import CoreMedia
import Foundation
import XCTest
@testable import Scribird

/// 세션 경계에서 시간축을 옮기는 규칙 테스트.
///
/// 검증 대상 계약: 경계를 넘은 발화는 새 세션 안에서 0부터 센다 / 경계에 걸친 발화는
/// 새 세션의 첫 발화로 눌러 담는다 / 토큰 시간축도 함께 옮겨져 중재가 어긋나지 않는다.
///
/// 경계에서 캡처를 끊지 않기 때문에 전사기가 주는 시각은 캡처 시작 기준으로 계속
/// 커진다. 이 변환이 없으면 두 번째 회의의 회의록이 `01:23:45`부터 시작한다.
final class SessionBoundaryTests: XCTestCase {

    private func segment(
        _ start: Double,
        _ end: Double,
        tokens: [TranscriptSegment.Token] = []
    ) -> TranscriptSegment {
        TranscriptSegment(
            speaker: .me,
            range: Fixture.range(start, end),
            text: "발화",
            isFinal: true,
            confidence: 0.9,
            localeIdentifier: "ko-KR",
            tokens: tokens
        )
    }

    // MARK: - 시간축 이동

    /// 한 시간 넘게 켜 둔 뒤 경계를 끊은 상황.
    ///
    /// 회의를 3720초(62분) 진행한 뒤 경계를 끊으면, 다음 회의의 첫 발화는 캡처
    /// 기준으로 3725초에 오지만 새 회의록에서는 5초여야 한다.
    func test_segmentAfterBoundary_startsFromZeroInNewSession() {
        let raw = segment(3725, 3728)

        let shifted = raw.shiftingTime(by: 3720)

        XCTAssertEqual(shifted.start, 5, accuracy: 0.01,
                       "경계 이후 발화가 새 세션 기준으로 옮겨지지 않았다")
        XCTAssertEqual(shifted.end, 8, accuracy: 0.01)
    }

    func test_shiftingTime_preservesDuration() {
        let shifted = segment(3725, 3728).shiftingTime(by: 3720)

        XCTAssertEqual(shifted.end - shifted.start, 3, accuracy: 0.01,
                       "시간축을 옮기면서 발화 길이가 변형됐다")
    }

    func test_shiftingTime_preservesIdentityAndText() {
        let raw = segment(3725, 3728)

        let shifted = raw.shiftingTime(by: 3720)

        XCTAssertEqual(shifted.id, raw.id, "시간축 이동이 세그먼트 신원을 바꿨다")
        XCTAssertEqual(shifted.text, raw.text)
        XCTAssertEqual(shifted.speaker, raw.speaker)
        XCTAssertEqual(shifted.localeIdentifier, raw.localeIdentifier)
        XCTAssertEqual(shifted.isFinal, raw.isFinal)
    }

    // MARK: - 경계에 걸친 발화

    /// 발화 도중에 경계를 끊으면 시작이 음수가 된다.
    ///
    /// 그 발화의 앞부분은 이미 이전 세션에 기록됐으므로, 새 세션에서는 남은 부분만
    /// 0부터 센다. 음수 시각을 그대로 두면 회의록 정렬과 타임코드가 깨진다.
    func test_segmentStraddlingBoundary_isClampedToZero() {
        // 경계는 100초. 발화는 98초에 시작해 103초에 끝났다.
        let shifted = segment(98, 103).shiftingTime(by: 100)

        XCTAssertEqual(shifted.start, 0, accuracy: 0.01,
                       "경계 이전으로 넘어간 시각이 음수로 남았다")
        XCTAssertEqual(shifted.end, 3, accuracy: 0.01,
                       "경계 이후 남은 구간의 길이가 보존되지 않았다")
    }

    /// 경계보다 완전히 앞선 발화는 길이가 0으로 접힌다.
    ///
    /// 이 발화는 이미 이전 세션이 가져갔으므로 새 세션에서 시간을 차지하면 안 된다.
    func test_segmentEntirelyBeforeBoundary_collapsesToZeroLength() {
        let shifted = segment(10, 20).shiftingTime(by: 100)

        XCTAssertEqual(shifted.start, 0, accuracy: 0.01)
        XCTAssertEqual(shifted.end, 0, accuracy: 0.01,
                       "이전 세션의 발화가 새 세션에서 시간을 차지한다")
    }

    func test_shiftingByZero_leavesTimingUnchanged() {
        let shifted = segment(12.5, 15).shiftingTime(by: 0)

        XCTAssertEqual(shifted.start, 12.5, accuracy: 0.01)
        XCTAssertEqual(shifted.end, 15, accuracy: 0.01)
    }

