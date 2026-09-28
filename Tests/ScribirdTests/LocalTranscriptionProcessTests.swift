import XCTest
@testable import Scribird

final class LocalTranscriptionProcessTests: XCTestCase {
    func test_workerFailure_isNotReportedAsSuccess() async throws {
        do {
            try await LocalTranscriptionProcess.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo 'worker failed' >&2; exit 7"]
            ) { _ in }
            XCTFail("Worker exit failure must propagate")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("worker failed"))
        }
    }

    func test_cancellation_terminatesAndWaitsForOwnedWorker() async throws {
        let (ready, continuation) = AsyncStream<Void>.makeStream()
        let pid = LockedBox<Int32?>(nil)
        let task = Task {
            defer { continuation.finish() }
            try await LocalTranscriptionProcess.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo $$; exec sleep 60"]
            ) { line in
                pid.mutate { $0 = Int32(line) }
                continuation.yield()
            }
        }
        for await _ in ready { break }
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancelled worker must fail")
        } catch {
            XCTAssertTrue(task.isCancelled)
            let processID = try XCTUnwrap(pid.value)
            XCTAssertEqual(kill(processID, 0), -1)
            XCTAssertEqual(errno, ESRCH)
        }
    }
}
