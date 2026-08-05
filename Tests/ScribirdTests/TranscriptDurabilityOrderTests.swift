import CoreMedia
import Foundation
import XCTest
@testable import Scribird

/// 화면에 보인 발화가 산출물에 남는지 — 저장 순서 계약 테스트.
///
/// 검증 대상 계약: 확정 발화의 기록은 화면 반영과 분리되어 미뤄지지 않는다 / 읽기용 회의록
/// 생성 전에 확정된 모든 발화의 기록이 끝나 있다 / 세션이 닫힌 뒤 도착한 확정 발화를 조용히
/// 버리지 않는다.
///
/// **이 테스트는 관측된 유실에서 나왔다.** 화면에는 전사된 문장이 보이는데 `transcript.jsonl`과
/// `transcript.md` 어느 쪽에도 없는 경우가 있었다. 원인은 확정 발화의 기록을 별도 태스크로
/// 미룬 것이다 — 그 태스크가 세션이 닫힌 뒤 실행되면 append는 닫힌 핸들 때문에 버려지고,
/// 읽기용 회의록은 그 발화가 빠진 목록으로 이미 생성돼 있어 **두 형식에서 함께 사라진다.**
/// 즉시 기록이 담당하던 이중화가 그 순서에서는 작동하지 않는다.
///
/// 실측: 같은 순서를 재현한 프로브에서 **200회 중 200회 유실**됐고, 화면에 5개가 표시된 시점의
/// 저장분이 0개였다 — 드물게 지는 경합이 아니라 기본적으로 지는 순서였다.
final class TranscriptDurabilityOrderTests: XCTestCase {

    private var sandbox: URL!
    private var originalHome: String?

