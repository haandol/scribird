import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Scribird

@MainActor
final class MicrophoneMuteShortcutTests: XCTestCase {
    private var defaults: UserDefaults!
    private let domain = "scribird.microphonemuteshortcut.tests"

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: domain)
        defaults.removePersistentDomain(forName: domain)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: domain)
        defaults = nil
        try await super.tearDown()
    }

    func test_default_isCommandY() {
        let shortcut = HotKeyShortcut.Slot.microphoneMute.defaultShortcut

        XCTAssertEqual(shortcut.keyCode, UInt32(kVK_ANSI_Y))
        XCTAssertEqual(shortcut.modifiers, [.command])
        XCTAssertEqual(shortcut.displayName, "⌘Y")
    }

    func test_savedShortcut_isRestoredIndependently() {
        let custom = HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_M),
            modifiers: [.command, .option]
        )
        custom.save(.microphoneMute, to: defaults)

        XCTAssertEqual(
            HotKeyShortcut.load(.microphoneMute, from: defaults),
            custom
        )
        XCTAssertEqual(
            HotKeyShortcut.load(.settingsWindow, from: defaults),
            HotKeyShortcut.Slot.settingsWindow.defaultShortcut
        )
        XCTAssertEqual(
            HotKeyShortcut.load(.transcriptWindow, from: defaults),
            HotKeyShortcut.Slot.transcriptWindow.defaultShortcut
        )
    }

    func test_storedShortcutWithoutModifiers_fallsBackToDefault() {
        HotKeyShortcut(keyCode: UInt32(kVK_ANSI_M), modifiers: [])
            .save(.microphoneMute, to: defaults)

        XCTAssertEqual(
            HotKeyShortcut.load(.microphoneMute, from: defaults),
            HotKeyShortcut.Slot.microphoneMute.defaultShortcut
        )
    }

    func test_configuredShortcut_matchesWithoutReadingInputMethodCharacters() throws {
        let settings = MicrophoneMuteHotKeySettings(defaults: defaults)
        let event = try keyEvent(
            keyCode: UInt16(kVK_ANSI_Y),
            modifiers: .command,
            characters: ""
        )

        XCTAssertTrue(settings.matches(event))
    }

    func test_configuredShortcut_withAdditionalModifier_doesNotMatch() throws {
        let settings = MicrophoneMuteHotKeySettings(defaults: defaults)
        for modifiers in [
            NSEvent.ModifierFlags([.command, .shift]),
            NSEvent.ModifierFlags([.command, .option]),
            NSEvent.ModifierFlags([.command, .control]),
        ] {
            XCTAssertFalse(
                settings.matches(
                    try keyEvent(
                        keyCode: UInt16(kVK_ANSI_Y),
                        modifiers: modifiers,
                        characters: "y"
                    )
                )
            )
        }
    }

    func test_repeatedConfiguredShortcut_doesNotMatch() throws {
        let settings = MicrophoneMuteHotKeySettings(defaults: defaults)
        let event = try keyEvent(
            keyCode: UInt16(kVK_ANSI_Y),
            modifiers: .command,
            characters: "y",
            isRepeat: true
        )

        XCTAssertFalse(settings.matches(event))
    }

    func test_update_takesEffectOnTheNextKeyEvent() throws {
        let settings = MicrophoneMuteHotKeySettings(defaults: defaults)
        let oldEvent = try keyEvent(
            keyCode: UInt16(kVK_ANSI_Y),
            modifiers: .command,
            characters: "y"
        )
        let replacement = HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_M),
            modifiers: [.command, .option]
        )

        settings.update(to: replacement)

        XCTAssertFalse(settings.matches(oldEvent))
        XCTAssertTrue(settings.matches(try keyEvent(
            keyCode: UInt16(kVK_ANSI_M),
            modifiers: [.command, .option],
            characters: "m"
        )))
        XCTAssertEqual(HotKeyShortcut.load(.microphoneMute, from: defaults), replacement)
    }

    func test_update_rejectsShortcutWithoutRequiredModifier() {
        let settings = MicrophoneMuteHotKeySettings(defaults: defaults)
        let before = settings.shortcut

        settings.update(to: HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_M),
            modifiers: [.shift]
        ))

        XCTAssertEqual(settings.shortcut, before)
        XCTAssertNotNil(settings.validationError)
    }

    func test_update_rejectsShortcutUsedByAnotherScribirdAction() {
        let settings = MicrophoneMuteHotKeySettings(defaults: defaults)
        let settingsWindowShortcut = HotKeyShortcut.Slot.settingsWindow.defaultShortcut
        settings.setConflictProvider { [settingsWindowShortcut] }
        let before = settings.shortcut

        settings.update(to: settingsWindowShortcut)

        XCTAssertEqual(settings.shortcut, before)
        XCTAssertNotNil(settings.validationError)
    }

    func test_rejectedEdit_keepsThePreviousShortcutActive() throws {
        let settings = MicrophoneMuteHotKeySettings(defaults: defaults)
        let conflict = HotKeyShortcut.Slot.settingsWindow.defaultShortcut
        settings.setConflictProvider { [conflict] }

        settings.update(to: conflict)

        XCTAssertTrue(settings.matches(try keyEvent(
            keyCode: UInt16(kVK_ANSI_Y),
            modifiers: .command,
            characters: "y"
        )))
    }

    func test_currentShortcutConflict_disablesMatchingUntilConflictChanges() throws {
        let settings = MicrophoneMuteHotKeySettings(defaults: defaults)
        let other = SettingsHotKeySettings(
            shortcut: HotKeyShortcut.Slot.microphoneMute.defaultShortcut
        )
        settings.setConflictProvider { [other] in [other.shortcut] }
        let event = try keyEvent(
            keyCode: UInt16(kVK_ANSI_Y),
            modifiers: .command,
            characters: "y"
        )

        XCTAssertFalse(settings.matches(event))
        XCTAssertNotNil(settings.validationError)

        other.update(to: HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_P),
            modifiers: [.command, .option]
        ))

        XCTAssertTrue(settings.matches(event))
        XCTAssertNil(settings.validationError)
    }

    func test_resetToDefault_restoresCommandY() {
        let custom = HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_M),
            modifiers: [.command, .option]
        )
        let settings = MicrophoneMuteHotKeySettings(
            shortcut: custom,
            defaults: defaults
        )

        settings.resetToDefault()

        XCTAssertEqual(
            settings.shortcut,
            HotKeyShortcut.Slot.microphoneMute.defaultShortcut
        )
    }

    private func keyEvent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        characters: String,
        isRepeat: Bool = false
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: isRepeat,
                keyCode: keyCode
            )
        )
    }
}
