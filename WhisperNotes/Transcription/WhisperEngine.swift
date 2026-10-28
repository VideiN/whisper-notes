import CoreML
import Foundation
@preconcurrency import WhisperKit

/// 전사 모델 (WhisperKit의 argmaxinc/whisperkit-coreml 저장소 이름)
nonisolated enum WhisperModel: String, CaseIterable, Codable, Sendable {
    /// large-v3 Turbo (OpenAI가 2024-09-30에 낸 것). 준실시간 전사와 완료 후 전사의 기본
    case turbo = "openai_whisper-large-v3-v20240930"
    /// 같은 Turbo를 양자화한 것 (CER 비교용, PLAN.md §9)
    case turboQuantized = "openai_whisper-large-v3-v20240930_626MB"
    /// large-v3 (CER 비교용. 차이가 작으면 뺀다, PLAN.md §3.3)
    case largeV3 = "openai_whisper-large-v3"

    var title: String {
        switch self {
        case .turbo: "large-v3 Turbo"
        case .turboQuantized: "large-v3 Turbo 양자화"
        case .largeV3: "large-v3"
        }
    }

    var approximateSize: String {
        switch self {
        case .turbo: "약 1.6GB"
        case .turboQuantized: "약 0.6GB"
        case .largeV3: "약 3GB"
        }
    }
}

/// 전사에 쓰는 계산 장치 (PLAN.md §3.2). GPU로 먼저 시험하고, 발열이나 필기 지연이 있으면 뉴럴 엔진으로 바꾼다.
/// CoreML은 불러올 때 계산 장치가 정해지므로 바꾸면 모델을 다시 불러온다. 시뮬레이터에서는 WhisperKit이 CPU만 쓴다
nonisolated enum ComputeMode: String, CaseIterable, Codable, Sendable {
    case gpu
    case neuralEngine

    var title: String {
        switch self {
        case .gpu: "GPU"
        case .neuralEngine: "뉴럴 엔진"
        }
    }

    var options: ModelComputeOptions {
        switch self {
        case .gpu:
            ModelComputeOptions(melCompute: .cpuAndGPU, audioEncoderCompute: .cpuAndGPU, textDecoderCompute: .cpuAndGPU)
        case .neuralEngine:
            ModelComputeOptions(melCompute: .cpuOnly, audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndNeuralEngine)
        }
    }
}

/// 불러온 WhisperKit 하나. 무거운 일은 모두 메인 밖(@concurrent)에서 한다.
/// WhisperKit은 Sendable이 아니지만, 이 앱은 한 번에 전사 하나만 돌리고(ModelManager) 그 사이 설정을 바꾸지 않는다
nonisolated final class WhisperEngine: @unchecked Sendable {
    let model: WhisperModel
    let compute: ComputeMode
    private let kit: WhisperKit

    private init(model: WhisperModel, compute: ComputeMode, kit: WhisperKit) {
        self.model = model
        self.compute = compute
        self.kit = kit
    }

    /// 모델을 base 아래에 받고 그 폴더를 돌려준다. 이미 받은 파일은 다시 받지 않는다
    @concurrent
    static func download(_ model: WhisperModel, to base: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await WhisperKit.download(variant: model.rawValue, downloadBase: base) { progress($0.fractionCompleted) }
    }

    @concurrent
    static func load(_ model: WhisperModel, compute: ComputeMode, folder: URL, tokenizerFolder: URL) async throws -> WhisperEngine {
        Logging.updateCallback { message in
            log("whisperkit: \(message)")
        }
        let config = WhisperKitConfig(
            modelFolder: folder.path,
            tokenizerFolder: tokenizerFolder,
            computeOptions: compute.options,
            verbose: true,
            logLevel: .info,
            prewarm: false,
            load: true,
            download: false
        )
        let kit = try await WhisperKit(config)
        return WhisperEngine(model: model, compute: compute, kit: kit)
    }

    /// 16kHz 모노 표본을 전사한다. 시각은 samples[0] 기준 (초).
    /// onProgress는 세그먼트가 나올 때마다 어디까지 전사했는지(초) 알린다
    @concurrent
    func transcribe(
        _ samples: [Float],
        options: DecodingOptions,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [TranscriptSegment] {
        var segmentCallback: SegmentDiscoveryCallback?
        if let onProgress {
            segmentCallback = { segments in
                if let end = segments.map(\.end).max() {
                    onProgress(Double(end))
                }
            }
        }
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options, callback: nil, segmentCallback: segmentCallback)
        return results
            .flatMap(\.segments)
            .map { TranscriptSegment(start: Double($0.start), end: Double($0.end), text: $0.text) }
    }

    @concurrent
    func unload() async {
        await kit.unloadModels()
    }

    /// 강의 전사 설정 (PLAN.md §3.2): 한국어 고정(자동 감지 끔), 무음·반복 판정 기준
    nonisolated static func options(live: Bool) -> DecodingOptions {
        DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: "ko",
            // 준실시간은 늦어지지 않게 다시 시도를 줄인다
            temperatureFallbackCount: live ? 2 : 5,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.6,
            // 완료 후 전사는 블록(약 5분) 안에서 앞 창의 마지막 시각부터 이어 가는 기본 방식이 경계에서 단어를 자르지 않는다
            chunkingStrategy: nil
        )
    }
}

nonisolated enum AudioLoader {
    /// 녹음 파일을 16kHz 모노 표본으로 읽는다
    @concurrent
    static func load(_ url: URL) async throws -> [Float] {
        try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
    }
}
