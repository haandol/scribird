import Foundation

protocol QwenChunkRecognizing: Sendable {
    func recognize(_ samples: [Float], language: TranscriptionLanguage) async throws -> String
    func cancel() async
}

/// One owned process per audio source keeps model state isolated and loads weights once.
actor QwenLiveWorker: QwenChunkRecognizing {
    private let input: Pipe
    private let writer: LocalProcessInput
    private var task: Task<Void, Never>?
    private var response: CheckedContinuation<String, any Error>?
    private var failure: (any Error)?
    private var expectedEvent = "ready"

    init() {
        let input = Pipe()
        self.input = input
        writer = LocalProcessInput(handle: input.fileHandleForWriting)
    }

    /// Waits for model readiness before capture can start; setup failure never selects another engine.
    func start(python: URL, runtime: URL) async throws {
        try await withTaskCancellationHandler {
            _ = try await withCheckedThrowingContinuation { (ready: CheckedContinuation<String, any Error>) in
                response = ready
                task = Task { [weak self, input] in
                    do {
                        try await LocalTranscriptionProcess.run(
                            executable: python, arguments: [runtime.appending(path: "transcribe.py").path, "--live"],
                            standardInput: input
                        ) { [weak self] line in
                            try await self?.receive(line)
                        }
                        await self?.fail(QwenFileTranscriber.RuntimeError.invalidOutput)
                    } catch { await self?.fail(error) }
                }
            }
        } onCancel: { Task { await self.cancel() } }
    }

    /// Sends one bounded mono Float32 chunk over the local pipe and awaits its matching result.
    func recognize(_ samples: [Float], language: TranscriptionLanguage) async throws -> String {
        try Task.checkCancellation()
        if let failure { throw failure }
        guard response == nil else { throw QwenFileTranscriber.RuntimeError.invalidOutput }
        expectedEvent = "result"
        let bytes = samples.withUnsafeBytes { Data($0) }
        var data = try JSONEncoder().encode(Request(audio: bytes.base64EncodedString(), language: language.rawValue))
        data.append(0x0A)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                response = continuation
                Task {
                    do { try await writer.write(data) }
                    catch { fail(error) }
                }
            }
        } onCancel: { Task { await self.cancel() } }
    }

    /// Validates every response before resuming the sole outstanding request.
    private func receive(_ line: String) throws {
        let event = try JSONDecoder().decode(Event.self, from: Data(line.utf8))
        guard event.event == expectedEvent,
              event.event == "ready" || event.text != nil,
              let response else { throw QwenFileTranscriber.RuntimeError.invalidOutput }
        self.response = nil
        response.resume(returning: event.text ?? "")
    }

    /// Resumes pending setup or inference when the process exits so neither can hang.
    private func fail(_ error: any Error) {
        failure = error
        let pending = response
        response = nil
        pending?.resume(throwing: error)
    }

    /// Stops only this source's process and releases pending calls before waiting for cleanup.
    func cancel() async {
        fail(CancellationError())
        writer.cancel()
        task?.cancel()
        await writer.close()
        await task?.value
        task = nil
    }

    private struct Request: Encodable { let audio: String; let language: String }
    private struct Event: Decodable { let event: String; let text: String? }
}
