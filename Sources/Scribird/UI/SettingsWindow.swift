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
    private let settingsHotKeySettings: SettingsHotKeySettings
    private let updateChecker: UpdateChecker

    init(
        recorder: MeetingRecorder,
        hotKeySettings: HotKeySettings,
        settingsHotKeySettings: SettingsHotKeySettings,
        updateChecker: UpdateChecker
    ) {
        self.recorder = recorder
        self.hotKeySettings = hotKeySettings
        self.settingsHotKeySettings = settingsHotKeySettings
        self.updateChecker = updateChecker
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        // 메뉴바 전용 앱(LSUIElement)은 활성화되지 않으므로 창이 키를 받으려면
        // 명시적으로 앞으로 끌어와야 한다. 단축키 입력 필드가 이것에 의존한다.
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 이미 떠 있는 창을 다시 열 때도 앞으로 끌어온다. 같은 층에서는 순서가 마지막
        // 호출로 정해지므로, 전사 창을 만진 뒤 설정을 다시 열면 이 호출이 필요하다.
        window.orderFrontRegardless()
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
        // 전사 창과 같은 층에 둔다.
        //
        // 전사 창은 회의 화면에 가려지지 않으려고 `.floating`이다. 설정 창을 기본 레벨로
        // 두면 키 윈도우가 되어도 전사 창 뒤에 깔린다 — 레벨이 키 상태보다 우선하기
        // 때문이다. 실측:
        //
        // ```
        // floating(전사) + normal(설정) → 위: 전사, 설정은 isKey=true인데도 뒤
        // floating(전사) + floating(설정) → 위: 설정 (나중에 부른 창)
        // ```
        //
        // 같은 층에 두면 마지막에 부른 창이 앞에 오므로, 설정을 열면 설정이 보이고 전사
        // 창을 다시 부르면 그쪽이 앞에 온다.
        window.level = .floating
        // 전체 화면 회의 앱 위에서도 설정을 열 수 있어야 한다. 전사 창과 같은 조건으로
        // 두지 않으면 회의 중에 설정만 다른 공간으로 튄다.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // 메뉴바 앱이라 창을 닫아도 앱이 종료되지 않아야 한다.
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: SettingsView(
                recorder: recorder,
                hotKeySettings: hotKeySettings,
                settingsHotKeySettings: settingsHotKeySettings,
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
