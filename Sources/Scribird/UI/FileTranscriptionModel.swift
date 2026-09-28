import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class FileTranscriptionModel {
    var source: URL?
    var language: TranscriptionLanguage = .english
    var engine: FileTranscriptionEngine = .speechAnalyzer
    private(set) var isRunning = false
    private(set) var isCancelling = false
    private(set) var text = ""
    private(set) var error: String?
    private(set) var result: FileTranscriptionResult?
    private(set) var outputDirectory: URL?
    private var task: Task<Void, Never>?

    func chooseFile() {
        guard !isRunning else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = tr("선택", "Choose")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.source = url
        }
    }

    func start() {
        guard !isRunning, let source else { return }
        isRunning = true
        isCancelling = false
        text = ""
        error = nil
        result = nil
        outputDirectory = nil
        let language = language
        let engine = engine
        task = Task {
            defer { isRunning = false; isCancelling = false; task = nil }
            let accessed = source.startAccessingSecurityScopedResource()
            defer { if accessed { source.stopAccessingSecurityScopedResource() } }
            do {
                let root = try RecordingPreferences.transcriptRoot() ?? TranscriptRootLocation.standardDirectory()
                result = try await FileTranscription.transcribe(
                    source: source, language: language, outputRoot: root, engine: engine,
                    onOutputDirectory: { [weak self] directory in
                        await self?.setOutputDirectory(directory)
                    }
                ) { [weak self] record in
                    await self?.append(record)
                }
                if result?.segments.isEmpty == true {
                    text = tr("인식된 음성이 없습니다.", "No speech recognized.")
                }
            } catch {
                self.error = Task.isCancelled
                    ? tr("파일 전사를 취소했습니다. 이미 저장된 부분 결과는 남아 있습니다.",
                         "File transcription cancelled. Any saved partial results are retained.")
                    : error.localizedDescription
            }
        }
    }

    private func append(_ record: FileTranscriptRecord) {
        if !text.isEmpty { text += "\n\n" }
        text += "[\(formatTimecode(record.start))] \(record.text)"
    }

    private func setOutputDirectory(_ directory: URL) {
        outputDirectory = directory
    }

    func cancel() {
        guard isRunning else { return }
        isCancelling = true
        task?.cancel()
    }
}
