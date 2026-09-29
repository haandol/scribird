import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 전사 화면을 담은 떠 있는 창.
///
/// 메뉴바 팝오버와 구분되는 성질이 **포커스를 잃어도 닫히지 않는다**는 것이다.
/// 회의 앱을 앞에 두고 전사를 곁에 두는 것이 이 창의 목적이므로, 다른 앱을 만지면
/// 사라지는 팝오버로는 그 사용을 지원할 수 없다.
@MainActor
final class FloatingTranscriptWindow {
    private var window: NSWindow?
    private let recorder: MeetingRecorder
    private let settings: HotKeySettings
    private let settingsHotKey: SettingsHotKeySettings
    private let languageSettings: AppLanguageSettings
    private let openSettings: () -> Void
    private let windowSettings: TranscriptWindowSettings

    /// Shares the display preference with utility windows while keeping recording lifetime independent.
    init(
        recorder: MeetingRecorder,
        settings: HotKeySettings,
        settingsHotKey: SettingsHotKeySettings,
        languageSettings: AppLanguageSettings,
        openSettings: @escaping () -> Void,
        windowSettings: TranscriptWindowSettings = .shared
    ) {
        self.recorder = recorder
        self.settings = settings
        self.settingsHotKey = settingsHotKey
        self.languageSettings = languageSettings
        self.openSettings = openSettings
        self.windowSettings = windowSettings
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    /// Yields to a utility window or folder without changing the user's pinning preference.
    /// Measured: retaining level 3 left Finder (level 0) behind the transcript even when Finder
    /// was active. Lowering to level 0 let Finder come first. Only recalling the transcript
    /// restores its configured level, so it cannot cover the folder again on a timer.
    func yieldFront() {
        windowSettings.yieldFront()
    }

    /// Recalls the existing transcript using the saved pinning choice without restarting recording.
    func show() {
        let window = window ?? makeWindow()
        self.window = window
        windowSettings.restoreFront()
        // 메뉴바 전용 앱(LSUIElement)은 활성화되지 않으므로 창이 키를 받으려면
        // 명시적으로 앞으로 끌어와야 한다. 스크롤·텍스트 선택이 이것에 의존한다.
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        window?.orderOut(nil)
    }

    /// Builds an independent transcript surface and binds focus restoration to the user's pinning choice.
    func makeWindow() -> NSWindow {
        let window = SettingsShortcutWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 540),
            // 닫기·최소화 버튼을 준다 — 자동으로 닫히지 않는 창이므로 사용자가
            // 치울 수단이 창 자체에 있어야 한다.
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.onSettingsShortcut = openSettings
        window.onBecomeKey = { [windowSettings] in windowSettings.restoreFront() }
        // 조합을 붙잡아 두지 않고 그때그때 물어본다 — 사용자가 설정에서 바꾸면 다음 키 입력부터
        // 바로 반영돼야 한다.
        let hotKey = settingsHotKey
        window.matchesSettingsShortcut = { hotKey.matches($0) }
        // 닫는 것은 숨기는 것이다 — 녹취에는 영향이 없다(창의 표시 여부와 녹취는 독립).
        window.onCloseShortcut = { [weak window] in window?.orderOut(nil) }
        window.title = "Scribird"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        windowSettings.attach(window)
        // 메뉴바 앱이라 마지막 창을 닫아도 앱이 종료되지 않아야 한다.
        window.isReleasedWhenClosed = false
        // 전체 화면 회의 앱 위에서도 보이게 한다.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentView = NSHostingView(
            rootView: TranscriptView(
                recorder: recorder,
                hotKeySettings: settings,
                languageSettings: languageSettings,
                openSettings: openSettings
            )
        )
        window.center()
        // 위치·크기를 기억해 다음 실행에서도 같은 자리에 뜬다.
        window.setFrameAutosaveName("ScribirdFloatingTranscript")
        return window
    }
}

