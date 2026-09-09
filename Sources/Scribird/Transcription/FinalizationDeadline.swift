import Foundation

enum FinalizationDeadline {
    /// 응답하지 않는 작업을 기다리느라 시간 제한 자체가 무효가 되지 않도록 한다.
    ///
    /// 실측: task group으로 두 작업을 경주시킨 구현은 20ms 제한에도 취소를 무시하는
    /// 250ms 작업이 끝날 때까지 약 266ms를 기다렸다. 그룹은 자식 종료를 기다리므로,
    /// 여기서는 완료 신호만 경주시키고 남은 작업의 취소 완료를 기다리지 않는다.
    static func wait(
        until timeout: @escaping @Sendable () async throws -> Void,
        operation: @escaping @Sendable () async -> Void
    ) async {
        let (completed, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        let work = Task {
            await operation()
            continuation.yield(())
            continuation.finish()
        }
        let timer = Task {
            do {
                try await timeout()
                guard !Task.isCancelled else { return }
                continuation.yield(())
                continuation.finish()
            } catch {
                // 정상 작업이 먼저 끝나거나 호출자가 취소한 경우 타이머도 취소된다.
            }
        }
        defer {
            work.cancel()
            timer.cancel()
            continuation.finish()
        }
        for await _ in completed { break }
    }
}
