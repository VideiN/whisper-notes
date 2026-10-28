import Foundation

/// Whisper 결과 다듬기 (PLAN.md §3.2 환각 대응).
/// 한국어 Whisper는 무음·소음 구간에서 방송 자막에서 배운 문구를 지어내는 일이 잘 알려져 있다
nonisolated enum TranscriptFilter {
    /// 공백 없이 비교한다
    static let knownHallucinations = [
        "시청해주셔서감사합니다",
        "시청해주셔서고맙습니다",
        "구독과좋아요",
        "좋아요와구독",
        "구독좋아요",
        "다음영상에서만나요",
        "끝까지시청해주셔서",
        "MBC뉴스",
        "KBS뉴스",
        "SBS뉴스",
        "자막제공",
        "자막by",
        "한글자막",
        "Thankyouforwatching",
    ]

    static func clean(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.compactMap { segment in
            let text = segment.text
                .replacing(/<\|[^|]*\|>/, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let compact = text.filter { !$0.isWhitespace }
            if let phrase = knownHallucinations.first(where: { compact.localizedCaseInsensitiveContains($0) }) {
                log("filter: dropped \"\(text)\" (\(phrase))")
                return nil
            }
            return TranscriptSegment(start: segment.start, end: segment.end, text: text)
        }
    }
}
