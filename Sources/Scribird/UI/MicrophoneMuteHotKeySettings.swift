import AppKit
import Foundation
import Observation

/// 마이크 음소거를 토글하는 로컬 단축키.
///
/// 전역 등록하지 않고 Scribird가 받는 키 이벤트만 판정한다. 다른 앱을 쓰는 동안 같은
/// 조합을 가로채지 않으면서, 사용자 환경의 충돌은 설정에서 조합을 바꿔 피할 수 있다.
@MainActor
@Observable
final class MicrophoneMuteHotKeySettings: ShortcutEditing {
    var defaultShortcut: HotKeyShortcut { HotKeyShortcut.Slot.microphoneMute.defaultShortcut }

    private(set) var shortcut: HotKeyShortcut
    var isRecording = false
    private(set) var inputError: String?

    private let defaults: UserDefaults
    private var conflictingShortcuts: @MainActor () -> [HotKeyShortcut] = { [] }

    init(
        shortcut: HotKeyShortcut? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        self.shortcut = shortcut ?? .load(.microphoneMute, from: defaults)
    }

    var validationError: String? {
        inputError ?? conflictMessage(for: shortcut)
    }

    func setConflictProvider(
        _ provider: @escaping @MainActor () -> [HotKeyShortcut]
    ) {
        conflictingShortcuts = provider
    }

    func matches(_ event: NSEvent) -> Bool {
        event.type == .keyDown
            && !event.isARepeat
            && conflictMessage(for: shortcut) == nil
            && event.keyCode == UInt16(shortcut.keyCode)
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                == shortcut.modifiers
    }

    func update(to newShortcut: HotKeyShortcut) {
        guard newShortcut.isValid else {
            inputError = tr("Command·Option·Control 중 하나 이상을 포함해야 합니다.",
                            "Must include at least one of Command, Option, or Control.")
            return
        }
        if let conflict = conflictMessage(for: newShortcut) {
            inputError = conflict
            return
        }

        shortcut = newShortcut
        newShortcut.save(.microphoneMute, to: defaults)
        inputError = nil
    }

    func resetToDefault() {
        update(to: defaultShortcut)
    }

    private func conflictMessage(for candidate: HotKeyShortcut) -> String? {
        guard conflictingShortcuts().contains(candidate) else { return nil }
        return tr(
            "다른 Scribird 단축키에서 이미 사용하는 조합입니다.",
            "This combination is already used by another Scribird shortcut."
        )
    }
}
