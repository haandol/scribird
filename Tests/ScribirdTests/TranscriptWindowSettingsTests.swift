import AppKit
import SwiftUI
import XCTest
@testable import Scribird

@MainActor
final class TranscriptWindowSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var domain: String!
    private var previousLanguage: AppLanguage!

    override func setUp() async throws {
        _ = NSApplication.shared
        domain = "scribird.window-tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: domain)
        previousLanguage = AppLanguage.current
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: domain)
        AppLanguage.setCurrent(previousLanguage)
    }

    func test_defaultAndInvalidPreference_keepTranscriptOnTop() {
        XCTAssertTrue(TranscriptWindowSettings(defaults: defaults).keepsOnTop)
        for value: Any in ["broken", ["unknown"], Data([2]), 2] {
            defaults.set(value, forKey: TranscriptWindowSettings.preferenceKey)
            XCTAssertTrue(TranscriptWindowSettings(defaults: defaults).keepsOnTop)
        }
    }

    func test_savedOffAndOn_surviveSettingsRecreation() {
        let settings = TranscriptWindowSettings(defaults: defaults)
        settings.update(keepsOnTop: false)
        XCTAssertFalse(TranscriptWindowSettings(defaults: defaults).keepsOnTop)
        settings.update(keepsOnTop: true)
        XCTAssertTrue(TranscriptWindowSettings(defaults: defaults).keepsOnTop)
    }

    /// Exercises the actual NSWindow focus override that previously hardcoded `.floating`.
    func test_transcriptFocus_restoresConfiguredLevelAfterYield() {
        let settings = TranscriptWindowSettings(defaults: defaults)
        let recorder = MeetingRecorder()
        let controller = transcript(recorder: recorder, settings: settings)
        let window = controller.makeWindow()
        defer { window.close() }
        XCTAssertEqual(window.level, .floating)
        controller.yieldFront()
        XCTAssertEqual(window.level, .normal)
        settings.update(keepsOnTop: false)
        settings.update(keepsOnTop: true)
        XCTAssertEqual(window.level, .normal, "Changing the choice must not cover the utility")
        window.becomeKey()
        XCTAssertEqual(window.level, .floating)
        settings.update(keepsOnTop: false)
        XCTAssertEqual(window.level, .normal)
        controller.yieldFront()
        window.becomeKey()
        XCTAssertEqual(window.level, .normal, "Focus cannot turn an explicit off back on")
        XCTAssertEqual(recorder.state, .idle)
    }

    /// Both concrete factories must remain normal, including activation of an already-open utility.
    func test_settingsAndFileWindows_yieldLiveTranscriptAndRemainNormal() {
        let settings = TranscriptWindowSettings(defaults: defaults)
        let recorder = MeetingRecorder()
        let live = transcript(recorder: recorder, settings: settings).makeWindow()
        let language = AppLanguageSettings(stored: .english)
        let preferences = SettingsWindow(
            recorder: recorder, hotKeySettings: HotKeySettings(defaults: defaults),
            settingsHotKeySettings: SettingsHotKeySettings(defaults: defaults),
            microphoneMuteHotKeySettings: MicrophoneMuteHotKeySettings(defaults: defaults),
            updateChecker: UpdateChecker(), languageSettings: language, windowSettings: settings
        ).makeWindow()
        let file = FileTranscriptionWindow(windowSettings: settings).preparedWindow(languageSettings: language)
        defer { live.close(); preferences.close(); file.close() }
        for utility in [preferences, file] {
            live.becomeKey()
            XCTAssertEqual(live.level, .floating)
            XCTAssertEqual(utility.level, .normal)
            utility.becomeKey()
            XCTAssertEqual(live.level, .normal)
            XCTAssertEqual(utility.level, .normal)
        }
        XCTAssertEqual(recorder.state, .idle)
    }

    func test_fileWindowReopening_reusesWindowAndSelectedInput() throws {
        let model = FileTranscriptionModel()
        model.source = URL(filePath: "/tmp/window-retention-fixture.wav")
        model.engine = .qwen3
        let controller = FileTranscriptionWindow(model: model, windowSettings: TranscriptWindowSettings(defaults: defaults))
        let language = AppLanguageSettings(stored: .english)
        let window = controller.preparedWindow(languageSettings: language)
        window.close()
        XCTAssertTrue(window === controller.preparedWindow(languageSettings: language))
        let host = try XCTUnwrap(window.contentView as? NSHostingView<FileTranscriptionView>)
        XCTAssertTrue(host.rootView.model === model)
        XCTAssertEqual(model.source?.lastPathComponent, "window-retention-fixture.wav")
        XCTAssertEqual(model.engine, .qwen3)
        XCTAssertFalse(model.isRunning)
    }

    /// Uses independent preferences without registering a global hotkey or opening capture devices.
    private func transcript(recorder: MeetingRecorder, settings: TranscriptWindowSettings) -> FloatingTranscriptWindow {
        FloatingTranscriptWindow(
            recorder: recorder, settings: HotKeySettings(defaults: defaults),
            settingsHotKey: SettingsHotKeySettings(defaults: defaults),
            languageSettings: AppLanguageSettings(stored: .english), openSettings: {}, windowSettings: settings
        )
    }
}
