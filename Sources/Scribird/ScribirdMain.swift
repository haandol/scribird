import Foundation

@main
enum ScribirdMain {
    @MainActor
    /// Routes CLI input to work without capture and handles termination signals as cancellation
    /// so cancellation preserves partial results and removes temporary files.
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") {
            print(FileTranscriptionCommand.usage)
            return
        }
        if arguments.contains("--transcribe") {
            // The MCP coordinator writes the completion marker after receiving the result,
            // preventing a timed-out response from leaving a completed archive.
            // The CLI and app write the marker directly.
            let commitCompletion = ProcessInfo.processInfo.environment["_SCRIBIRD_MCP_DEFER_COMPLETION"] != "1"
            let commandTask = Task { try await FileTranscriptionCommand(arguments: arguments).run(commitCompletion: commitCompletion) }
            let signals = [SIGINT, SIGTERM].map { value in
                signal(value, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: value, queue: .global())
                // If this global-queue callback inherits main()'s MainActor isolation, a signal
                // triggers dispatch_assert_queue_fail and prevents temporary-file cleanup.
                source.setEventHandler { @Sendable in commandTask.cancel() }
                source.resume()
                return source
            }
            defer { for source in signals { source.cancel() } }
            do {
                let result = try await commandTask.value
                var data = try JSONEncoder().encode(result)
                data.append(0x0A)
                try FileHandle.standardOutput.write(contentsOf: data)
            } catch {
                try? FileHandle.standardError.write(contentsOf: Data((error.localizedDescription + "\n").utf8))
                exit(1)
            }
            return
        }
        if arguments.contains(where: { $0.hasPrefix("--") }) {
            try? FileHandle.standardError.write(contentsOf: Data((FileTranscriptionCommand.usage + "\n").utf8))
            exit(1)
        }
        ScribirdApp.main()
    }
}
