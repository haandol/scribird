import XCTest
@testable import Scribird

/// 두 소스 결과의 시간축 병합 테스트.
///
/// 검증 대상 계약: 잠정 결과는 화자당 한 칸을 덮어쓰고 저장되지 않는다 / 확정 결과만
/// 저장 대상으로 반환된다 / 뒤늦게 도착한 발화도 제자리에 꽂힌다 / 종료 시 미확정
/// 발화도 잃지 않는다.
@MainActor
final class TranscriptTimelineTests: XCTestCase {

    private func volatileSegment(
        _ speaker: Speaker, _ text: String, _ start: Double, _ end: Double
    ) -> TranscriptSegment {
        TranscriptSegment(
            speaker: speaker, range: Fixture.range(start, end),
            text: text, isFinal: false, confidence: 0.8, localeIdentifier: "ko-KR"
        )
    }

    private func finalSegment(
        _ speaker: Speaker, _ text: String, _ start: Double, _ end: Double
    ) -> TranscriptSegment {
        TranscriptSegment(
            speaker: speaker, range: Fixture.range(start, end),
            text: text, isFinal: true, confidence: 0.9, localeIdentifier: "ko-KR"
        )
    }

    // MARK: - 잠정 결과

    func test_volatileSegment_isNotReturnedForPersistence() {
        let timeline = TranscriptTimeline()

        let persisted = timeline.ingest(volatileSegment(.me, "안녕", 0, 1))

        XCTAssertNil(persisted, "잠정 결과는 저장 대상이 아니다")
        XCTAssertEqual(timeline.displaySegments.count, 1, "화면에는 보여야 한다")
    }

    func test_successiveVolatileSegments_overwriteOneSlotPerSpeaker() {
        let timeline = TranscriptTimeline()

        timeline.ingest(volatileSegment(.me, "안", 0, 0.5))
        timeline.ingest(volatileSegment(.me, "안녕", 0, 0.8))
        timeline.ingest(volatileSegment(.me, "안녕하세요", 0, 1.2))

        XCTAssertEqual(timeline.displaySegments.count, 1, "같은 화자의 잠정 결과가 누적됐다")
        XCTAssertEqual(timeline.displaySegments[0].text, "안녕하세요")
    }

    func test_volatileSegment_keepsIdentityAcrossUpdates() {
        let timeline = TranscriptTimeline()

        timeline.ingest(volatileSegment(.me, "안", 0, 0.5))
        let firstID = timeline.displaySegments[0].id
        timeline.ingest(volatileSegment(.me, "안녕하세요", 0, 1.2))
        let secondID = timeline.displaySegments[0].id

        // id가 유지돼야 화면이 행을 지우고 새로 만드는 대신 제자리에서 갱신한다.
        XCTAssertEqual(firstID, secondID)
    }

    func test_twoSpeakers_haveIndependentVolatileSlots() {
        let timeline = TranscriptTimeline()

        timeline.ingest(volatileSegment(.me, "제가 말하는 중", 0, 1))
        timeline.ingest(volatileSegment(.remote, "상대방도 말하는 중", 0.5, 1.5))

        XCTAssertEqual(timeline.displaySegments.count, 2, "화자별로 한 칸씩 있어야 한다")
    }

    // MARK: - 확정 결과

    func test_finalSegment_isReturnedForPersistence() {
        let timeline = TranscriptTimeline()

        let persisted = timeline.ingest(finalSegment(.me, "안녕하세요.", 0, 1.2))

        XCTAssertNotNil(persisted, "확정 결과는 저장돼야 한다")
        XCTAssertEqual(persisted?.text, "안녕하세요.")
    }

    func test_finalSegment_clearsThatSpeakersVolatileSlot() {
        let timeline = TranscriptTimeline()

        timeline.ingest(volatileSegment(.me, "안녕하", 0, 1.0))
        timeline.ingest(finalSegment(.me, "안녕하세요.", 0, 1.2))

        XCTAssertEqual(timeline.displaySegments.count, 1, "잠정 칸이 남아 발화가 중복됐다")
        XCTAssertTrue(timeline.displaySegments[0].isFinal)
    }