/// 창을 닫는 표준 단축키(`⌘W`) 판정.
///
/// 이 창은 자동으로 닫히지 않으므로 치우는 수단이 창에 있어야 하고, 사용자가 이미 아는 조작을
/// 다시 배우게 할 이유가 없다. `⌘,`와 같은 이유로 창의 `sendEvent`에서 가로챈다 — 메뉴바 전용
/// 앱에는 메인 메뉴가 없어 표준 경로가 닿지 않는다.
enum WindowCloseShortcut {
    /// **키 코드로 판정한다.** 한글 입력기가 켜져 있으면 `charactersIgnoringModifiers`가 비어
    /// 도착하므로(이 앱의 다른 단축키에서 실측된 동작) 문자 비교는 조합 중에 조용히 멈춘다.
    ///
    /// 수정자는 정확히 `⌘`만일 때로 한정한다. `⇧⌘W`·`⌥⌘W`는 다른 앱에서 다른 뜻을 가지므로
    /// 넉넉하게 받으면 사용자가 의도하지 않은 닫기가 일어난다.
    static func matches(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        keyCode == UInt16(kVK_ANSI_W)
            && modifiers.intersection(.deviceIndependentFlagsMask) == .command
    }
}

/// `⌘,`를 직접 받아 설정 창을 여는 창.
///
/// **SwiftUI의 `.keyboardShortcut`은 이 앱에서 동작하지 않는다.** 그것은 메뉴 시스템을 거쳐
/// 처리되는데, `MenuBarExtra` 전용 앱(`LSUIElement`)에는 메인 메뉴가 없다. 실측:
///
/// ```
/// NSApp.mainMenu → nil
/// keyWindow는 정상인데도 버튼에 붙인 .keyboardShortcut(",", modifiers: .command)이
/// 호출되지 않았다
/// ```
///
/// 그래서 키 이벤트를 창에서 직접 가로챈다. 실측으로 이 경로는 메뉴 없이 동작한다.
///
/// 메인 메뉴를 만들어 해결하지 않는 이유: 메뉴바 전용 앱에 메뉴를 붙이면 앱을 활성화할 때마다
/// 화면 상단 메뉴바가 이 앱의 것으로 바뀐다. Dock에도 뜨지 않는 앱이 상단 메뉴를 점유하는 것은
/// 사용자가 기대하는 동작이 아니다.
private final class SettingsShortcutWindow: NSWindow {
    var onBecomeKey: (() -> Void)?
    var onSettingsShortcut: (() -> Void)?
    /// 어떤 조합을 설정 열기로 볼지. 사용자가 바꿀 수 있으므로 값을 물어서 판정한다.
    var matchesSettingsShortcut: ((NSEvent) -> Bool)?
    /// `⌘W`로 창을 치울 때의 동작.
    var onCloseShortcut: (() -> Void)?

    /// Restores the configured display level when recalled, including an explicit choice to remain normal.
    override func becomeKey() {
        super.becomeKey()
        onBecomeKey?()
    }

    private func isCloseShortcut(_ event: NSEvent) -> Bool {
        WindowCloseShortcut.matches(keyCode: event.keyCode, modifiers: event.modifierFlags)
    }

    /// `sendEvent`에서 가로챈다 — `performKeyEquivalent`보다 앞이다.
    ///
    /// 키 입력은 `sendEvent` → 입력기 → responder chain → `performKeyEquivalent` 순으로
    /// 흐른다. 한글 입력기가 켜져 있으면 그 사이에서 키가 소비돼 뒤쪽까지 오지 않을 수 있고,
    /// `NSHostingView` 안의 SwiftUI도 자기 단축키를 먼저 처리한다. 진입점에서 잡으면 그 둘을
    /// 모두 앞지른다.
    ///
    /// SwiftUI의 `.keyboardShortcut`을 쓸 수 없는 이유: 그것은 메뉴 시스템을 거쳐 처리되는데
    /// 메뉴바 전용 앱(`LSUIElement`)에는 메인 메뉴가 없다(실측: `NSApp.mainMenu`가 nil).
    /// 메뉴를 만들어 해결하지 않는 것은, 메뉴바 전용 앱이 화면 상단 메뉴바를 점유하는 것이
    /// 사용자가 기대하는 동작이 아니기 때문이다.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            // 설정 단축키를 먼저 본다 — 사용자가 그것을 `⌘W`로 바꿔 두었다면 그 의도가
            // 기본 닫기보다 앞선다.
            if matchesSettingsShortcut?(event) == true {
                onSettingsShortcut?()
                return
            }
            if isCloseShortcut(event) {
                onCloseShortcut?()
                return
            }
        }
        super.sendEvent(event)
    }
}
