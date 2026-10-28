import BackgroundTasks
import UIKit

/// 완료 후 전사 (PLAN.md §3.3, M2). 녹음 조각을 순서대로 16kHz로 읽어 약 5분 블록으로 나눠 전사하고,
/// 블록마다 transcript/progress.json에 저장해 멈춘 곳부터 이어 간다. 블록 경계는 앞뒤 20초 중 가장 조용한 곳이다.
/// 다 끝나면 transcript/final.json에 쓴다 (준실시간 결과는 그대로 두고 화면에서 이것을 먼저 보여 준다).
///
/// 실행 경로:
/// - BGContinuedProcessingTask를 낼 수 있으면 낸다. 시스템이 진행률을 보여 주고, 앱을 나가도 이어 간다.
///   GPU 모드면 requiredResources = .gpu로 백그라운드 GPU를 요청한다 (이 앱에서 백그라운드 GPU는 여기서만 쓴다)
/// - 못 내면(LiveContainer 등) 앱 안에서 돌린다. 화면이 꺼지지 않게 하고, 백그라운드로 가면 멈췄다가 돌아오면 이어 간다
@Observable
final class FinalTranscriber {
    struct Job {
        let session: SessionFiles
        let model: WhisperModel
        let compute: ComputeMode
        var doneSeconds: Double = 0
        var totalSeconds: Double = 0
        /// 이번 실행의 처리 속도 (배속)
        var speed: Double?
        var status = "준비 중"
        var inBackgroundTask = false
        var backgroundGPU = false

        var fraction: Double { totalSeconds > 0 ? min(doneSeconds / totalSeconds, 1) : 0 }
    }

    static let blockSamples = 300 * SpeechChunker.sampleRate
    static let slackSamples = 20 * SpeechChunker.sampleRate

    private(set) var job: Job?
    /// 백그라운드로 가서 멈춘 세션. 돌아오면 이어 간다
    private(set) var pausedSession: SessionFiles?
    /// 블록을 저장하거나 전사가 끝날 때마다 오른다 (화면이 파일을 다시 읽게)
    private(set) var revision = 0
    private(set) var lastError: String?

    var isRunning: Bool { job != nil }

    private let models: ModelManager
    private var work: Task<Void, Never>?
    private var backgroundTask: BGContinuedProcessingTask?
    private var isInBackground = false

    init(models: ModelManager) {
        self.models = models
    }

    func start(_ session: SessionFiles) {
        guard job == nil else { return }
        let model = AppSettings.finalModel
        let compute = AppSettings.computeMode
        guard models.downloaded.contains(model) else {
            lastError = ModelManager.ModelError.notDownloaded(model).localizedDescription
            return
        }
        lastError = nil
        pausedSession = nil
        job = Job(session: session, model: model, compute: compute)
        UIApplication.shared.isIdleTimerDisabled = true
        if submitBackgroundTask(for: session, gpu: compute == .gpu) {
            // 시스템이 곧 작업을 시작한다 (attach). 시작하지 않으면 앱 안에서 돌린다
            Task {
                try? await Task.sleep(for: .seconds(3))
                if job?.session == session, work == nil {
                    log("final: background task did not start, running in app")
                    run()
                }
            }
        } else {
            run()
        }
    }

    func cancel() {
        log("final: cancel")
        pausedSession = nil
        work?.cancel()
    }

    func setBackground(_ inBackground: Bool) {
        isInBackground = inBackground
        if inBackground {
            guard let job, work != nil else { return }
            // GPU 작업은 백그라운드 GPU를 받은 작업 안에서만, 다른 계산도 백그라운드 작업 안에서만 이어 간다
            let canContinue = job.inBackgroundTask && (job.compute == .neuralEngine || job.backgroundGPU)
            if !canContinue {
                log("final: pausing for background")
                pausedSession = job.session
                work?.cancel()
            }
        } else if let session = pausedSession, job == nil {
            log("final: resuming after background")
            start(session)
        }
    }

    // MARK: - 실행

    private func run() {
        guard let job, work == nil else { return }
        work = Task(priority: .userInitiated) {
            let completed = await transcribe(job.session, model: job.model, compute: job.compute)
            finish(completed: completed)
        }
    }

