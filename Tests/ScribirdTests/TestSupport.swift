import CoreMedia
import Foundation
@testable import Scribird

/// 테스트에서 쓰는 세그먼트·토큰 조립 헬퍼.
///
/// 시간은 초 단위로 받아 고정 timescale의 `CMTime`으로 바꾼다. 실측 로그가 초
/// 단위로 기록돼 있어 테스트도 같은 단위로 읽히게 하려는 것이다.
enum Fixture {
    static let timescale: CMTimeScale = 1000

    static func time(_ seconds: Double) -> CMTime {
        CMTime(value: CMTimeValue((seconds * Double(timescale)).rounded()), timescale: timescale)
    }

    static func range(_ start: Double, _ end: Double) -> CMTimeRange {
        CMTimeRange(start: time(start), end: time(end))
    }

    static func token(
        _ text: String,
        _ start: Double,
        _ end: Double,
        _ confidence: Double?
    ) -> TranscriptSegment.Token {
        TranscriptSegment.Token(text: text, range: range(start, end), confidence: confidence)
    }

    /// 확정 세그먼트 하나. 토큰을 주면 그 범위를 합쳐 세그먼트 범위로 쓴다.
    static func segment(
        speaker: Speaker = .remote,
        locale: String?,
        tokens: [TranscriptSegment.Token],
        confidence: Double? = nil,
        isFinal: Bool = true
    ) -> TranscriptSegment {
        let span: CMTimeRange = tokens.isEmpty
            ? range(0, 0)
            : tokens.dropFirst().reduce(tokens[0].range) { $0.union($1.range) }
        let averaged = confidence ?? Self.durationWeightedMean(tokens)
        return TranscriptSegment(
            speaker: speaker,
            range: span,
            text: tokens.map(\.text).joined(),
            isFinal: isFinal,
            confidence: averaged,
            localeIdentifier: locale,
            tokens: tokens
        )
    }

    /// 토큰 없이 세그먼트 하나 (audioTimeRange를 못 받은 경우 재현용).
    static func segmentWithoutTokens(
        speaker: Speaker = .remote,
        locale: String?,
        text: String,
        _ start: Double,
        _ end: Double,
        confidence: Double?
    ) -> TranscriptSegment {
        TranscriptSegment(
            speaker: speaker,
            range: range(start, end),
            text: text,
            isFinal: true,
            confidence: confidence,
            localeIdentifier: locale,
            tokens: []
        )
    }

    private static func durationWeightedMean(_ tokens: [TranscriptSegment.Token]) -> Double? {
        var weighted = 0.0
        var total = 0.0
        for token in tokens {
            guard let confidence = token.confidence else { continue }
            let weight = max(token.range.duration.seconds, 0.01)
            weighted += confidence * weight
            total += weight
        }
        return total > 0 ? weighted / total : nil
    }
}

/// 오디오 콜백·Core Audio 리스너 큐에서 온 값을 테스트가 안전하게 모으는 상자.
///
/// 그 콜백들은 메인 액터 밖에서 오므로 지역 `var`를 그대로 캡처하면 Swift 6 데이터 경합
/// 검사가 잡는다. 검사를 약화하는 대신 락으로 감싼다 — 소스가 쓰는 것과 같은 패턴이다.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        lock.withLock { stored }
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.withLock { body(&stored) }
    }
}

extension Array where Element == TranscriptSegment {
    /// 결과를 `[locale] 텍스트` 형태로 눌러 담아 비교하기 쉽게 만든다.
    var digest: [String] {
        map { segment in
            let code = segment.localeIdentifier?.split(separator: "-").first.map(String.init) ?? "?"
            return "[\(code)] \(segment.text)"
        }
    }

    var joinedText: String {
        map(\.text).joined(separator: " | ")
    }
}
