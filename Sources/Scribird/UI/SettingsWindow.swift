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
    private let languageSettings: AppLanguageSettings

    init(
        recorder: MeetingRecorder,
        hotKeySettings: HotKeySettings,
        settingsHotKeySettings: SettingsHotKeySettings,
        updateChecker: UpdateChecker,
        languageSettings: AppLanguageSettings
    ) {
        self.recorder = recorder
        self.hotKeySettings = hotKeySettings
        self.settingsHotKeySettings = settingsHotKeySettings
        self.updateChecker = updateChecker
        self.languageSettings = languageSettings
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
            // 뷰가 요구하는 크기와 같게 둔다. 어긋나면 첫 표시에서 내용이 잘리거나 여백이 남는다.
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
            // 크기 조절을 주지 않는다 — 탭이 그 안에서 스크롤한다.
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = tr("Scribird 설정", "Scribird Settings")
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
        // **창 크기를 내용에 따라 바꾸지 않는다.** 뷰가 자기 높이를 정하고 창이 그것을 따라가게
        // 하면 Auto Layout이 수렴하지 않는다 — 뷰가 높이를 요구하면 창이 커지고, 커진 창이 다시
        // 레이아웃을 유발한다. 실측: `sizingOptions = .preferredContentSize`와 뷰의
        // `fixedSize(vertical:)`를 함께 쓴 상태에서 탭을 바꾸면 즉시 죽었다.
        //
        // ```
        // NSGenericException: The window has been marked as needing another Update Constraints
        // in Window pass, but it has already had more ... passes than there are views
        // ```
        //
        // 그래서 창은 고정 크기이고, 내용이 그보다 길면 뷰 쪽이 스크롤한다. 탭마다 높이가 다른
        // 것은 짧은 탭에 빈 공간이 남는 것으로 받아들인다 — 잘려서 도달할 수 없는 항목이 생기는
        // 것보다 낫다.
        let controller = NSHostingController(
            rootView: SettingsView(
                recorder: recorder,
                hotKeySettings: hotKeySettings,
                settingsHotKeySettings: settingsHotKeySettings,
                updateChecker: updateChecker,
                languageSettings: languageSettings
            )
        )
        window.contentViewController = controller
        window.center()
        window.setFrameAutosaveName("ScribirdSettings")
        return window
    }
}
