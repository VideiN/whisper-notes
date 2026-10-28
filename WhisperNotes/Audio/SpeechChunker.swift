import Foundation

/// 준실시간 전사에 넘기는 16kHz 모노 음성 조각
nonisolated struct SpeechChunk: Sendable {
    /// 세션 오디오 시간축에서 시작 위치 (초)
    let start: Double
    let samples: [Float]

    var duration: Double { Double(samples.count) / Double(SpeechChunker.sampleRate) }
}

/// 16kHz 음성을 쉬는 곳에서 끊어 최대 29초 조각으로 나눈다 (PLAN.md §3.2).
/// 고정 30초로 자르면 단어 중간이 잘리므로, 4초가 넘은 뒤 0.6초 조용하면 끊고, 29초가 되면 마지막 5초 중 가장 조용한 곳에서 끊는다.
/// 소리가 거의 없는 조각은 넘기지 않는다 (무음 환각 줄이기). 조용함의 기준은 주변 소음을 따라 바뀐다 (강의실 공조·프로젝터 소음)
nonisolated struct SpeechChunker {
    static let sampleRate = 16_000
    /// 0.1초
    static let frameLength = 1_600

    var minFrames = 40
    /// Whisper 창(30초)보다 조금 짧게
    var maxFrames = 290
    var pauseFrames = 6
    /// 소리 있는 프레임이 이보다 적으면 무음 조각으로 보고 버린다
    var minVoicedFrames = 3

    /// samples[0]의 세션 오디오 시각 (초)
    private(set) var origin: Double
    private var samples: [Float] = []
    private var energies: [Float] = []
    private var noiseFloor: Float = 0.002

    init(origin: Double = 0) {
        self.origin = origin
    }

    /// 소리 있음/없음 경계 (RMS)
    var threshold: Float { max(noiseFloor * 3, 0.004) }

    mutating func append(_ newSamples: [Float]) -> [SpeechChunk] {
        samples.append(contentsOf: newSamples)
        while (energies.count + 1) * Self.frameLength <= samples.count {
            let start = energies.count * Self.frameLength
            let energy = Self.rms(samples[start ..< start + Self.frameLength])
            energies.append(energy)
            // 조용해지면 빨리 따라 내려가고, 시끄러우면 천천히 올라간다
            noiseFloor = energy < noiseFloor ? noiseFloor * 0.7 + energy * 0.3 : min(noiseFloor * 1.002, 0.05)
        }
        var chunks: [SpeechChunk] = []
        while let cut = nextCut() {
            if let chunk = take(frames: cut) {
                chunks.append(chunk)
            }
        }
        return chunks
    }

    /// 녹음이 끝나거나 끊길 때 남은 것을 내보낸다
    mutating func flush() -> SpeechChunk? {
        let frames = (samples.count + Self.frameLength - 1) / Self.frameLength
        while energies.count < frames {
            let start = energies.count * Self.frameLength
            energies.append(Self.rms(samples[start ..< min(start + Self.frameLength, samples.count)]))
        }
        let voiced = energies.filter { $0 >= threshold }.count
        let chunk = SpeechChunk(start: origin, samples: samples)
        origin += chunk.duration
        samples = []
        energies = []
        return voiced >= minVoicedFrames ? chunk : nil
    }

    private func nextCut() -> Int? {
        let count = energies.count
        if count >= maxFrames {
            let tail = (maxFrames - 50) ..< maxFrames
            let quietest = tail.min { energies[$0] < energies[$1] } ?? maxFrames - 1
            return quietest + 1
        }
        guard count >= minFrames else { return nil }
        let limit = threshold
        if energies[(count - pauseFrames)...].allSatisfy({ $0 < limit }) {
            return count - pauseFrames / 2
        }
        return nil
    }

    private mutating func take(frames: Int) -> SpeechChunk? {
        let count = frames * Self.frameLength
        let limit = threshold
        let voiced = energies[..<frames].filter { $0 >= limit }.count
        let chunk = SpeechChunk(start: origin, samples: Array(samples[..<count]))
        samples.removeFirst(count)
        energies.removeFirst(frames)
        origin += chunk.duration
        return voiced >= minVoicedFrames ? chunk : nil
    }

    static func rms(_ frame: ArraySlice<Float>) -> Float {
        guard !frame.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in frame {
            sum += sample * sample
        }
        return (sum / Float(frame.count)).squareRoot()
    }
}