    private func finish(completed: Bool) {
        if let backgroundTask {
            backgroundTask.setTaskCompleted(success: completed)
            self.backgroundTask = nil
        }
        work = nil
        job = nil
        revision += 1
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func transcribe(_ session: SessionFiles, model: WhisperModel, compute: ComputeMode) async -> Bool {
        guard let manifest = session.load(AudioManifest.self, from: session.manifestURL), !manifest.segments.isEmpty else {
            lastError = "녹음이 없습니다."
            return false
        }
        var state = session.load(FinalProgress.self, from: session.progressURL)
            .flatMap { $0.model == model.rawValue ? $0 : nil }
            ?? FinalProgress(model: model.rawValue, doneSamples: 0, segments: [])
        let totalSeconds = manifest.segments.reduce(0) { $0 + ($1.duration ?? Recorder.segmentSeconds) }
        let resumedFrom = Double(state.doneSamples) / Double(SpeechChunker.sampleRate)
        job?.totalSeconds = totalSeconds
        job?.doneSeconds = resumedFrom
        log("final: start \(session.id) \(model.rawValue) on \(compute.rawValue), \(formatClock(totalSeconds)) (from \(formatClock(resumedFrom)))")

        let started = ContinuousClock.now
        do {
            job?.status = "모델 불러오는 중"
            let engine = try await models.engine(model, compute: compute)
            job?.status = "전사 중"
            var buffer: [Float] = []
            /// buffer[0]의 세션 오디오 위치 (표본)
            var cursor = 0
            for segment in manifest.segments {
                try Task.checkCancellation()
                let samples: [Float]
                do {
                    samples = try await AudioLoader.load(session.audioDirectory.appending(path: segment.file))
                } catch {
                    // 앱이 죽어서 닫지 못한 조각은 읽을 수 없다
                    log("final: skip \(segment.file): \(error)")
                    continue
                }
                buffer.append(contentsOf: samples)
                if state.doneSamples > cursor {
                    let done = min(state.doneSamples - cursor, buffer.count)
                    buffer.removeFirst(done)
                    cursor += done
                }
                while buffer.count >= Self.blockSamples + Self.slackSamples {
                    let cut = QuietPoint.find(in: buffer, around: Self.blockSamples, radius: Self.slackSamples)
                    try await transcribeBlock(Array(buffer[..<cut]), at: cursor, engine: engine, state: &state, session: session, started: started, resumedFrom: resumedFrom)
                    buffer.removeFirst(cut)
                    cursor += cut
                }
            }
            if !buffer.isEmpty {
                try await transcribeBlock(buffer, at: cursor, engine: engine, state: &state, session: session, started: started, resumedFrom: resumedFrom)
            }

            let elapsed = (ContinuousClock.now - started) / .seconds(1)
            let transcript = Transcript(model: model.rawValue, computeMode: compute.rawValue, segments: state.segments, updatedAt: .now)
            try session.save(transcript, to: session.finalURL)
            try? FileManager.default.removeItem(at: session.progressURL)
            var meta = session.load(SessionMeta.self, from: session.metaURL) ?? SessionMeta(createdAt: .now)
            meta.finalModel = model.rawValue
            meta.finalComputeMode = compute.rawValue
            meta.finalCompletedAt = .now
            meta.finalElapsed = elapsed
            try session.save(meta, to: session.metaURL)
            log("final: done \(session.id) in \(String(format: "%.0f", elapsed))s, \(state.segments.count) segments")
            return true
        } catch {
            if Task.isCancelled {
                log("final: stopped at \(formatClock(Double(state.doneSamples) / Double(SpeechChunker.sampleRate)))")
            } else {
                log("final: failed: \(error)")
                lastError = "완료 후 전사 실패: \(error.localizedDescription)"
            }
            return false
        }
    }

    private func transcribeBlock(
        _ samples: [Float],
        at start: Int,
        engine: WhisperEngine,
        state: inout FinalProgress,
        session: SessionFiles,
        started: ContinuousClock.Instant,
        resumedFrom: Double
    ) async throws {
        let offset = Double(start) / Double(SpeechChunker.sampleRate)
        let blockStarted = ContinuousClock.now
        let found = try await engine.transcribe(samples, options: WhisperEngine.options(live: false)) { seconds in
            Task { @MainActor in
                self.report(doneSeconds: offset + seconds, started: started, resumedFrom: resumedFrom)
            }
        }
        try Task.checkCancellation()
        state.segments.append(contentsOf: TranscriptFilter.clean(found).map { $0.shifted(by: offset) })
        state.doneSamples = start + samples.count
        try session.save(state, to: session.progressURL)
        revision += 1
        let blockSeconds = Double(samples.count) / Double(SpeechChunker.sampleRate)
        let elapsed = (ContinuousClock.now - blockStarted) / .seconds(1)
        log("final: block \(formatClock(offset)) +\(formatClock(blockSeconds)) in \(String(format: "%.1f", elapsed))s")
        report(doneSeconds: offset + blockSeconds, started: started, resumedFrom: resumedFrom)
    }

    private func report(doneSeconds: Double, started: ContinuousClock.Instant, resumedFrom: Double) {
        guard var job, doneSeconds > job.doneSeconds else { return }
        job.doneSeconds = doneSeconds
        let elapsed = (ContinuousClock.now - started) / .seconds(1)
        if elapsed > 5 {
            job.speed = (doneSeconds - resumedFrom) / elapsed
        }
        self.job = job
        if let backgroundTask {
            backgroundTask.progress.completedUnitCount = Int64(job.fraction * 1000)
            backgroundTask.updateTitle("강의 전사", subtitle: "\(Int(job.fraction * 100))% · \(formatClock(job.doneSeconds)) / \(formatClock(job.totalSeconds))")
        }
    }

    // MARK: - BGContinuedProcessingTask

    /// LiveContainer처럼 다른 앱 안에서 돌면 등록할 수 있는 작업 식별자가 그 앱의 것이라, 시도하지 않는다
    private static var canUseBackgroundTasks: Bool {
        Bundle.main.bundlePath.localizedCaseInsensitiveContains("/containers/Bundle/Application/")
            && Bundle.main.bundleIdentifier == "io.github.videin.whispernotes"
    }

    private func submitBackgroundTask(for session: SessionFiles, gpu: Bool) -> Bool {
        guard Self.canUseBackgroundTasks, let bundleID = Bundle.main.bundleIdentifier else {
            log("final: background task not available here")
            return false
        }
        // Info.plist의 BGTaskSchedulerPermittedIdentifiers: <번들 ID>.final.*
        // 같은 식별자를 두 번 등록하면 앱이 죽으므로 매번 새로 만든다
        let identifier = "\(bundleID).final.\(session.id).\(Int(Date.now.timeIntervalSince1970))"
        // 시작 처리기는 메인 큐에서 부른다 (using: .main)
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { @Sendable [weak self] task in
            nonisolated(unsafe) let launched = task
            MainActor.assumeIsolated {
                guard let self, let task = launched as? BGContinuedProcessingTask else {
                    launched.setTaskCompleted(success: false)
                    return
                }
                self.attach(task, session: session)
            }
        }
        guard registered else {
            log("final: cannot register background task")
            return false
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "강의 전사", subtitle: "시작하는 중")
        request.strategy = .fail
        let gpuSupported = BGTaskScheduler.supportedResources.contains(.gpu)
        if gpu, gpuSupported {
            request.requiredResources = .gpu
        }
        do {
            try BGTaskScheduler.shared.submit(request)
            job?.backgroundGPU = gpu && gpuSupported
            log("final: submitted background task (gpu requested \(gpu), supported \(gpuSupported))")
            return true
        } catch {
            log("final: cannot submit background task: \(error)")
            return false
        }
    }

    private func attach(_ task: BGContinuedProcessingTask, session: SessionFiles) {
        guard job?.session == session else {
            task.setTaskCompleted(success: false)
            return
        }
        log("final: background task started")
        backgroundTask = task
        job?.inBackgroundTask = true
        task.progress.totalUnitCount = 1000
        task.progress.completedUnitCount = Int64((job?.fraction ?? 0) * 1000)
        task.expirationHandler = { @Sendable [weak self] in
            Task { @MainActor in
                log("final: background task expired")
                self?.work?.cancel()
            }
        }
        if isInBackground, let job, !(job.compute == .neuralEngine || job.backgroundGPU) {
            // GPU를 받지 못한 채로 이미 백그라운드다. 돌아오면 다시 시작한다
            pausedSession = session
            finish(completed: false)
            return
        }
        run()
    }
}

nonisolated enum QuietPoint {
    /// samples[around - radius ..< around + radius]에서 앞뒤 0.25초 에너지가 가장 낮은 곳 (0.1초 간격으로 찾는다)
    static func find(in samples: [Float], around center: Int, radius: Int, window: Int = 8_000) -> Int {
        let half = window / 2
        let lower = max(half, center - radius)
        let upper = min(samples.count - half, center + radius)
        guard lower < upper else { return min(center, samples.count) }
        var best = center
        var bestEnergy = Float.infinity
        var position = lower
        while position < upper {
            var energy: Float = 0
            for sample in samples[(position - half) ..< (position + half)] {
                energy += sample * sample
            }
            if energy < bestEnergy {
                bestEnergy = energy
                best = position
            }
            position += SpeechChunker.frameLength
        }
        return best
    }
}
