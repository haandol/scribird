import XCTest
@testable import Scribird

@MainActor
final class FinalizationDeadlineTests: XCTestCase {
    func test_timeout_returnsWhileOperationIgnoresCancellation() async {
        let started = AsyncTestGate()
        let releaseWork = AsyncTestGate()
        let timeout = AsyncTestGate()
        let returned = expectation(description: "시간 초과 반환")
        let workFinished = expectation(description: "실험 작업 정리")
        let task = Task {
            await FinalizationDeadline.wait(until: { await timeout.wait() }) {
                await started.open()
                // 취소해도 직접 열어 주기 전에는 반환하지 않는 작업이다.
                await releaseWork.wait()
                workFinished.fulfill()
            }
            returned.fulfill()
        }

        await started.wait()
        await timeout.open()
        await fulfillment(of: [returned], timeout: 1)
        await releaseWork.open()
        await fulfillment(of: [workFinished], timeout: 1)
        await task.value
    }

    func test_operationFinishes_doesNotWaitForTimeout() async {
        let timeout = AsyncTestGate()
        let returned = expectation(description: "정상 완료")
        let task = Task {
            await FinalizationDeadline.wait(until: { await timeout.wait() }) {}
            returned.fulfill()
        }

        await fulfillment(of: [returned], timeout: 1)
        await timeout.open()
        await task.value
    }

    func test_callerCancelled_doesNotWaitForEitherChild() async {
        let started = AsyncTestGate()
        let release = AsyncTestGate()
        let returned = expectation(description: "호출자 취소")
        let task = Task {
            await FinalizationDeadline.wait(until: { await release.wait() }) {
                await started.open()
                await release.wait()
            }
            returned.fulfill()
        }

        await started.wait()
        task.cancel()
        await fulfillment(of: [returned], timeout: 1)
        await release.open()
        await task.value
    }
}

/// 실제 시간이나 sleep 없이 비동기 작업의 진행 지점을 제어한다.
actor AsyncTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
