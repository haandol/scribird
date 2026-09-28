import Foundation

/// 자식 출력이 읽히는 동안 취소할 수 있어야 큰 파일의 전사를 UI에서 멈출 수 있다.
enum LocalTranscriptionProcess {
    static func run(
        executable: URL, arguments: [String], environment: [String: String]? = nil,
        onLine: @escaping @Sendable (String) async throws -> Void
    ) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
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
            do {
                for try await line in stdout.fileHandleForReading.bytes.lines {
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
                // 취소된 태스크의 AsyncStream은 즉시 끝나므로 프로세스 종료는 별도로 기다린다.
                await Task.detached { process.waitUntilExit() }.value
                throw error
            }
        } onCancel: { managed.cancel() }
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

    init(_ process: Process) { self.process = process }

    func start() throws {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            try process.run()
        }
    }

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