    // MARK: - 토큰 시간축

    /// 토큰도 함께 옮겨져야 한다.
    ///
    /// 언어 중재는 토큰 시간축으로 구역을 나눈다. 세그먼트만 옮기고 토큰을 두면
    /// 경계 이후의 다국어 회의에서 구역 계산이 세그먼트 범위와 어긋난다.
    func test_shiftingTime_movesTokensToo() {
        let raw = segment(3725, 3728, tokens: [
            Fixture.token("안녕", 3725, 3726, 0.9),
            Fixture.token("하세요", 3726.5, 3728, 0.88),
        ])

        let shifted = raw.shiftingTime(by: 3720)

        XCTAssertEqual(shifted.tokens.count, 2)
        XCTAssertEqual(shifted.tokens[0].range.start.seconds, 5, accuracy: 0.01,
                       "토큰 시간축이 세그먼트와 함께 옮겨지지 않았다")
        XCTAssertEqual(shifted.tokens[1].range.start.seconds, 6.5, accuracy: 0.01)
        XCTAssertEqual(shifted.tokens[1].range.end.seconds, 8, accuracy: 0.01)
    }

    func test_shiftingTime_preservesTokenTextAndConfidence() {
        let raw = segment(3725, 3726, tokens: [Fixture.token("안녕", 3725, 3726, 0.905)])

        let shifted = raw.shiftingTime(by: 3720)

        XCTAssertEqual(shifted.tokens[0].text, "안녕")
        XCTAssertEqual(shifted.tokens[0].confidence ?? 0, 0.905, accuracy: 0.001)
    }

    /// 옮긴 세그먼트가 회의록에 기록될 때 타임코드도 새 세션 기준이어야 한다.
    func test_shiftedSegment_rendersNewSessionTimecode() {
        // 캡처 기준 1시간 2분 5초 → 새 세션에서는 5초.
        let shifted = segment(3725, 3728).shiftingTime(by: 3720)

        XCTAssertEqual(formatTimecode(shifted.start), "00:00:05",
                       "회의록 타임코드가 캡처 시작 기준으로 남았다")
    }

    // MARK: - 경계 이전 결과 걸러내기

    /// 경계에서 미확정 발화를 이전 세션에 넣은 뒤에도 전사기는 같은 구간의 확정
    /// 결과를 보낸다. 그것을 새 세션에도 담으면 같은 말이 두 회의록에 남는다.
    ///
    /// 판정 기준은 "경계 이전에서 끝났는가"다. 시작 시점으로 판정하면 경계에 걸친
    /// 발화까지 버려져 새 세션의 도입부가 사라진다.
    @MainActor
    func test_resultEndingBeforeBoundary_isDiscardedAsDuplicate() {
        let late = segment(94, 98)

        XCTAssertTrue(
            MeetingRecorder.isAlreadyRecorded(late, boundaryAt: 100),
            "경계 이전에서 끝난 결과가 걸러지지 않아 같은 말이 두 회의록에 남는다"
        )
    }

    /// 경계에 걸친 발화는 뒷부분이 새 세션의 내용이므로 살려야 한다.
    @MainActor
    func test_resultStraddlingBoundary_isKept() {
        let straddling = segment(98, 103)

        XCTAssertFalse(
            MeetingRecorder.isAlreadyRecorded(straddling, boundaryAt: 100),
            "경계에 걸친 발화가 중복으로 판정되면 새 세션 도입부가 사라진다"
        )
    }

    /// 경계를 넘지 않은 세션에서는 아무것도 걸러내지 않는다.
    @MainActor
    func test_beforeAnyBoundary_nothingIsDiscarded() {
        XCTAssertFalse(
            MeetingRecorder.isAlreadyRecorded(segment(0, 3), boundaryAt: 0),
            "첫 세션의 발화가 걸러지면 회의록이 비어 버린다"
        )
    }

    // MARK: - 타임라인과의 결합

    /// 옮긴 세그먼트들이 새 세션 타임라인에서 시간순으로 정렬돼야 한다.
    @MainActor
    func test_shiftedSegments_sortCorrectlyInNewTimeline() {
        let timeline = TranscriptTimeline()
        let offset = 3720.0

        // 경계에 걸친 발화(0으로 접힘)와 그 뒤 발화를 순서대로 넣는다.
        timeline.ingest(segment(3718, 3722).shiftingTime(by: offset))
        timeline.ingest(segment(3725, 3728).shiftingTime(by: offset))

        let starts = timeline.finalized.map(\.start)
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(starts[0], 0, accuracy: 0.01)
        XCTAssertEqual(starts[1], 5, accuracy: 0.01)
    }
}
