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
                languageSettings: delegate.languageSettings,
                openSettings: { delegate.windows.showSettings() }
            )
        } label: {
            menuBarIcon
        }
        .menuBarExtraStyle(.window)
    }

    @ViewBuilder
    private var menuBarIcon: some View {
        let appearance = MenuBarRecordingAppearance(state: delegate.recorder.state)
        if appearance.highlightsRecording {
            Image(nsImage: MenuBarRecordingAppearance.recordingImage())
                .accessibilityLabel(tr("녹취 중", "Recording"))
        } else {
            Image(systemName: appearance.symbolName)
                .accessibilityLabel(tr("Scribird 대기 중", "Scribird idle"))
        }
    }
}

struct MenuBarRecordingAppearance: Equatable {
    let symbolName: String
    let highlightsRecording: Bool

    init(state: MeetingRecorder.State) {
        highlightsRecording = state == .recording
        symbolName = highlightsRecording ? "waveform.circle.fill" : "waveform.circle"
    }

    static func recordingImage() -> NSImage {
        let symbol = NSImage(
            systemSymbolName: "waveform.circle.fill",
            accessibilityDescription: tr("녹취 중", "Recording")
        ) ?? NSImage()
        let configuration = NSImage.SymbolConfiguration(
            paletteColors: [.white, .systemRed]
        )
        let image = symbol.withSymbolConfiguration(configuration) ?? symbol
        image.isTemplate = false
        image.size = NSSize(width: 18, height: 18)
        return image
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
    let microphoneMuteHotKeySettings = MicrophoneMuteHotKeySettings()
    let updateChecker = UpdateChecker()
    let languageSettings = AppLanguageSettings()
    private var microphoneMuteMonitor: Any?
    lazy var windows = WindowCoordinator(
        recorder: recorder,
        hotKeySettings: hotKeySettings,
        settingsHotKeySettings: settingsHotKeySettings,
        microphoneMuteHotKeySettings: microphoneMuteHotKeySettings,
        updateChecker: updateChecker,
        languageSettings: languageSettings
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        microphoneMuteHotKeySettings.setConflictProvider {
            [weak hotKeySettings, weak settingsHotKeySettings] in
            [hotKeySettings?.shortcut, settingsHotKeySettings?.shortcut].compactMap { $0 }
        }
        // 사용자가 메뉴바를 열지 않아도 단축키가 준비돼 있어야 한다.
        windows.activateHotKey()
        microphoneMuteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak recorder, weak microphoneMuteHotKeySettings] event in
            guard microphoneMuteHotKeySettings?.matches(event) == true,
                  recorder?.canToggleMicrophoneMute == true
            else { return event }
            recorder?.toggleMicrophoneMute()
            return nil
        }
        Task { await recorder.installRequiredEnglishIfNeeded() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let microphoneMuteMonitor {
            NSEvent.removeMonitor(microphoneMuteMonitor)
        }
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
        microphoneMuteHotKeySettings: MicrophoneMuteHotKeySettings,
        updateChecker: UpdateChecker,
        languageSettings: AppLanguageSettings
    ) {
        self.hotKeySettings = hotKeySettings
        self.settingsWindow = SettingsWindow(
            recorder: recorder,
            hotKeySettings: hotKeySettings,
            settingsHotKeySettings: settingsHotKeySettings,
            microphoneMuteHotKeySettings: microphoneMuteHotKeySettings,
            updateChecker: updateChecker,
            languageSettings: languageSettings
        )
        let settings = settingsWindow
        let transcriptWindow = FloatingTranscriptWindow(
            recorder: recorder,
            settings: hotKeySettings,
            settingsHotKey: settingsHotKeySettings,
            languageSettings: languageSettings,
            openSettings: { settings.show() }
        )
        self.transcriptWindow = transcriptWindow

        // 폴더를 열 때 전사 창이 그 위를 덮지 않게 비켜 준다.
        //
        // 이 연결을 여기서 만드는 이유는 조정자가 창을 알지 못하기 때문이다 — 조정자는
        // "폴더를 연다"만 알고, 그 결과 어떤 창이 앞자리를 넘겨야 하는지는 창을 조립하는
        // 이곳이 안다.
        recorder.folderOpener = .yieldingFront(
            to: .system,
            yield: { transcriptWindow.yieldFront() }
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
