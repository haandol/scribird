import Foundation

@main
enum ScribirdMain {
    @MainActor
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") {
            print(FileTranscriptionCommand.usage)
            return
        }
        if arguments.contains("--transcribe") {
            let commandTask = Task { try await FileTranscriptionCommand(arguments: arguments).run() }
            let signals = [SIGINT, SIGTERM].map { value in
                signal(value, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: value, queue: .global())
                // 전역 큐의 콜백이 main()의 MainActor 격리를 상속하면 신호 수신 시
                // dispatch_assert_queue_fail로 종료되어 임시 파일 정리도 실행되지 않는다.
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
