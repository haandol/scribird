import CoreMedia
import Foundation

/// 전사 결과 한 조각.
///
/// `SpeechTranscriber`는 같은 구간에 대해 volatile(잠정) 결과를 여러 번 내보내다가
/// 마지막에 final 결과 하나로 확정한다. `isFinal == false`인 세그먼트는 화면에만
/// 흐리게 표시하고 디스크에는 쓰지 않는다.
struct TranscriptSegment: Identifiable, Sendable {
    let id: UUID
    let speaker: Speaker
    /// 세션 시작 시점을 0으로 하는 오디오 타임라인 위의 구간.
    let range: CMTimeRange
    let text: String
    let isFinal: Bool
    /// 전사기가 신뢰도를 보고했을 때만 값이 있다.
    let confidence: Double?
    /// 이 결과를 낸 전사기의 로케일. 다국어 중재와 회의록 표기에 쓴다.
    let localeIdentifier: String?
    /// 단어 단위 조각. 다국어 중재가 이 단위로 판정한다.
    let tokens: [Token]

    init(
        id: UUID = UUID(),
        speaker: Speaker,
        range: CMTimeRange,
        text: String,
        isFinal: Bool,
        confidence: Double? = nil,
        localeIdentifier: String? = nil,
        tokens: [Token] = []
    ) {
        self.id = id
        self.speaker = speaker
        self.range = range
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence
        self.localeIdentifier = localeIdentifier
        self.tokens = tokens
    }

    /// 전사기가 보고한 단어 단위 조각.
    ///
    /// 다국어 중재는 세그먼트 전체가 아니라 이 단위로 판정해야 한다. 한 전사기가
    /// 코드스위칭 발화를 하나의 긴 세그먼트로 뭉개도, 자기 언어가 아닌 구간은
    /// 낮은 신뢰도 조각으로 남기 때문이다. 실측 예 (한→영→한 오디오, ko 전사기):
    ///
    /// ```
    /// 0.00~0.78s conf=0.905 '안녕하세요.'   ← 한국어 구간, 높음
    /// 2.70~6.00s conf=0.562 ' 네,'          ← 영어 구간을 뭉갠 조각, 낮음
    /// 6.48~6.96s conf=0.903 ' 그럼'         ← 한국어 구간, 높음
    /// ```
    struct Token: Sendable {
        let text: String
        let range: CMTimeRange
        let confidence: Double?
    }

    /// `ko`, `en` 같은 짧은 언어 코드. UI 배지에 쓴다.
    var languageCode: String? {
        guard let localeIdentifier else { return nil }
        return Locale(identifier: localeIdentifier).language.languageCode?.identifier
    }

    var start: TimeInterval { range.start.seconds }
    var end: TimeInterval { range.end.seconds }

    /// 잠정 결과가 확정될 때 텍스트만 갈아끼운다. id를 유지해서 SwiftUI가
    /// 행을 지우고 새로 만드는 대신 제자리에서 갱신하게 한다.
    func replacingText(
        _ newText: String,
        isFinal: Bool,
        confidence: Double?,
        localeIdentifier: String? = nil
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            speaker: speaker,
            range: range,
            text: newText,
            isFinal: isFinal,
            confidence: confidence,
            localeIdentifier: localeIdentifier ?? self.localeIdentifier,
            tokens: tokens
        )
    }
}

extension TranscriptSegment {
    /// JSONL 한 줄로 직렬화되는 형태. CMTimeRange는 Codable이 아니라 초 단위로 눌러 담는다.
    struct Record: Codable, Sendable {
        let id: UUID
        let speaker: Speaker
        let start: TimeInterval
        let end: TimeInterval
        let text: String
        let confidence: Double?
        let locale: String?
    }

    var record: Record {
        Record(
            id: id,
            speaker: speaker,
            start: start,
            end: end,
            text: text,
            confidence: confidence,
            locale: localeIdentifier
        )
    }
}

/// `00:04:12` 형태의 타임코드.
func formatTimecode(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "00:00:00" }
    let total = Int(seconds.rounded(.down))
    return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
}
