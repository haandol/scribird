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
    func install(
        _ language: SpeechModelLanguage,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws
}

struct SystemSpeechModelInstaller: SpeechModelInstalling {
    func installedLocaleIdentifiers() async -> [String] {
        await SpeechModelInstaller.installedLocaleIdentifiers()
    }

    func install(
        _ language: SpeechModelLanguage,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await SpeechModelInstaller.install(
            locale: language.locale,
            onProgress: onProgress
        )
    }
}

@MainActor
@Observable
final class SpeechModelManager {
    enum State: Equatable {
        case notInstalled
        case installing(Double)
        case installed
        case failed(String)

        var isInstalling: Bool {
            if case .installing = self { return true }
            return false
        }
    }

    private let installer: any SpeechModelInstalling
    private(set) var states: [SpeechModelLanguage: State]

    init(installer: any SpeechModelInstalling = SystemSpeechModelInstaller()) {
        self.installer = installer
        self.states = Dictionary(
            uniqueKeysWithValues: SpeechModelLanguage.allCases.map { ($0, .notInstalled) }
        )
    }

    func state(for language: SpeechModelLanguage) -> State {
        states[language] ?? .notInstalled
    }

    var availableLanguages: [TranscriptionLanguage] {
        guard case .installed = state(for: .english) else { return [] }
        return TranscriptionLanguage.available(
            installedIdentifiers: installedModels.map(\.locale.identifier)
        )
    }

    var hasInstalledLanguage: Bool {
        !availableLanguages.isEmpty
    }

    func refresh() async {
        let installed = normalizedSet(await installer.installedLocaleIdentifiers())
        for language in SpeechModelLanguage.allCases {
            guard !state(for: language).isInstalling else { continue }
            if installed.contains(normalized(language.locale.identifier)) {
                states[language] = .installed
            } else if case .installed = state(for: language) {
                states[language] = .notInstalled
            }
        }
    }

    func install(_ language: SpeechModelLanguage) async {
        guard !state(for: language).isInstalling else { return }
        states[language] = .installing(0)

        do {
            try await installer.install(language) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self, self.state(for: language).isInstalling else { return }
                    self.states[language] = .installing(min(max(fraction, 0), 1))
                }
            }

            let installed = normalizedSet(await installer.installedLocaleIdentifiers())
            guard installed.contains(normalized(language.locale.identifier)) else {
                let progress = currentProgress(for: language)
                throw SpeechModelInstaller.InstallError.incompleteInstallation(
                    language.locale,
                    progress: progress
                )
            }
            states[language] = .installed
        } catch {
            states[language] = .failed(error.localizedDescription)
        }
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
        SpeechModelLanguage.allCases.filter {
            if case .installed = state(for: $0) { return true }
            return false
        }
    }

    private func currentProgress(for language: SpeechModelLanguage) -> Double {
        if case .installing(let fraction) = state(for: language) {
            return fraction
        }
        return 0
    }

    private func normalizedSet(_ identifiers: [String]) -> Set<String> {
        Set(identifiers.map(normalized))
    }

    private func normalized(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}
