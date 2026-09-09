import AVFoundation
import Speech

@MainActor
protocol SpeechSessionProviding {
    func prepare(language: TranscriptionLanguage) async throws -> PreparedSpeechSessions
    func installedLocales(for language: TranscriptionLanguage) async throws -> [Locale]
}

struct PreparedSpeechSessions {
    let sessions: [Speaker: any Transcribing]
    let audioFormat: AVAudioFormat
    let retentionWarning: String?
}

@MainActor
struct SystemSpeechSessionProvider: SpeechSessionProviding {
    func installedLocales(for language: TranscriptionLanguage) async throws -> [Locale] {
        let locales = try await SpeechModelInstaller.resolveLocales(language.locales)
        guard await SpeechModelInstaller.areInstalled(locales: locales) else {
            throw MeetingRecorder.RecorderError.languageModelNotInstalled(language)
        }
        return locales
    }

    func prepare(language: TranscriptionLanguage) async throws -> PreparedSpeechSessions {
        let locales = try await installedLocales(for: language)
        var sessions: [Speaker: TranscriptionSession] = [:]
        for speaker in Speaker.allCases {
            sessions[speaker] = TranscriptionSession(speaker: speaker, locales: locales)
        }

        do {
            let modules = await sessions[.me]!.modules
            let warning = try await reserveModels(locales: locales, modules: modules)
            guard let format = await TranscriptionSession.bestAudioFormat(for: modules) else {
                throw MeetingRecorder.RecorderError.noCompatibleAudioFormat
            }
            for session in sessions.values { try await session.prepare(format: format) }
            return PreparedSpeechSessions(
                sessions: sessions, audioFormat: format, retentionWarning: warning
            )
        } catch {
            // 준비 도중 실패한 세션도 생성한 쪽에서 정리한다.
            for session in sessions.values { Task { await session.cancel() } }
            throw error
        }
    }

    private func reserveModels(locales: [Locale], modules: [any SpeechModule]) async throws -> String? {
        let reservation = await SpeechModelInstaller.reserve(locales: locales)
        guard !reservation.isComplete else { return nil }

        // 예약이 0개여도 설치된 모델의 포맷 질의·분석기 준비는 성공했다. 설치된 경우는
        // 경고만 남긴다.
        guard await SpeechModelInstaller.isInstalled(modules: modules) else {
            let failed = reservation.unreserved[0]
            throw SpeechModelInstaller.InstallError.reservationFailed(
                locale: failed.locale,
                reason: failed.reason,
                requested: locales,
                reserved: await SpeechModelInstaller.reservedLocales()
            )
        }
        return MeetingRecorder.retentionWarning(for: reservation.unreserved)
    }
}
