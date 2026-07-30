import CoreMedia
import XCTest
@testable import Scribird

/// 세그먼트 모델과 타임코드 표기 테스트.
final class TranscriptSegmentTests: XCTestCase {

    // MARK: - 언어 코드 (UI 배지)

    func test_languageCode_extractsShortCodeFromLocale() {
        let korean = TranscriptSegment(
            speaker: .me, range: Fixture.range(0, 1), text: "안녕", isFinal: true,
            localeIdentifier: "ko-KR"
        )
        let english = TranscriptSegment(
            speaker: .me, range: Fixture.range(0, 1), text: "Hi", isFinal: true,
            localeIdentifier: "en-US"
        )

        XCTAssertEqual(korean.languageCode, "ko")
        XCTAssertEqual(english.languageCode, "en")
    }

    func test_languageCode_isNilWhenLocaleAbsent() {
        let segment = TranscriptSegment(
            speaker: .me, range: Fixture.range(0, 1), text: "x", isFinal: true
        )

        XCTAssertNil(segment.languageCode)
    }

    func test_languageCode_handlesUnderscoreLocaleForm() {
        // 시스템은 `ko_KR` 형태로 로케일을 돌려주기도 한다.
        let segment = TranscriptSegment(
            speaker: .me, range: Fixture.range(0, 1), text: "안녕", isFinal: true,
            localeIdentifier: "ko_KR"
        )

        XCTAssertEqual(segment.languageCode, "ko")
    }

    // MARK: - 잠정 → 확정 전환

    func test_replacingText_keepsIdentityAndRange() {
        let volatile = TranscriptSegment(
            speaker: .remote, range: Fixture.range(1.0, 2.5), text: "안녕하", isFinal: false,
            confidence: 0.7, localeIdentifier: "ko-KR"
        )

        let finalized = volatile.replacingText("안녕하세요.", isFinal: true, confidence: 0.95)

        // id 유지가 SwiftUI 행 재생성을 막는다.
        XCTAssertEqual(finalized.id, volatile.id)
        XCTAssertEqual(finalized.range, volatile.range)
        XCTAssertEqual(finalized.text, "안녕하세요.")
        XCTAssertTrue(finalized.isFinal)
        XCTAssertEqual(finalized.confidence ?? 0, 0.95, accuracy: 0.001)
    }

    func test_replacingText_retainsLocaleWhenNotOverridden() {
        let segment = TranscriptSegment(
            speaker: .me, range: Fixture.range(0, 1), text: "a", isFinal: false,
            localeIdentifier: "en-US"
        )

        let updated = segment.replacingText("ab", isFinal: true, confidence: nil)

        XCTAssertEqual(updated.localeIdentifier, "en-US")
    }

    // MARK: - JSONL 직렬화

    func test_record_convertsTimeToSeconds() {
        let segment = TranscriptSegment(
            speaker: .remote, range: Fixture.range(12.5, 15.25), text: "발화", isFinal: true,
            confidence: 0.88, localeIdentifier: "ko-KR"
        )

        let record = segment.record

        XCTAssertEqual(record.start, 12.5, accuracy: 0.001)
        XCTAssertEqual(record.end, 15.25, accuracy: 0.001)
        XCTAssertEqual(record.speaker, .remote)
        XCTAssertEqual(record.locale, "ko-KR")
    }

    // MARK: - 타임코드

    func test_formatTimecode_padsToHoursMinutesSeconds() {
        XCTAssertEqual(formatTimecode(0), "00:00:00")
        XCTAssertEqual(formatTimecode(5), "00:00:05")
        XCTAssertEqual(formatTimecode(65), "00:01:05")
        XCTAssertEqual(formatTimecode(3661), "01:01:01")
    }

    func test_formatTimecode_truncatesFraction() {
        XCTAssertEqual(formatTimecode(9.99), "00:00:09")
    }

    func test_formatTimecode_handlesLongMeeting() {
        // 3시간 회의도 표기가 깨지지 않아야 한다.
        XCTAssertEqual(formatTimecode(3 * 3600 + 25 * 60 + 7), "03:25:07")
    }

    func test_formatTimecode_guardsAgainstInvalidInput() {
        // 시간축이 아직 잡히지 않은 상태에서 호출될 수 있다.
        XCTAssertEqual(formatTimecode(-1), "00:00:00")
        XCTAssertEqual(formatTimecode(.nan), "00:00:00")
        XCTAssertEqual(formatTimecode(.infinity), "00:00:00")
    }

    // MARK: - 화자

    func test_speakerRawValue_matchesAudioFileNames() {
        // 원본 오디오 파일 이름이 이 값에서 나오고, 회의록 머리말이 그것을 되읽는다.
        XCTAssertEqual(Speaker.me.rawValue, "me")
        XCTAssertEqual(Speaker.remote.rawValue, "remote")
    }

    func test_speakerDisplayNames_areDistinct() {
        XCTAssertNotEqual(Speaker.me.displayName, Speaker.remote.displayName)
    }

    func test_speakerAllCases_coversBothSources() {
        XCTAssertEqual(Set(Speaker.allCases), [.me, .remote],
                       "소스가 늘면 파이프라인 조립도 함께 바뀌어야 한다")
    }

    // MARK: - 언어 구성

    func test_singleLanguage_needsNoArbitration() {
        XCTAssertFalse(TranscriptionLanguage.korean.needsArbitration)
        XCTAssertFalse(TranscriptionLanguage.english.needsArbitration)
    }

    func test_autoLanguage_needsArbitration() {
        XCTAssertTrue(TranscriptionLanguage.auto.needsArbitration,
                      "두 언어를 함께 돌리면 중재기가 필요하다")
    }

    func test_autoLanguage_requestsBothLocales() {
        XCTAssertEqual(TranscriptionLanguage.auto.locales.count, 2)
    }

    func test_singleLanguage_requestsOneLocale() {
        XCTAssertEqual(TranscriptionLanguage.korean.locales.count, 1)
        XCTAssertEqual(TranscriptionLanguage.english.locales.count, 1)
    }
}
