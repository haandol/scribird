import Foundation
import Observation

enum SpeechModelLanguage: String, CaseIterable, Identifiable, Sendable {
    case english
    case korean

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .korean: "한국어"
        case .english: "English"
        }
    }

    var locale: Locale {
        switch self {
        case .korean: Locale(identifier: "ko-KR")
        case .english: Locale(identifier: "en-US")
        }
    }
}

protocol SpeechModelInstalling: Sendable {
    func installedLocaleIdentifiers() async -> [String]
    func install(_ language: SpeechModelLanguage) async throws
}

struct SystemSpeechModelInstaller: SpeechModelInstalling {
    func installedLocaleIdentifiers() async -> [String] {
        await SpeechModelInstaller.installedLocaleIdentifiers()
    }

    func install(_ language: SpeechModelLanguage) async throws {
        try await SpeechModelInstaller.install(locale: language.locale)
    }
}

@MainActor
@Observable
final class SpeechModelManager {
    enum State: Equatable {
        case notInstalled
        case installing
        case installed
        case failed(String)

        var isInstalling: Bool {
            if case .installing = self { return true }
            return false
        }
    }

    private let installer: any SpeechModelInstalling
    private var states: [SpeechModelLanguage: State] = [:]
    private(set) var hasCheckedInventory = false
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var appliedRevision: [SpeechModelLanguage: Int] = [:]

    init(installer: any SpeechModelInstalling = SystemSpeechModelInstaller()) {
        self.installer = installer
    }

    func state(for language: SpeechModelLanguage) -> State {
        states[language] ?? .notInstalled
    }

    var availableLanguages: [TranscriptionLanguage] {
        guard hasRequiredEnglish else { return [] }
        return TranscriptionLanguage.available(
            installedIdentifiers: installedModels.map(\.locale.identifier)
        )
    }

    var hasRequiredEnglish: Bool {
        state(for: .english) == .installed
    }

    func refresh() async {
        let readRevision = nextRevision()
        let expected = SpeechModelLanguage.allCases.filter { $0 == .english || state(for: $0) == .installed }
        let identifiers = await SpeechModelInstaller.confirmedInstalledIdentifiers(
            for: expected.map(\.locale), read: installer.installedLocaleIdentifiers
        )
        for language in SpeechModelLanguage.allCases {
            // A read started before another refresh or a completed installation can return last.
            guard readRevision > appliedRevision[language, default: 0],
                  !state(for: language).isInstalling else { continue }
            appliedRevision[language] = readRevision
            if SpeechModelInstaller.allInstalled(requested: [language.locale], installedIdentifiers: identifiers) {
                states[language] = .installed
            } else if case .installed = state(for: language) {
                states[language] = .notInstalled
            }
        }
        hasCheckedInventory = true
    }

    func install(_ language: SpeechModelLanguage) async {
        guard !state(for: language).isInstalling else { return }
        states[language] = .installing

        do {
            try await installer.install(language)

            guard await SpeechModelInstaller.areInstalled(
                locales: [language.locale], read: installer.installedLocaleIdentifiers
            ) else {
                throw SpeechModelInstaller.InstallError.incompleteInstallation(language.locale)
            }
            states[language] = .installed
        } catch {
            states[language] = .failed(error.localizedDescription)
        }
        appliedRevision[language] = nextRevision()
    }

    func installRequiredEnglishIfNeeded() async {
        await refresh()
        switch state(for: .english) {
        case .installed, .installing:
            return
        case .notInstalled, .failed:
            await install(.english)
        }
    }

    private var installedModels: [SpeechModelLanguage] {
        SpeechModelLanguage.allCases.filter { state(for: $0) == .installed }
    }

    private func nextRevision() -> Int {
        revision += 1
        return revision
    }
}
