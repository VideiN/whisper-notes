import Foundation

/// 준실시간 전사 (PLAN.md §3.2, M3). 녹음기가 쉬는 곳에서 끊은 조각을 차례로 Turbo로 전사해 transcript/live.json에 쌓는다.
/// 자원 순위는 녹음 > 필기 > 전사라서 낮은 우선순위로 돌리고, 기기가 뜨거우면 조각 사이를 띄운다.
/// GPU 모드에서는 앱이 백그라운드에 있는 동안 멈춘다 (백그라운드에서는 GPU를 쓸 수 없다). 그동안 밀린 조각이 많으면
/// 오래된 것은 건너뛴다. 완료 후 전사가 전체를 다시 덮기 때문이다
@Observable
final class LiveTranscriber {
    /// 돌아왔을 때 밀린 조각이 이보다 많으면 최근 것만 남긴다
    static let maxBacklog = 4

    let session: SessionFiles
    private(set) var segments: [TranscriptSegment] = []
    private(set) var pendingCount = 0
    private(set) var isTranscribing = false
    /// 마지막 조각의 처리 속도 (오디오 길이 / 처리 시간, 배속)
    private(set) var lastSpeed: Double?
    private(set) var skippedChunks = 0
    private(set) var message: String?
    private(set) var isPaused = false

    /// 아직 전사할 조각이 남았거나 전사 중
    var isBusy: Bool { isTranscribing || pendingCount > 0 }

    private let models: ModelManager
    private let compute: ComputeMode
    private var pending: [SpeechChunk] = []

    init(session: SessionFiles, models: ModelManager) {
        self.session = session
        self.models = models
        compute = AppSettings.computeMode
        segments = session.load(Transcript.self, from: session.liveURL)?.segments ?? []
    }

    /// 녹음을 시작하면 바로 모델을 불러 둔다 (첫 조각을 기다리게 하지 않으려고)
    func prepare() {
        guard AppSettings.liveEnabled else {
            message = "준실시간 전사가 꺼져 있습니다 (설정)."
            return
        }
        guard models.downloaded.contains(AppSettings.liveModel) else {
            message = "\(AppSettings.liveModel.title) 모델을 받으면 녹음하면서 전사합니다."
            return
        }
        Task(priority: .utility) {
            do {
                _ = try await models.engine(AppSettings.liveModel, compute: compute)
            } catch {
                message = "모델을 불러오지 못했습니다: \(error.localizedDescription)"
            }
        }
    }

    func enqueue(_ chunk: SpeechChunk) {
        guard AppSettings.liveEnabled, models.downloaded.contains(AppSettings.liveModel) else { return }
        pending.append(chunk)
        pendingCount = pending.count
        processNext()
    }

    /// 앱이 백그라운드로 가면 (GPU 모드일 때만) 멈춘다
    func setBackground(_ inBackground: Bool) {
        guard compute == .gpu else { return }
        if inBackground {
            isPaused = true
            log("live: paused (background, GPU)")
            return
        }
        guard isPaused else { return }
        isPaused = false
        if pending.count > Self.maxBacklog {
            let dropped = pending.count - Self.maxBacklog
            pending.removeFirst(dropped)
            pendingCount = pending.count
            skippedChunks += dropped
            log("live: skipped \(dropped) chunks from background")
        }
        log("live: resumed")
        processNext()
    }

    private func processNext() {
        guard !isTranscribing, !isPaused, !pending.isEmpty else { return }
        let chunk = pending.removeFirst()
        pendingCount = pending.count
        isTranscribing = true
        Task(priority: .utility) {
            await transcribe(chunk)
            isTranscribing = false
            processNext()
        }
    }

    private func transcribe(_ chunk: SpeechChunk) async {
        do {
            let engine = try await models.engine(AppSettings.liveModel, compute: compute)
            if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                log("live: hot (\(ProcessInfo.processInfo.thermalState.rawValue)), waiting")
                try await Task.sleep(for: .seconds(5))
            }
            let started = ContinuousClock.now
            let found = try await engine.transcribe(chunk.samples, options: WhisperEngine.options(live: true))
            let seconds = (ContinuousClock.now - started) / .seconds(1)
            lastSpeed = chunk.duration / max(seconds, 0.001)
            let kept = TranscriptFilter.clean(found).map { $0.shifted(by: chunk.start) }
            segments.append(contentsOf: kept)
            message = nil
            log("live: \(formatClock(chunk.start)) +\(String(format: "%.1f", chunk.duration))s → \(String(format: "%.2f", seconds))s, \(kept.count) segments")
            save()
        } catch {
            log("live: failed at \(formatClock(chunk.start)): \(error)")
            message = "전사하지 못한 조각이 있습니다: \(error.localizedDescription)"
        }
    }

    private func save() {
        let transcript = Transcript(
            model: AppSettings.liveModel.rawValue,
            computeMode: compute.rawValue,
            segments: segments,
            updatedAt: .now
        )
        do {
            try session.save(transcript, to: session.liveURL)
        } catch {
            log("live: cannot save: \(error)")
        }
    }
}
