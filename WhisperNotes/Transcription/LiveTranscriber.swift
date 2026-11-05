import Foundation

/// 준실시간 전사 (PLAN.md §3.2, M3). 녹음기가 쉬는 곳에서 끊은 조각을 차례로 Turbo로 전사해 transcript/live.json에 쌓는다.
/// 자원 순위는 녹음 > 필기 > 전사라서 낮은 우선순위로 돌리고, 기기가 뜨거우면 조각 사이를 띄운다.
/// 앱이 백그라운드에 있는 동안:
/// - 뉴럴 엔진 모드(기본)는 이어 간다. 녹음은 오디오 백그라운드 모드로 계속되고, iPadOS 27부터는 백그라운드에서 뉴럴 엔진을 쓰려면
///   Background Inference 엔타이틀먼트가 있어야 한다 (WhisperNotes.entitlements)
/// - GPU 모드는 멈춘다. 백그라운드 GPU는 BGContinuedProcessingTask 안에서만 허락되기 때문이다. 하던 조각은 취소하고 돌아오면 다시 한다
/// 밀린 조각은 메모리에 있으므로 개수를 제한하고, 넘치면 오래된 것부터 건너뛴다. 완료 후 전사가 전체를 다시 덮기 때문이다
@Observable
final class LiveTranscriber {
    /// GPU 모드로 백그라운드에 있는 동안 남겨 두는 조각 수 (돌아오면 최근 약 2분만 전사한다)
    static let maxBacklog = 4
    /// 전사가 녹음보다 느릴 때(백그라운드에서 느려지는 경우 등) 남겨 두는 조각 수. 조각은 최대 29초, 16kHz float라서 하나에 약 1.9MB
    static let maxQueued = 20

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
    /// 모델과 계산 장치는 녹음을 시작할 때 정해 둔다 (녹음 중에 설정을 바꿔도 다음 녹음부터)
    private let model: WhisperModel
    private let compute: ComputeMode
    private var pending: [SpeechChunk] = []
    private var current: Task<Void, Never>?
    private var isInBackground = false

    init(session: SessionFiles, models: ModelManager) {
        self.session = session
        self.models = models
        model = AppSettings.liveModel
        compute = AppSettings.liveComputeMode
        segments = session.load(Transcript.self, from: session.liveURL)?.segments ?? []
    }

    /// 녹음을 시작하면 바로 모델을 불러 둔다 (첫 조각을 기다리게 하지 않으려고)
    func prepare() {
        guard AppSettings.liveEnabled else {
            message = "준실시간 전사가 꺼져 있습니다 (설정)."
            return
        }
        guard models.downloaded.contains(model) else {
            message = "\(model.title) 모델을 받으면 녹음하면서 전사합니다."
            return
        }
        Task(priority: .utility) {
            do {
                _ = try await models.engine(model, compute: compute)
            } catch {
                message = "모델을 불러오지 못했습니다: \(error.localizedDescription)"
            }
        }
    }

    func enqueue(_ chunk: SpeechChunk) {
        guard AppSettings.liveEnabled, models.downloaded.contains(model) else { return }
        pending.append(chunk)
        trimPending(to: isPaused ? Self.maxBacklog : Self.maxQueued)
        processNext()
    }

    /// GPU 모드면 백그라운드로 갈 때 멈추고 하던 조각을 취소한다. 뉴럴 엔진 모드는 그대로 이어 간다
    func setBackground(_ inBackground: Bool) {
        isInBackground = inBackground
        guard compute == .gpu else {
            log("live: \(inBackground ? "background" : "foreground"), continuing on \(compute.rawValue)")
            return
        }
        if inBackground {
            isPaused = true
            // GPU 작업을 더 내지 않게 한다. WhisperKit이 취소를 보지 못하고 끝까지 가면 그 결과는 그대로 쓴다
            current?.cancel()
            trimPending(to: Self.maxBacklog)
            log("live: paused (background, GPU)")
            return
        }
        guard isPaused else { return }
        isPaused = false
        log("live: resumed")
        processNext()
    }

    /// 밀린 조각이 limit보다 많으면 오래된 것을 버린다
    private func trimPending(to limit: Int) {
        if pending.count > limit {
            let dropped = pending.count - limit
            pending.removeFirst(dropped)
            skippedChunks += dropped
            log("live: skipped \(dropped) chunks (backlog)")
        }
        pendingCount = pending.count
    }

    private func processNext() {
        guard !isTranscribing, !isPaused, !pending.isEmpty else { return }
        let chunk = pending.removeFirst()
        pendingCount = pending.count
        isTranscribing = true
        current = Task(priority: .utility) {
            await transcribe(chunk)
            isTranscribing = false
            current = nil
            processNext()
        }
    }

    private func transcribe(_ chunk: SpeechChunk) async {
        do {
            let engine = try await models.engine(model, compute: compute)
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
            // 백그라운드에서 얼마나 느려지는지 보려고 표시한다 (PLAN.md §3.3의 알려진 이슈)
            log("live: \(formatClock(chunk.start)) +\(String(format: "%.1f", chunk.duration))s → \(String(format: "%.2f", seconds))s, \(kept.count) segments\(isInBackground ? " (background)" : "")")
            save()
        } catch where Task.isCancelled {
            // 백그라운드로 가서 취소했다. 돌아오면 다시 한다 (그사이 밀린 조각이 많으면 건너뛸 수 있다)
            pending.insert(chunk, at: 0)
            trimPending(to: Self.maxBacklog)
            log("live: cancelled at \(formatClock(chunk.start)), will retry")
        } catch {
            log("live: failed at \(formatClock(chunk.start)): \(error)")
            message = "전사하지 못한 조각이 있습니다: \(error.localizedDescription)"
        }
    }

    private func save() {
        let transcript = Transcript(
            model: model.rawValue,
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