    override func setUpWithError() throws {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "scribird-order-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", sandbox.path, 1)
    }

    override func tearDownWithError() throws {
        if let originalHome { setenv("HOME", originalHome, 1) }
        try? FileManager.default.removeItem(at: sandbox)
    }

    /// 기본 저장 루트에 세션을 연다. `HOME`을 임시 디렉터리로 바꿔 두었으므로 그 안으로 들어온다.
    private func makeStore() throws -> TranscriptStore {
        try TranscriptStore(
            startedAt: Date(),
            root: TranscriptRootLocation.standardDirectory()
        )
    }

    private func segment(
        _ text: String, _ start: Double, _ end: Double,
        locale: String? = "ko-KR"
    ) -> TranscriptSegment {
        TranscriptSegment(
            speaker: .me, range: Fixture.range(start, end),
            text: text, isFinal: true, confidence: 0.9, localeIdentifier: locale
        )
    }

    private func markdown(_ directory: URL) throws -> String {
        try String(contentsOf: directory.appending(path: "transcript.md"), encoding: .utf8)
    }

    private func jsonl(_ directory: URL) throws -> String {
        try String(contentsOf: directory.appending(path: "transcript.jsonl"), encoding: .utf8)
    }

    // MARK: - 세션이 닫힌 뒤의 도착

    /// **닫힌 뒤 도착한 발화는 조용히 사라지지 않는다.**
    ///
    /// 늦게 도착하는 것 자체는 정상이지만, 흔적 없이 버리면 유실이 일어난 사실조차 알 수 없다.
    /// 이 카운터가 순서 위반을 드러내는 유일한 신호다.
    func test_appendAfterFinalize_isCountedNotSilentlyDropped() async throws {
        let store = try makeStore()
        await store.append(segment("회의 중 발화입니다.", 0, 1.5))
        _ = await store.finalize(audioFiles: [])

        await store.append(segment("닫힌 뒤 도착했습니다.", 2, 3))

        let dropped = await store.droppedAfterFinalize
        XCTAssertEqual(dropped, 1,
                       "세션이 닫힌 뒤 도착한 발화가 아무 흔적 없이 버려졌다 — 유실을 감지할 방법이 없다")
    }

    /// 닫힌 뒤 도착한 발화는 **두 형식 모두에서** 빠진다.
    ///
    /// 이것이 관측된 증상의 정체다. 한쪽이라도 남으면 복원할 수 있지만, 이 순서에서는 즉시
    /// 기록도 읽기용 회의록도 그 발화를 갖지 못한다.
    func test_appendAfterFinalize_missesBothOutputs() async throws {
        let store = try makeStore()
        await store.append(segment("남아야 하는 발화.", 0, 1))
        let directory = await store.finalize(audioFiles: [])

        await store.append(segment("사라지는 발화.", 2, 3))

        XCTAssertFalse(try jsonl(directory).contains("사라지는 발화."),
                       "닫힌 세션에 기록됐다 — 이 테스트의 전제가 깨졌다")
        XCTAssertFalse(try markdown(directory).contains("사라지는 발화."),
                       "닫힌 세션의 회의록에 나타났다 — 이 테스트의 전제가 깨졌다")
        // 그래서 순서를 지키는 것이 유일한 방어다.
        XCTAssertTrue(try jsonl(directory).contains("남아야 하는 발화."))
        XCTAssertTrue(try markdown(directory).contains("남아야 하는 발화."))
    }

    /// 정상 순서에서는 하나도 버려지지 않는다.
    func test_appendBeforeFinalize_dropsNothing() async throws {
        let store = try makeStore()

        for index in 0..<5 {
            await store.append(segment("발화\(index)", Double(index), Double(index) + 0.5))
        }
        let directory = await store.finalize(audioFiles: [])

        let dropped = await store.droppedAfterFinalize
        XCTAssertEqual(dropped, 0, "정상 순서인데도 발화가 버려졌다")

        let lines = try jsonl(directory).split(separator: "\n")
        XCTAssertEqual(lines.count, 5, "확정 발화 수와 기록된 줄 수가 다르다")
        for index in 0..<5 {
            XCTAssertTrue(try markdown(directory).contains("발화\(index)"),
                          "발화\(index)가 읽기용 회의록에 없다")
        }
    }

    // MARK: - 확정 발화의 기록이 미뤄지지 않는가

    /// **화면에 표시된 발화는 기록도 끝나 있다.**
    ///
    /// 관측된 증상의 직접 원인이 이 순서였다. 타임라인에 넣어 화면에 반영한 뒤 기록을 별도
    /// 태스크로 미루면, 그 태스크가 실행되기 전에 세션이 닫힐 수 있다.
    @MainActor
    func test_committing_persistsBeforeReturning() async throws {
        let store = try makeStore()
        let timeline = TranscriptTimeline()

        await MeetingRecorder.commit(segment("화면에 보인 발화.", 0, 1.5), to: timeline, store: store)

        // 반환된 직후 — 아무것도 더 기다리지 않고 — 이미 디스크에 있어야 한다.
        let directory = await store.sessionDirectory
        XCTAssertTrue(try jsonl(directory).contains("화면에 보인 발화."),
                      "화면에는 반영됐는데 기록은 아직 끝나지 않았다 — 지금 세션이 닫히면 유실된다")
        XCTAssertEqual(timeline.displaySegments.count, 1, "화면 반영이 누락됐다")
    }

    /// 종료가 곧바로 이어져도 유실되지 않는다.
    ///
    /// 이것이 실제 시나리오다 — 회의 끝에 짧은 발화가 확정되고 사용자가 바로 중지를 누른다.
    func test_committingThenImmediatelyFinalizing_losesNothing() async throws {
        let store = try makeStore()
        let timeline = await TranscriptTimeline()

        for index in 0..<5 {
            await MeetingRecorder.commit(
                segment("발화\(index)", Double(index), Double(index) + 0.5),
                to: timeline,
                store: store
            )
        }
        // 기다리는 것 없이 곧바로 종료한다.
        let directory = await store.finalize(audioFiles: [])

        let dropped = await store.droppedAfterFinalize
        XCTAssertEqual(dropped, 0, "\(dropped)개가 세션이 닫힌 뒤에 도착했다")

        let displayed = await timeline.displaySegments.count
        let lines = try jsonl(directory).split(separator: "\n").count
        XCTAssertEqual(lines, displayed,
                       "화면 \(displayed)개 vs 기록 \(lines)줄 — 화면에 보인 발화가 파일에 없다")
        for index in 0..<5 {
            XCTAssertTrue(try markdown(directory).contains("발화\(index)"),
                          "발화\(index)가 읽기용 회의록에 없다")
        }
    }

    // MARK: - 중재기가 기다려지는가

    /// **중재기의 확정을 기다려야 그 발화가 산출물에 들어간다.**
    ///
    /// 다국어 회의에서는 확정 발화가 유예 후 중재기를 통해 나온다. 종료 경로가 그 확정을
    /// 기다리지 않으면 마지막 발화들이 회의록 생성 이후에 도착한다 — 관측된 유실이 회의 끝에
    /// 몰린 짧은 발화에서 나타난 이유다.
    func test_flushingArbiter_completesBeforeReturning() async throws {
        let store = try makeStore()
        let arbiter = await LanguageArbiter { segment in
            await store.append(segment)
        }

        _ = await arbiter.submit(segment("중재를 기다리는 발화.", 0, 1.5))
        // 유예 타이머가 끝나기 전에 종료를 흉내낸다.
        await arbiter.flush()

        // flush가 반환된 시점에 이미 기록돼 있어야 한다 — 여기서 finalize가 이어진다.
        let directory = await store.finalize(audioFiles: [])

        XCTAssertTrue(try jsonl(directory).contains("중재를 기다리는 발화."),
                      "중재 확정을 기다리지 않아 발화가 기록 전에 세션이 닫혔다")
        XCTAssertTrue(try markdown(directory).contains("중재를 기다리는 발화."),
                      "중재로 확정된 발화가 읽기용 회의록에 없다")
        let dropped = await store.droppedAfterFinalize
        XCTAssertEqual(dropped, 0, "중재 확정이 세션이 닫힌 뒤에 도착했다")
    }

    /// 여러 발화가 밀려 있어도 전부 기다린다.
    ///
    /// 하나만 확인하면 "마지막 하나만 기다린다"는 구현도 통과한다.
    func test_flushingArbiter_persistsEveryPendingSegment() async throws {
        let store = try makeStore()
        let arbiter = await LanguageArbiter { segment in
            await store.append(segment)
        }

        // 시간이 겹치지 않게 넣어 각각 별개 라운드가 되게 한다.
        for index in 0..<4 {
            let start = Double(index) * 10
            _ = await arbiter.submit(segment("대기\(index)", start, start + 1))
        }
        await arbiter.flush()
        let directory = await store.finalize(audioFiles: [])

        let contents = try jsonl(directory)
        for index in 0..<4 {
            XCTAssertTrue(contents.contains("대기\(index)"),
                          "대기\(index)가 기록되지 않았다 — 밀려 있던 발화를 전부 기다리지 않는다")
        }
        let dropped = await store.droppedAfterFinalize
        XCTAssertEqual(dropped, 0, "\(dropped)개가 세션이 닫힌 뒤에 도착했다")
    }
}
