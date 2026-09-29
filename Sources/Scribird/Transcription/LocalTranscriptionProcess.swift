import Foundation
import Darwin

/// Allows cancellation while reading child output so the UI can stop transcription of large files.
enum LocalTranscriptionProcess {
    /// Delivers results line by line, surfaces runner errors and cancellation, and cleans up the owned process.
    static func run(
        executable: URL, arguments: [String], environment: [String: String]? = nil,
        standardInput: Pipe? = nil,
        onLine: @escaping @Sendable (String) async throws -> Void
    ) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let standardInput { process.standardInput = standardInput }
        let stdout = Pipe()
        process.standardOutput = stdout
        let errorURL = FileManager.default.temporaryDirectory.appending(path: "scribird-worker-\(UUID()).log")
        try Data().write(to: errorURL)
        let stderr = try FileHandle(forWritingTo: errorURL)
        process.standardError = stderr
        let managed = CancellableTranscriptionProcess(process)
        let (exits, exitContinuation) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { process in
            exitContinuation.yield(process.terminationStatus)
            exitContinuation.finish()
        }
        defer {
            try? stderr.close()
            try? FileManager.default.removeItem(at: errorURL)
            try? stdout.fileHandleForReading.close()
        }
        try await withTaskCancellationHandler {
            try managed.start()
            // The parent must not keep a read end that conceals the child's exit from its writer.
            try? standardInput?.fileHandleForReading.close()
            do {
                for try await line in readLines(from: stdout.fileHandleForReading) {
                    try Task.checkCancellation()
                    try await onLine(line)
                }
                for await status in exits {
                    try Task.checkCancellation()
                    guard status == 0 else {
                        let diagnostic = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
                        throw Failure(status: status, diagnostic: String(diagnostic.suffix(4000)))
                    }
                }
                try Task.checkCancellation()
            } catch {
                managed.cancel()
                // A cancelled task's AsyncStream ends immediately.
                // Wait separately for the process to terminate.
                await Task.detached { process.waitUntilExit() }.value
                throw error
            }
        } onCancel: { managed.cancel() }
    }

    /// A dedicated reader prevents one idle persistent worker from blocking another pipe.
    /// Two Qwen workers stalled during readiness with FileHandle.bytes.lines on this macOS.
    private static func readLines(from handle: FileHandle) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            DispatchQueue(label: "com.scribird.asr-output.\(UUID())").async {
                do {
                    var pending = Data()
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while true {
                        // FileHandle.read(upToCount:) can wait to fill the requested count
                        // on a pipe. POSIX read returns the available readiness line immediately.
                        let count = buffer.withUnsafeMutableBytes {
                            Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count)
                        }
                        if count == 0 { break }
                        if count < 0 {
                            if errno == EINTR { continue }
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                        pending.append(contentsOf: buffer.prefix(count))
                        while let newline = pending.firstIndex(of: 0x0A) {
                            var line = pending[..<newline]
                            if line.last == 0x0D { line = line.dropLast() }
                            continuation.yield(String(decoding: line, as: UTF8.self))
                            pending.removeSubrange(...newline)
                        }
                    }
                    if !pending.isEmpty { continuation.yield(String(decoding: pending, as: UTF8.self)) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
    }

    struct Failure: LocalizedError {
        let status: Int32
        let diagnostic: String

        var errorDescription: String? {
            tr("로컬 ASR 실행 실패 (\(status)): ", "Local ASR process failed (\(status)): ") + diagnostic
        }
    }
}

private final class CancellableTranscriptionProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var cancelled = false

    /// Retains ownership so cancellation targets only the process created by this task.
    init(_ process: Process) { self.process = process }

    /// Serializes launch and cancellation so a request cancelled just before launch
    /// cannot leave a new process running.
    func start() throws {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            try process.run()
        }
    }

    /// Force-kills a runner that survives the termination signal so cleanup cannot wait indefinitely.
    func cancel() {
        lock.withLock {
            cancelled = true
            guard process.isRunning else { return }
            process.terminate()
            let process = process
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}
