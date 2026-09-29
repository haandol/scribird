import AppKit
import Observation

/// Keeps the user's pinning choice separate from temporarily yielding to another window.
@MainActor
@Observable
final class TranscriptWindowSettings {
    static let shared = TranscriptWindowSettings()
    static let preferenceKey = "transcriptWindowAlwaysOnTop"

    private(set) var keepsOnTop: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var isYielding = false

    /// Restores the choice at launch; absent or unreadable preferences keep the default-on behavior.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keepsOnTop = RecordingPreferences.boolean(forKey: Self.preferenceKey, from: defaults, fallback: true)
    }

    /// Attaches only the live transcript; utility windows never inherit its floating level.
    func attach(_ window: NSWindow) {
        self.window = window
        applyLevel()
    }

    /// Persists changes immediately without lifting the transcript over an active utility window.
    func update(keepsOnTop: Bool) {
        self.keepsOnTop = keepsOnTop
        defaults.set(keepsOnTop, forKey: Self.preferenceKey)
        applyLevel()
    }

    /// Lowers the transcript before opening a utility or folder, without altering the saved choice.
    func yieldFront() {
        isYielding = true
        applyLevel()
    }

    /// An explicit recall or activation restores the configured level, never a timer-driven pin.
    func restoreFront() {
        isYielding = false
        applyLevel()
    }

    /// Changes only window order; recording and file jobs have no dependency on this state.
    private func applyLevel() {
        window?.level = keepsOnTop && !isYielding ? .floating : .normal
    }
}
