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
        /// 완료 후 전사의 계산 장치. 예전에 두 전사가 같이 쓰던 키를 그대로 쓴다 (이미 고른 값을 살리려고)
        static let finalComputeMode = "computeMode"
        static let liveComputeMode = "liveComputeMode"
        static let finalModel = "finalModel"
        static let liveEnabled = "liveEnabled"
        static let audioMode = "audioMode"
    }

    /// 준실시간 전사 모델은 Turbo로 정했다 (PLAN.md §2)
    static let liveModel = WhisperModel.turbo

    /// 준실시간 전사는 뉴럴 엔진이 기본이다. 녹음 중 백그라운드에서도 이어 갈 수 있는 것은 뉴럴 엔진뿐이기 때문이다
    /// (iPadOS 27부터는 Background Inference 엔타이틀먼트가 있어야 한다, PLAN.md §3.2)
    static var liveComputeMode: ComputeMode {
        UserDefaults.standard.string(forKey: Key.liveComputeMode).flatMap(ComputeMode.init) ?? .neuralEngine
    }

    /// 완료 후 전사는 GPU가 기본이다 (백그라운드에서는 BGContinuedProcessingTask의 백그라운드 GPU, PLAN.md §3.3)
    static var finalComputeMode: ComputeMode {
        UserDefaults.standard.string(forKey: Key.finalComputeMode).flatMap(ComputeMode.init) ?? .gpu
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
