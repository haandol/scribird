import XCTest
@testable import Scribird

@MainActor
final class LanguageArbiterSubmissionTests: XCTestCase {
    /// Reproduces the probe where a late Korean segment bridges two English rounds.
    func test_bridgingFinal_competesWithEveryOverlappingRound() async {
        let first = Fixture.segmentWithoutTokens(locale: "en-US", text: "first", 0, 1, confidence: 0.5)
        let second = Fixture.segmentWithoutTokens(locale: "en-US", text: "second", 2, 3, confidence: 0.5)
        let bridge = Fixture.segmentWithoutTokens(locale: "ko-KR", text: "승자", 0, 3, confidence: 0.9)
        for input in [[first, second, bridge], [second, first, bridge], [bridge, first, second]] {
            var decisions: [TranscriptSegment] = []
            let arbiter = LanguageArbiter { decisions.append($0) }
            for segment in input { XCTAssertNil(arbiter.submit(segment)) }
            await arbiter.flush()
            await arbiter.flush()
            XCTAssertEqual(decisions.map(\.text), ["승자"])
        }
    }

    /// The measured .449 rejection must not hide display-only provisional text.
    func test_provisionalConfidence_passesThroughWithoutFinalizing() async {
        var decisions: [TranscriptSegment] = []
        let arbiter = LanguageArbiter { decisions.append($0) }
        for confidence: Double? in [nil, 0, 0.449, 0.45, 0.9] {
            let base = Fixture.segmentWithoutTokens(locale: "en-US", text: "pending", 0, 1, confidence: confidence)
            let provisional = base.replacingText(base.text, isFinal: false, confidence: confidence)
            XCTAssertEqual(arbiter.submit(provisional)?.id, provisional.id)
        }
        await arbiter.flush()
        XCTAssertTrue(decisions.isEmpty)
    }

    /// Separate utterances must survive; resetting removes only the pending work.
    func test_disjointFinals_flushOnceAndResetDiscardsPending() async {
        var decisions: [TranscriptSegment] = []
        let arbiter = LanguageArbiter { decisions.append($0) }
        let first = Fixture.segmentWithoutTokens(locale: "en-US", text: "first", 0, 1, confidence: 0.5)
        let second = Fixture.segmentWithoutTokens(locale: "ko-KR", text: "second", 2, 3, confidence: 0.9)
        _ = arbiter.submit(first)
        _ = arbiter.submit(second)
        await arbiter.flush()
        XCTAssertEqual(Set(decisions.map(\.text)), Set(["first", "second"]))
        _ = arbiter.submit(first)
        arbiter.reset()
        await arbiter.flush()
        XCTAssertEqual(decisions.count, 2)
    }
}
