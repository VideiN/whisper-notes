import Foundation

/// meta.json: 세션 정보. 나중에 필드를 더해도 예전 파일을 읽을 수 있게 모두 옵셔널이다
nonisolated struct SessionMeta: Codable, Sendable {
    var createdAt: Date
    var finalModel: String?
    var finalComputeMode: String?
    var finalCompletedAt: Date?
    /// 완료 후 전사에 걸린 시간 (초, 마지막으로 이어서 돌린 것만)
    var finalElapsed: Double?
}

/// audio/manifest.json: 녹음 조각 순서와 벽시계 시각 (PLAN.md §2, §3.2).
/// 세션 오디오 시간축은 조각을 순서대로 이어 붙인 것이고, 전화 등으로 끊겼던 시간은 벽시계 시각으로만 남는다
nonisolated struct AudioManifest: Codable, Sendable {
    struct Segment: Codable, Sendable {
        /// audio/ 안의 파일 이름 (seg_0001.m4a)
        var file: String
        var sampleRate: Double
        var startedAt: Date
        /// 닫지 못한 조각(녹음 중이거나 앱이 죽었을 때)은 nil
        var endedAt: Date?
        /// 세션 오디오 시간축에서 이 조각이 시작하는 위치 (초)
        var offset: Double
        var duration: Double?
    }

    var segments: [Segment]

    /// 닫은 조각까지의 길이 (초)
    var duration: Double {
        guard let last = segments.last else { return 0 }
        return last.offset + (last.duration ?? 0)
    }
}

/// Whisper 세그먼트 1개. 시각은 세션 오디오 시간축 (초)
nonisolated struct TranscriptSegment: Codable, Hashable, Sendable {
    var start: Double
    var end: Double
    var text: String

    func shifted(by offset: Double) -> TranscriptSegment {
        TranscriptSegment(start: start + offset, end: end + offset, text: text)
    }
}

/// transcript/live.json, transcript/final.json
nonisolated struct Transcript: Codable, Sendable {
    var model: String
    var computeMode: String
    var segments: [TranscriptSegment]
    var updatedAt: Date

    /// 공유용 글: "[1:02:03] 문장" 줄들
    static func text(title: String, segments: [TranscriptSegment]) -> String {
        let lines = segments.map { "[\(formatClock($0.start))] \($0.text)" }
        return ([title, ""] + lines).joined(separator: "\n")
    }
}

/// transcript/progress.json: 완료 후 전사를 중간에 멈췄다가 이어 가기 위한 상태 (PLAN.md §3.3)
nonisolated struct FinalProgress: Codable, Sendable {
    var model: String
    /// 세션 오디오 시간축에서 전사를 끝낸 곳 (16kHz 표본 수)
    var doneSamples: Int
    var segments: [TranscriptSegment]
}

/// 65초 → "1:05", 3723초 → "1:02:03"
nonisolated func formatClock(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, secs)
        : String(format: "%d:%02d", minutes, secs)
}
