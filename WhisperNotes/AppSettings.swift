import AVFoundation

/// 마이크 모드 (PLAN.md §3.2: 멀리서 수음할 때 어느 쪽이 나은지 비교)
nonisolated enum AudioMode: String, CaseIterable, Sendable {
    case standard
    /// 시스템의 음성 처리(자동 이득 등)를 끈다
    case measurement

    var title: String {
        switch self {
        case .standard: "기본"
        case .measurement: "측정 (음성 처리 끔)"
        }
    }

    var sessionMode: AVAudioSession.Mode {
        switch self {
        case .standard: .default
        case .measurement: .measurement
        }
    }
}

/// 앱 설정. 화면에서는 같은 키로 @AppStorage를 쓴다
nonisolated enum AppSettings {
    enum Key {
        static let computeMode = "computeMode"
        static let finalModel = "finalModel"
        static let liveEnabled = "liveEnabled"
        static let audioMode = "audioMode"
    }

    /// 준실시간 전사 모델은 Turbo로 정했다 (PLAN.md §2)
    static let liveModel = WhisperModel.turbo

    static var computeMode: ComputeMode {
        UserDefaults.standard.string(forKey: Key.computeMode).flatMap(ComputeMode.init) ?? .gpu
    }

    static var finalModel: WhisperModel {
        UserDefaults.standard.string(forKey: Key.finalModel).flatMap(WhisperModel.init) ?? .turbo
    }

    static var liveEnabled: Bool {
        UserDefaults.standard.object(forKey: Key.liveEnabled) as? Bool ?? true
    }

    static var audioMode: AudioMode {
        UserDefaults.standard.string(forKey: Key.audioMode).flatMap(AudioMode.init) ?? .standard
    }
}
