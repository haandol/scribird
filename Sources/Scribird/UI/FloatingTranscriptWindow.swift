import AppKit
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

    init(recorder: MeetingRecorder, settings: HotKeySettings) {
        self.recorder = recorder
        self.settings = settings
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        // 메뉴바 전용 앱(LSUIElement)은 활성화되지 않으므로 창이 키를 받으려면
        // 명시적으로 앞으로 끌어와야 한다. 스크롤·텍스트 선택이 이것에 의존한다.
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 540),
            // 닫기·최소화 버튼을 준다 — 자동으로 닫히지 않는 창이므로 사용자가
            // 치울 수단이 창 자체에 있어야 한다.
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Scribird"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        // 회의 화면에 가려지지 않아야 확인용으로 쓸 수 있다.
        window.level = .floating
        // 메뉴바 앱이라 마지막 창을 닫아도 앱이 종료되지 않아야 한다.
        window.isReleasedWhenClosed = false
        // 전체 화면 회의 앱 위에서도 보이게 한다.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentView = NSHostingView(
            rootView: TranscriptView(recorder: recorder, hotKeySettings: settings)
        )
        window.center()
        // 위치·크기를 기억해 다음 실행에서도 같은 자리에 뜬다.
        window.setFrameAutosaveName("ScribirdFloatingTranscript")
        return window
    }
}
