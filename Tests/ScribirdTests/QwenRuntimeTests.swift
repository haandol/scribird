import XCTest
@testable import Scribird

final class QwenRuntimeTests: XCTestCase {
    /// Reuses prepared Python without invoking installation and holds an exclusive lock during initial setup.
    func test_managedSetup_commitsReadinessAndReusesWithoutUv() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = LockedBox(0)
        let python = try await QwenRuntime.prepare(runtime: root, supportDirectory: root, variables: [:], uvCandidates: ["/usr/bin/true"]) { _, arguments, environment in
            calls.mutate { $0 += 1 }
            XCTAssertTrue(arguments.contains("--frozen"))
            let lock = open(root.appending(path: "Scribird/QwenRuntime/.setup.lock").path, O_RDWR)
            defer { close(lock) }
            XCTAssertGreaterThanOrEqual(lock, 0)
            XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), -1)
            XCTAssertEqual(errno, EWOULDBLOCK)
            try QwenRuntimeTests.writePython(environment)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: python.deletingLastPathComponent().deletingLastPathComponent().appending(path: ".scribird-ready").path))
        let reused = try await QwenRuntime.prepare(runtime: root, supportDirectory: root, variables: [:], uvCandidates: []) { _, _, _ in
            XCTFail("Ready environment must not invoke uv")
        }
        XCTAssertEqual(python, reused)
        XCTAssertEqual(calls.value, 1)
    }

    /// Marks setup ready only when installation succeeds and produces a complete environment.
    func test_failedOrIncompleteSetup_doesNotCreateReadyMarker() async throws {
        for fails in [true, false] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                _ = try await QwenRuntime.prepare(runtime: root, supportDirectory: root, variables: [:], uvCandidates: ["/usr/bin/true"]) { _, _, _ in
                    if fails { throw CocoaError(.fileWriteNoPermission) }
                }
                XCTFail("Incomplete setup must fail")
            } catch {
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "Scribird/QwenRuntime/0.1.0/.scribird-ready").path))
            }
        }
    }

    /// Retries interrupted setup that left only Python, and allows reacquiring a cancelled installation's
    /// lock.
    func test_interruptedSetup_canRetryWithoutFalseReadiness() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (ready, signal) = AsyncStream<Void>.makeStream()
        let (release, finish) = AsyncStream<Void>.makeStream()
        let task = Task {
            defer { signal.finish() }
            return try await QwenRuntime.prepare(runtime: root, supportDirectory: root, variables: [:], uvCandidates: ["/usr/bin/true"]) { _, _, environment in
                try QwenRuntimeTests.writePython(environment)
                signal.yield()
                for await _ in release { break }
                try Task.checkCancellation()
            }
        }
        for await _ in ready { break }
        task.cancel()
        finish.finish()
        do { _ = try await task.value; XCTFail("Interrupted setup must not succeed") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "Scribird/QwenRuntime/0.1.0/.scribird-ready").path))
        let calls = LockedBox(0)
        _ = try await QwenRuntime.prepare(runtime: root, supportDirectory: root, variables: [:], uvCandidates: ["/usr/bin/true"]) { _, _, environment in
            calls.mutate { $0 += 1 }
            try QwenRuntimeTests.writePython(environment)
        }
        XCTAssertEqual(calls.value, 1)
    }

    /// Concurrent setup requests must not corrupt the shared environment or finalize installation twice.
    func test_concurrentInitialSetup_usesOnePreparedEnvironment() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = LockedBox(0)
        let setup: QwenRuntime.Setup = { _, _, environment in
            calls.mutate { $0 += 1 }
            await Task.yield()
            try QwenRuntimeTests.writePython(environment)
        }
        async let first = QwenRuntime.prepare(runtime: root, supportDirectory: root, variables: [:], uvCandidates: ["/usr/bin/true"], setup: setup)
        async let second = QwenRuntime.prepare(runtime: root, supportDirectory: root, variables: [:], uvCandidates: ["/usr/bin/true"], setup: setup)
        let values = try await (first, second)
        XCTAssertEqual(values.0, values.1)
        XCTAssertEqual(calls.value, 1)
    }

    /// Missing system prerequisites produce an actionable error
    /// without downloading or running another engine.
    func test_missingUv_doesNotInvokeSetup() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await QwenRuntime.prepare(runtime: root, supportDirectory: root, variables: [:], uvCandidates: []) { _, _, _ in
                XCTFail("Missing uv must stop before setup")
            }
            XCTFail("Missing uv must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("uv")) }
    }

    /// Creates an isolated root so tests cannot create or modify the user's environment.
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "scribird-runtime-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    /// An offline installer stub creates only an executable Python stand-in at the actual setup path.
    private static func writePython(_ environment: [String: String]) throws {
        let root = URL(fileURLWithPath: try XCTUnwrap(environment["UV_PROJECT_ENVIRONMENT"]))
        let bin = root.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let python = bin.appending(path: "python")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: python, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: python.path)
    }
}
