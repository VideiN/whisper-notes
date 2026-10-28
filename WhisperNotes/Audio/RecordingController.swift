import AVFoundation

/// 녹음 1회: 녹음기와 준실시간 전사를 잇는다
@Observable
final class RecordingController {
    let session: SessionFiles
    let live: LiveTranscriber
    private(set) var isRecording = false
    private(set) var seconds: Double = 0
    private(set) var level: Float = 0
    private(set) var status: String?

    private var recorder: Recorder?
    private var chunks: AsyncStream<SpeechChunk>.Continuation?
    private var events: AsyncStream<Recorder.Event>.Continuation?

    init(session: SessionFiles, models: ModelManager) {
        self.session = session
        live = LiveTranscriber(session: session, models: models)
    }

    func start() async throws {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw PermissionError()
        }
        let (chunkStream, chunkInput) = AsyncStream.makeStream(of: SpeechChunk.self)
        let (eventStream, eventInput) = AsyncStream.makeStream(of: Recorder.Event.self)
        let recorder = Recorder(
            session: session,
            mode: AppSettings.audioMode.sessionMode,
            onChunk: { _ = chunkInput.yield($0) },
            onEvent: { _ = eventInput.yield($0) }
        )
        try recorder.start()
        self.recorder = recorder
        chunks = chunkInput
        events = eventInput
        isRecording = true
        live.prepare()
        Task {
            for await chunk in chunkStream {
                live.enqueue(chunk)
            }
        }
        Task {
            for await event in eventStream {
                handle(event)
            }
        }
    }

    func stop() {
        guard let recorder else { return }
        recorder.stop()
        self.recorder = nil
        chunks?.finish()
        events?.finish()
        isRecording = false
        level = 0
    }

    private func handle(_ event: Recorder.Event) {
        switch event {
        case .progress(let level, let seconds):
            self.level = level
            self.seconds = seconds
        case .interrupted:
            status = "녹음이 중단되었습니다 (전화·Siri 등). 끝나면 이어서 녹음합니다."
        case .resumed:
            status = nil
        case .failed(let message):
            status = "녹음 오류: \(message)"
        }
    }

    nonisolated struct PermissionError: LocalizedError {
        var errorDescription: String? { "마이크 권한이 없습니다. 설정 앱에서 위스퍼 필기의 마이크를 허용해 주세요." }
    }
}
