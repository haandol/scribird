import AppKit
import SwiftUI

@main
struct ScribirdApp: App {
    /// 앱 시작 시점에 상태와 창을 준비한다.
    ///
    /// `MenuBarExtra`의 콘텐츠 클로저 안에서 준비하면 안 된다 — 그 클로저는 사용자가
    /// 팝오버를 처음 열 때 만들어지므로, 전역 단축키가 그때까지 등록되지 않는다.
    /// 실측한 증상: 메뉴바 아이콘을 한 번 클릭하기 전에는 단축키가 동작하지 않았다.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // 메뉴바 상주. Info.plist의 LSUIElement와 짝을 이뤄 Dock에 뜨지 않는다.
        //
        // 단축키로 뜨는 떠 있는 창이 생겼어도 이 경로는 유지한다 — 단축키를 모르거나
        // 다른 앱과 충돌해 못 쓰는 사용자에게 유일한 도달 경로다.
        MenuBarExtra {
            TranscriptView(
                recorder: delegate.recorder,
                hotKeySettings: delegate.hotKeySettings,
                openSettings: { delegate.windows.showSettings() }
            )
        } label: {
            Image(
                systemName: delegate.recorder.state == .recording
                    ? "waveform.circle.fill"
                    : "waveform.circle"
            )
        }
        .menuBarExtraStyle(.window)
    }
}

/// 앱 수명과 함께 사는 상태를 들고 있다.
///
/// 전역 단축키는 UI가 하나도 그려지지 않은 상태에서도 동작해야 하므로, 등록을 뷰
/// 생명주기에 매달지 않고 시작 콜백에서 수행한다.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let recorder = MeetingRecorder()
    let hotKeySettings = HotKeySettings()
    let settingsHotKeySettings = SettingsHotKeySettings()
    let updateChecker = UpdateChecker()
    lazy var windows = WindowCoordinator(
        recorder: recorder,
        hotKeySettings: hotKeySettings,
        settingsHotKeySettings: settingsHotKeySettings,
        updateChecker: updateChecker
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 사용자가 메뉴바를 열지 않아도 단축키가 준비돼 있어야 한다.
        windows.activateHotKey()
    }
}

/// 전사 창·설정 창과 전역 단축키를 함께 들고 있다.
///
/// 두 창이 서로를 참조해야 한다 — 전사 화면에서 설정을 열고, 설정 창은 전사 창과
/// 독립적으로 떠 있어야 한다. 그 연결을 한 곳에서 만든다.
@MainActor
final class WindowCoordinator {
    private let hotKeySettings: HotKeySettings
    private let settingsWindow: SettingsWindow
    private let transcriptWindow: FloatingTranscriptWindow

    init(
        recorder: MeetingRecorder,
        hotKeySettings: HotKeySettings,
        settingsHotKeySettings: SettingsHotKeySettings,
        updateChecker: UpdateChecker
    ) {
        self.hotKeySettings = hotKeySettings
        self.settingsWindow = SettingsWindow(
            recorder: recorder,
            hotKeySettings: hotKeySettings,
            settingsHotKeySettings: settingsHotKeySettings,
            updateChecker: updateChecker
        )
        let settings = settingsWindow
        self.transcriptWindow = FloatingTranscriptWindow(
            recorder: recorder,
            settings: hotKeySettings,
            settingsHotKey: settingsHotKeySettings,
            openSettings: { settings.show() }
        )
    }

    func activateHotKey() {
        let window = transcriptWindow
        hotKeySettings.activate { window.toggle() }
    }

    func showSettings() {
        settingsWindow.show()
    }
}
