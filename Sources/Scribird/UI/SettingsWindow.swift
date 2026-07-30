import AppKit
import SwiftUI

/// 설정 창.
///
/// 전사 창과 독립적으로 열고 닫힌다 — 설정을 보는 동안 트랜스크립트가 가려지거나
/// 녹취가 멈추지 않아야 한다. 회의 화면 곁에 띄워 둔 전사 창을 덮지 않는 것이 별도
/// 창으로 분리한 이유의 절반이다.
@MainActor
final class SettingsWindow {
    private var window: NSWindow?
    private let recorder: MeetingRecorder
    private let hotKeySettings: HotKeySettings
    private let updateChecker: UpdateChecker

    init(
        recorder: MeetingRecorder,
        hotKeySettings: HotKeySettings,
        updateChecker: UpdateChecker
    ) {
        self.recorder = recorder
        self.hotKeySettings = hotKeySettings
        self.updateChecker = updateChecker
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        // 메뉴바 전용 앱(LSUIElement)은 활성화되지 않으므로 창이 키를 받으려면
        // 명시적으로 앞으로 끌어와야 한다. 단축키 입력 필드가 이것에 의존한다.
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
            // 크기 조절을 주지 않는다 — 내용 높이에 맞춰 뜨는 설정 창이다.
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Scribird 설정"
        // 메뉴바 앱이라 창을 닫아도 앱이 종료되지 않아야 한다.
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: SettingsView(
                recorder: recorder,
                hotKeySettings: hotKeySettings,
                updateChecker: updateChecker
            )
        )
        // 내용이 요구하는 높이로 맞춘다. 고정 높이로 두면 항목이 잘린다.
        window.setContentSize(window.contentView?.fittingSize ?? window.frame.size)
        window.center()
        window.setFrameAutosaveName("ScribirdSettings")
        return window
    }
}
