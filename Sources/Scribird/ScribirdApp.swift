import SwiftUI

@main
struct ScribirdApp: App {
    @State private var recorder = MeetingRecorder()
    @State private var hotKeySettings = HotKeySettings()
    @State private var updateChecker = UpdateChecker()
    @State private var windows: WindowCoordinator?

    var body: some Scene {
        // 메뉴바 상주. Info.plist의 LSUIElement와 짝을 이뤄 Dock에 뜨지 않는다.
        //
        // 단축키로 뜨는 떠 있는 창이 생겼어도 이 경로는 유지한다 — 단축키를 모르거나
        // 다른 앱과 충돌해 못 쓰는 사용자에게 유일한 도달 경로다.
        MenuBarExtra {
            TranscriptView(
                recorder: recorder,
                hotKeySettings: hotKeySettings,
                openSettings: { prepared().showSettings() }
            )
            .task { _ = prepared() }
        } label: {
            Image(systemName: recorder.state == .recording ? "waveform.circle.fill" : "waveform.circle")
        }
        .menuBarExtraStyle(.window)
    }

    /// 창들과 전역 단축키를 한 번만 준비한다.
    @MainActor
    private func prepared() -> WindowCoordinator {
        if let windows { return windows }
        let coordinator = WindowCoordinator(
            recorder: recorder,
            hotKeySettings: hotKeySettings,
            updateChecker: updateChecker
        )
        windows = coordinator
        coordinator.activateHotKey()
        return coordinator
    }
}

/// 전사 창·설정 창과 전역 단축키를 함께 들고 있다.
///
/// 두 창이 서로를 참조해야 한다 — 전사 화면에서 설정을 열고, 설정 창은 전사 창과
/// 독립적으로 떠 있어야 한다. 그 연결을 한 곳에서 만든다.
@MainActor
@Observable
final class WindowCoordinator {
    private let hotKeySettings: HotKeySettings
    private let settingsWindow: SettingsWindow
    private var transcriptWindow: FloatingTranscriptWindow?

    init(
        recorder: MeetingRecorder,
        hotKeySettings: HotKeySettings,
        updateChecker: UpdateChecker
    ) {
        self.hotKeySettings = hotKeySettings
        self.settingsWindow = SettingsWindow(
            recorder: recorder,
            hotKeySettings: hotKeySettings,
            updateChecker: updateChecker
        )
        let settings = settingsWindow
        self.transcriptWindow = FloatingTranscriptWindow(
            recorder: recorder,
            settings: hotKeySettings,
            openSettings: { settings.show() }
        )
    }

    func activateHotKey() {
        let window = transcriptWindow
        hotKeySettings.activate { window?.toggle() }
    }

    func showSettings() {
        settingsWindow.show()
    }
}
