import AVFoundation
import Speech

struct SpeechFileTranscriber: FileTranscribing {
    private let locale: Locale
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer

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
        // 실시간 세션의 모델 예약은 바꾸지 않는다.
        analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: .utility, modelRetention: .whileInUse)
        )
    }

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
                        // 마지막 결과까지 받은 뒤 반환해야 공통 저장기가 안전하게 닫힌다.
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
