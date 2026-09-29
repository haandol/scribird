import AppKit
import Observation

/// 전역 단축키 설정과 등록 상태.
///
/// 등록 실패를 상태로 들고 있는 이유: 다른 앱이 같은 조합을 이미 점유하면 등록이
/// 실패하는데, 이를 알리지 않으면 사용자는 단축키를 눌러 보고 앱이 고장 났다고
/// 판단한다. 단축키를 못 써도 메뉴바 경로가 남아 있으므로 녹취는 막지 않는다.
@MainActor
@Observable
final class HotKeySettings: ShortcutEditing {
    /// 사용자가 아무것도 정하지 않았을 때의 조합.
    var defaultShortcut: HotKeyShortcut { .default }

    private(set) var shortcut: HotKeyShortcut
    /// 등록에 실패한 사유. 성공하면 nil이다.
    private(set) var registrationError: String?
    /// 사용자가 새 조합을 누르기를 기다리는 중인지.
    var isRecording = false

    private var hotKey: GlobalHotKey?
    private let defaults: UserDefaults
    private let registerShortcut: ((HotKeyShortcut) throws -> Void)?

    /// Loads the stored choice; an injectable registration boundary exercises failures without taking system hotkeys.
    init(shortcut: HotKeyShortcut? = nil, defaults: UserDefaults = .standard,
         registerShortcut: ((HotKeyShortcut) throws -> Void)? = nil) {
        self.defaults = defaults
        self.shortcut = shortcut ?? .load(from: defaults)
        self.registerShortcut = registerShortcut
    }

    /// 단축키가 눌렸을 때 실행할 동작을 붙이고 등록한다.
    func activate(handler: @MainActor @Sendable @escaping () -> Void) {
        hotKey = GlobalHotKey(handler: handler)
        apply(shortcut)
    }

    /// Restores the previous choice on registration failure without hiding why the requested change failed.
    func update(to newShortcut: HotKeyShortcut) {
        if let error = newShortcut.validationError {
            registrationError = error
            return
        }
        let previous = shortcut
        apply(newShortcut)
        if let changeError = registrationError, newShortcut != previous {
            apply(previous)
            registrationError = [changeError, registrationError].compactMap { $0 }.joined(separator: "\n")
        }
    }

    func resetToDefault() {
        update(to: .default)
    }

    /// Persists only a successfully registered choice and exposes registration errors to the settings UI.
    private func apply(_ candidate: HotKeyShortcut) {
        do {
            if let registerShortcut { try registerShortcut(candidate) }
            else { try hotKey?.register(candidate) }
            shortcut = candidate
            candidate.save(to: defaults)
            registrationError = nil
        } catch {
            registrationError = error.localizedDescription
        }
    }
}
