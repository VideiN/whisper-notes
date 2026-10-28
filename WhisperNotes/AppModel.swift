import SwiftUI

/// 세션 목록에 보이는 요약
struct SessionSummary: Identifiable, Hashable {
    let session: SessionFiles
    let createdAt: Date
    let duration: Double
    let liveSegments: Int
    let finalModel: WhisperModel?
    let hasProgress: Bool

    var id: String { session.id }

    var title: String {
        createdAt.formatted(.dateTime.month().day().weekday(.abbreviated).hour().minute())
    }
}

/// 앱 전체 상태: 녹음은 한 번에 하나, 전사 모델도 한 번에 하나만 불러 둔다
@Observable
final class AppModel {
    let models = ModelManager()
    let finalTranscriber: FinalTranscriber
    private(set) var recording: RecordingController?
    /// 녹음을 멈춘 뒤에도 밀린 조각을 전사하는 중일 수 있다. 그동안 완료 후 전사를 시작하지 않는다 (모델 하나를 같이 쓴다)
    private(set) var stoppedLive: LiveTranscriber?
    private(set) var sessions: [SessionSummary] = []
    var errorMessage: String?

    init() {
        finalTranscriber = FinalTranscriber(models: models)
        reload()
    }

    func reload() {
        sessions = SessionFiles.all().map { session in
            let meta = session.load(SessionMeta.self, from: session.metaURL)
            let manifest = session.load(AudioManifest.self, from: session.manifestURL)
            let live = session.load(Transcript.self, from: session.liveURL)
            return SessionSummary(
                session: session,
                createdAt: meta?.createdAt ?? .distantPast,
                duration: manifest?.segments.reduce(0) { $0 + ($1.duration ?? 0) } ?? 0,
                liveSegments: live?.segments.count ?? 0,
                finalModel: FileManager.default.fileExists(atPath: session.finalURL.path) ? meta?.finalModel.flatMap(WhisperModel.init) : nil,
                hasProgress: FileManager.default.fileExists(atPath: session.progressURL.path)
            )
        }
    }

    func summary(of session: SessionFiles) -> SessionSummary? {
        sessions.first { $0.session == session }
    }

    /// 그 세션을 전사하고 있거나 막 끝낸 준실시간 전사
    func live(for session: SessionFiles) -> LiveTranscriber? {
        if let recording, recording.session == session { return recording.live }
        if let stoppedLive, stoppedLive.session == session { return stoppedLive }
        return nil
    }

    /// 녹음도 전사도 하고 있지 않다 (새 녹음이나 완료 후 전사를 시작할 수 있다)
    var isIdle: Bool {
        recording == nil && !finalTranscriber.isRunning && !(stoppedLive?.isBusy ?? false)
    }

    func startRecording() async -> SessionFiles? {
        guard isIdle else { return nil }
        do {
            let session = try SessionFiles.create()
            let controller = RecordingController(session: session, models: models)
            recording = controller
            stoppedLive = nil
            do {
                try await controller.start()
            } catch {
                recording = nil
                try? session.delete()
                throw error
            }
            reload()
            return session
        } catch {
            log("app: cannot start recording: \(error)")
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func stopRecording() {
        guard let recording else { return }
        recording.stop()
        stoppedLive = recording.live
        self.recording = nil
        reload()
    }

    func delete(_ session: SessionFiles) {
        guard recording?.session != session, finalTranscriber.job?.session != session, live(for: session)?.isBusy != true else { return }
        do {
            try session.delete()
            log("app: deleted session \(session.id)")
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            (recording?.live ?? stoppedLive)?.setBackground(true)
            finalTranscriber.setBackground(true)
        case .active:
            (recording?.live ?? stoppedLive)?.setBackground(false)
            finalTranscriber.setBackground(false)
        default:
            break
        }
    }
}