    func test_finalSegment_doesNotClearOtherSpeakersVolatileSlot() {
        let timeline = TranscriptTimeline()

        timeline.ingest(volatileSegment(.remote, "상대방 진행 중", 0.5, 2.0))
        timeline.ingest(finalSegment(.me, "제 발언 확정.", 0, 1.2))

        XCTAssertEqual(timeline.displaySegments.count, 2,
                       "한 화자의 확정이 다른 화자의 진행 중 발화를 지웠다")
    }

    // MARK: - 시간순 정렬 (두 소스 비동기 도착)

    func test_lateArrivingSegment_isInsertedInTimeOrder() {
        let timeline = TranscriptTimeline()

        timeline.ingest(finalSegment(.me, "세번째", 5.0, 6.0))
        timeline.ingest(finalSegment(.remote, "첫번째", 1.0, 2.0))
        timeline.ingest(finalSegment(.me, "두번째", 3.0, 4.0))

        XCTAssertEqual(timeline.displaySegments.map(\.text),
                       ["첫번째", "두번째", "세번째"],
                       "뒤늦게 도착한 발화가 제자리에 꽂히지 않았다")
    }

    func test_segmentsWithIdenticalStart_areAllKept() {
        let timeline = TranscriptTimeline()

        timeline.ingest(finalSegment(.me, "동시 발화 A", 2.0, 3.0))
        timeline.ingest(finalSegment(.remote, "동시 발화 B", 2.0, 3.0))

        XCTAssertEqual(timeline.displaySegments.count, 2, "동시 시작 발화가 유실됐다")
    }

    // MARK: - 종료 처리

    func test_flushPending_promotesVolatileToFinal() {
        let timeline = TranscriptTimeline()
        timeline.ingest(volatileSegment(.me, "말하는 중이었다", 0, 1.5))

        let flushed = timeline.flushPending()

        XCTAssertEqual(flushed.count, 1, "종료 시 미확정 발화를 잃었다")
        XCTAssertTrue(flushed[0].isFinal, "저장되려면 확정 상태여야 한다")
        XCTAssertEqual(flushed[0].text, "말하는 중이었다")
    }

    func test_flushPending_emptiesPendingSlots() {
        let timeline = TranscriptTimeline()
        timeline.ingest(volatileSegment(.me, "A", 0, 1))
        timeline.ingest(volatileSegment(.remote, "B", 0, 1))

        _ = timeline.flushPending()

        XCTAssertTrue(timeline.flushPending().isEmpty, "두 번 flush하면 중복 저장된다")
    }

    func test_flushPending_keepsFlushedSegmentsInTimeline() {
        let timeline = TranscriptTimeline()
        timeline.ingest(finalSegment(.me, "확정된 것", 0, 1))
        timeline.ingest(volatileSegment(.remote, "미확정이던 것", 2, 3))

        _ = timeline.flushPending()

        XCTAssertEqual(timeline.displaySegments.map(\.text), ["확정된 것", "미확정이던 것"])
    }

    func test_flushPending_withNothingPending_returnsEmpty() {
        let timeline = TranscriptTimeline()
        timeline.ingest(finalSegment(.me, "확정", 0, 1))

        XCTAssertTrue(timeline.flushPending().isEmpty)
    }

    // MARK: - 리셋

    func test_reset_clearsEverything() {
        let timeline = TranscriptTimeline()
        timeline.ingest(finalSegment(.me, "확정", 0, 1))
        timeline.ingest(volatileSegment(.remote, "진행 중", 2, 3))

        timeline.reset()

        XCTAssertTrue(timeline.displaySegments.isEmpty, "이전 세션 발화가 남았다")
    }

    // MARK: - 표시 순서

    func test_displaySegments_placeVolatileAfterFinalized() {
        let timeline = TranscriptTimeline()

        timeline.ingest(finalSegment(.me, "확정된 발화", 0, 1))
        timeline.ingest(volatileSegment(.remote, "지금 말하는 중", 1.5, 2.5))

        // 진행 중인 발화는 확정분 뒤에 붙어야 대화가 자연스럽게 읽힌다.
        XCTAssertEqual(timeline.displaySegments.map(\.isFinal), [true, false])
    }
}
