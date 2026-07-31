import AppKit
import Observation

/// 설정 창을 여는 단축키.
///
/// **전역으로 등록하지 않는다.** 전사 창이 앞에 있을 때만 듣는다 — 전역으로 잡으면 다른 앱을
/// 쓰는 중에도 그 조합을 가로채 그 앱의 설정이 열리지 않는다. 남의 앱 단축키를 빼앗는 것은 이
/// 기능의 목적을 넘어선다. 그래서 등록 실패라는 상태가 없고, 전역 단축키와 달리 충돌을 알릴
/// 필요도 없다.
///
/// 대신 다른 앱이 같은 조합을 전역으로 점유하면 이 앱에는 키가 오지 않는다. 실측 — 메뉴바
/// 유틸리티가 `⌘,`를 전역 등록한 환경에서 이 앱이 반응하지 않았고, 그 유틸리티를 종료하자 즉시
/// 동작했다. 그 상황에서 사용자가 조합을 바꿔 쓸 수 있어야 하므로 이 설정이 존재한다.
@MainActor
@Observable
final class SettingsHotKeySettings: ShortcutEditing {
    /// 사용자가 아무것도 정하지 않았을 때의 조합. macOS 관례인 `⌘,`다.
    var defaultShortcut: HotKeyShortcut { HotKeyShortcut.Slot.settingsWindow.defaultShortcut }

    private(set) var shortcut: HotKeyShortcut
    /// 사용자가 새 조합을 누르기를 기다리는 중인지.
    var isRecording = false
    /// 조합을 거부한 사유. 받아들이면 nil이다.
    private(set) var validationError: String?

    init(shortcut: HotKeyShortcut = .load(.settingsWindow)) {
        self.shortcut = shortcut
    }

    /// 이 조합이 설정 열기에 해당하는지. 창이 키 이벤트를 판정할 때 쓴다.
    ///
    /// 키 코드로 비교한다 — 문자로 비교하면 입력기가 조합 중일 때 `charactersIgnoringModifiers`가
    /// 빈 문자열로 와서 놓친다.
    func matches(_ event: NSEvent) -> Bool {
        event.keyCode == UInt16(shortcut.keyCode)
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                == shortcut.modifiers
    }

    /// 사용자가 고른 조합으로 바꾼다.
    ///
    /// 전역 등록이 없으므로 실패할 여지는 유효성뿐이다.
    func update(to newShortcut: HotKeyShortcut) {
        guard newShortcut.isValid else {
            validationError = "Command·Option·Control 중 하나 이상을 포함해야 합니다."
            return
        }
        shortcut = newShortcut
        newShortcut.save(.settingsWindow)
        validationError = nil
    }

    func resetToDefault() {
        update(to: defaultShortcut)
    }
}
