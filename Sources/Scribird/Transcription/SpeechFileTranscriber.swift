import AVFoundation
import Speech

struct SpeechFileTranscriber: FileTranscribing {
    private let locale: Locale
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    var modelDescription: String { "Apple SpeechTranscriber (\(locale.identifier))" }

    /// Checks readiness for the selected language first because file jobs
    /// do not automatically install Speech models.
    init(language: TranscriptionLanguage) async throws {
        let locales = try await SpeechModelInstaller.resolveLocales(language.locales)
        guard await SpeechModelInstaller.areInstalled(locales: locales) else {
            throw FileTranscriptionError.modelMissing
        }
        locale = locales[0]
        transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
        // Leave the live session's model reservations unchanged.
        analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: .utility, modelRetention: .whileInUse)
        )
    }

    /// Returns after delivering the file's final results; cancellation or failure closes both the analyzer
    /// and result receiver.
    func transcribe(
        audio: URL,
        onSegment: @escaping @Sendable (FileTranscriptRecord) async throws -> Void
    ) async throws {
        let file = try AVAudioFile(forReading: audio)
        do {
            try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        do {
                            for try await result in transcriber.results {
                                try Task.checkCancellation()
                                guard result.isFinal else { continue }
                                let record = Self.record(result, locale: locale)
                                guard !record.text.isEmpty else { continue }
                                try await onSegment(record)
                            }
                        } catch {
                            await analyzer.cancelAndFinishNow()
                            throw error
                        }
                    }
                    do {
                        // Receive every final result before returning so the shared archive can close safely.
                        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
                        try await group.waitForAll()
                    } catch {
                        group.cancelAll()
                        await analyzer.cancelAndFinishNow()
                        throw error
                    }
                }
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    /// Copies only model-provided timing and confidence, leaving imported-file speakers unassigned.
    private static func record(_ result: SpeechTranscriber.Result, locale: Locale) -> FileTranscriptRecord {
        let confidences = result.text.runs.compactMap(\.transcriptionConfidence)
        return FileTranscriptRecord(
            start: result.range.start.seconds,
            end: result.range.end.seconds,
            text: String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines),
            locale: locale.identifier,
            confidence: confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
        )
    }
}
