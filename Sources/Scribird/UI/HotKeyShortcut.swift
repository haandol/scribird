import AppKit
import Carbon.HIToolbox
import Foundation

/// 전역 단축키 한 조합.
///
/// 사용자가 바꿀 수 있어야 하고 앱을 다시 켜도 유지되어야 한다 — 전역 단축키는
/// 사용자가 이미 쓰는 다른 앱과 충돌할 수 있고, 어떤 조합이 비어 있는지는 환경마다
/// 다르므로 고정값으로 두면 일부 사용자에게는 동작하지 않는 기능이 된다.
struct HotKeyShortcut: Equatable, Sendable {
    /// 물리 키 코드. 키보드 레이아웃이 바뀌어도 같은 자리를 가리킨다.
    let keyCode: UInt32
    /// Command·Option·Shift·Control 조합.
    let modifiers: NSEvent.ModifierFlags

    /// 기본값 ⌥⌘S. macOS 기본 단축키와 충돌하지 않는다.
    static let `default` = HotKeyShortcut(
        keyCode: UInt32(kVK_ANSI_S),
        modifiers: [.option, .command]
    )

    /// 단축키로 쓸 수 있는 조합인지.
    ///
    /// 수정자가 없거나 Shift만 있는 조합은 일반 타이핑을 가로채므로 거부한다.
    var isValid: Bool {
        let required: NSEvent.ModifierFlags = [.command, .control, .option]
        return !modifiers.intersection(required).isEmpty
    }

    /// `⌥⌘S` 형태의 표시 문자열.
    var displayName: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + Self.keyName(for: keyCode)
    }

    /// Carbon이 요구하는 수정자 비트.
    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        return result
    }

    /// 키 코드에 대응하는 표시 이름.
    ///
    /// 레이아웃에서 문자를 얻어 온다 — 같은 키 코드가 레이아웃에 따라 다른 문자를
    /// 내므로, 고정 표에서 찾으면 사용자가 실제로 누르는 키와 어긋난다.
    private static func keyName(for keyCode: UInt32) -> String {
        if let special = specialKeyNames[keyCode] { return special }
        if let character = layoutCharacter(for: keyCode) { return character.uppercased() }
        return "Key \(keyCode)"
    }

    /// 문자를 내지 않는 키들. 레이아웃으로는 이름을 얻을 수 없다.
    private static let specialKeyNames: [UInt32: String] = [
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Return): "↩",
        UInt32(kVK_Tab): "⇥",
        UInt32(kVK_Escape): "⎋",
        UInt32(kVK_Delete): "⌫",
        UInt32(kVK_ForwardDelete): "⌦",
        UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑",
        UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_Home): "↖",
        UInt32(kVK_End): "↘",
        UInt32(kVK_PageUp): "⇞",
        UInt32(kVK_PageDown): "⇟",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
    ]

    /// 키 코드를 문자로 옮긴다.
    ///
    /// **ASCII 레이아웃으로 읽는다. 현재 입력 소스가 아니다.** 등록되는 것은 물리 키
    /// 자리이므로 표시도 그 자리의 이름이어야 한다. 현재 입력 소스로 읽으면 한글
    /// 입력 중에 `⌥⌘S`가 `⌥⌘ㄴ`으로 보여, 사용자가 실제로 눌러야 하는 키와 어긋난다.
    private static func layoutCharacter(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?
                .takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)

        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
            else { return -1 }
            return UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,  // 수정자를 빼고 눌러야 키의 기본 문자가 나온다.
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}

extension HotKeyShortcut {
    /// 저장되는 단축키의 종류.
    ///
    /// 두 단축키는 동작 범위가 다르다 — 전사 창 띄우기는 전역이고, 설정 열기는 전사 창이 앞에
    /// 있을 때만 듣는다. 저장 방식은 같으므로 키 이름만 나눈다.
    enum Slot {
        /// 전사 창을 어디서든 띄운다. Carbon으로 전역 등록한다.
        case transcriptWindow
        /// 설정 창을 연다. 전사 창이 앞에 있을 때만 듣는다.
        case settingsWindow

        var keyCodeKey: String {
            switch self {
            case .transcriptWindow: "hotKeyCode"
            case .settingsWindow: "settingsHotKeyCode"
            }
        }

        var modifiersKey: String {
            switch self {
            case .transcriptWindow: "hotKeyModifiers"
            case .settingsWindow: "settingsHotKeyModifiers"
            }
        }

        /// 사용자가 아무것도 정하지 않았을 때의 조합.
        var defaultShortcut: HotKeyShortcut {
            switch self {
            case .transcriptWindow: .default
            // macOS 앱의 설정 단축키 관례를 기본값으로 둔다. 다른 앱이 이 조합을 전역으로
            // 점유하면 이 앱 안에서는 이길 수 없으므로 사용자가 바꿀 수 있어야 한다.
            case .settingsWindow: HotKeyShortcut(
                keyCode: UInt32(kVK_ANSI_Comma),
                modifiers: [.command]
            )
            }
        }
    }

    /// 앱을 다시 켜도 사용자가 정한 조합이 유지되도록 저장한다.
    ///
    /// 저장된 값이 없으면 기본값을 쓴다 — 사용자가 아무것도 설정하지 않은 상태에서도
    /// 단축키가 바로 동작해야 한다.
    static func load(
        _ slot: Slot = .transcriptWindow,
        from defaults: UserDefaults = .standard
    ) -> HotKeyShortcut {
        guard defaults.object(forKey: slot.keyCodeKey) != nil else { return slot.defaultShortcut }
        let shortcut = HotKeyShortcut(
            keyCode: UInt32(defaults.integer(forKey: slot.keyCodeKey)),
            modifiers: NSEvent.ModifierFlags(
                rawValue: UInt(defaults.integer(forKey: slot.modifiersKey))
            )
        )
        // 저장된 값이 손상됐으면 기능을 잃는 대신 기본값으로 되돌린다. 설정 단축키가 이렇게
        // 되면 설정 창에 도달할 수단이 하나 줄어드는 셈이라 특히 중요하다.
        return shortcut.isValid ? shortcut : slot.defaultShortcut
    }

    func save(_ slot: Slot = .transcriptWindow, to defaults: UserDefaults = .standard) {
        defaults.set(Int(keyCode), forKey: slot.keyCodeKey)
        defaults.set(Int(modifiers.rawValue), forKey: slot.modifiersKey)
    }
}
