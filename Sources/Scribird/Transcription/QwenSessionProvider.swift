import AVFoundation
import Foundation

@MainActor
struct QwenSessionProvider: SpeechSessionProviding {
    /// Qwen uses its own multilingual model and must not depend on Apple locale assets.
    func installedLocales(for language: TranscriptionLanguage) async throws -> [Locale] { language.locales }

    /// Prepares both independent workers before opening capture; any failed setup cleans up both.
    func prepare(language: TranscriptionLanguage) async throws -> PreparedSpeechSessions {
        #if !arch(arm64)
        throw QwenFileTranscriber.RuntimeError.message(tr("Qwen3는 Apple Silicon Mac이 필요합니다.",
                                                         "Qwen3 requires an Apple Silicon Mac."))
        #else
        let runtime = QwenFileTranscriber.runtimeDirectory()
        let python = try await QwenFileTranscriber.preparePython(runtime: runtime)
        var workers: [QwenLiveWorker] = []
        var sessions: [Speaker: any Transcribing] = [:]
        do {
            for speaker in Speaker.allCases {
                let worker = QwenLiveWorker()
                workers.append(worker)
                try await worker.start(python: python, runtime: runtime)
                sessions[speaker] = QwenTranscriptionSession(speaker: speaker, language: language, worker: worker)
            }
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                            channels: 1, interleaved: false) else {
                throw MeetingRecorder.RecorderError.noCompatibleAudioFormat
            }
            return PreparedSpeechSessions(sessions: sessions, audioFormat: format, retentionWarning: nil)
        } catch {
            for worker in workers { await worker.cancel() }
            throw error
        }
        #endif
    }
}
