import AppKit
import XCTest
@testable import Scribird

@MainActor
final class HotKeyFailureTests: XCTestCase {
    /// Reproduces successful rollback erasing the registration failure notice.
    func test_failedChange_restoresPreviousShortcutAndRetainsFailureNotice() throws {
        let domain = "scribird.hotkey-failure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let previous = HotKeyShortcut.default
        let candidate = HotKeyShortcut(keyCode: 0, modifiers: [.control, .option])
        var attempts: [HotKeyShortcut] = []
        let settings = HotKeySettings(shortcut: previous, defaults: defaults) { shortcut in
            attempts.append(shortcut)
            if shortcut == candidate { throw TestError.requested }
        }
        settings.update(to: candidate)
        XCTAssertEqual(attempts, [candidate, previous])
        XCTAssertEqual(settings.shortcut, previous)
        XCTAssertEqual(HotKeyShortcut.load(from: defaults), previous)
        XCTAssertEqual(settings.registrationError, TestError.requested.localizedDescription)
        settings.update(to: previous)
        XCTAssertNil(settings.registrationError)
    }

    func test_failedChangeAndFailedRollback_preserveBothReasons() throws {
        let domain = "scribird.hotkey-rollback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let previous = HotKeyShortcut.default
        let candidate = HotKeyShortcut(keyCode: 0, modifiers: [.control, .option])
        let settings = HotKeySettings(shortcut: previous, defaults: defaults) { shortcut in
            throw shortcut == candidate ? TestError.requested : TestError.rollback
        }
        settings.update(to: candidate)
        XCTAssertEqual(settings.shortcut, previous)
        let message = try XCTUnwrap(settings.registrationError)
        XCTAssertTrue(message.contains(TestError.requested.localizedDescription))
        XCTAssertTrue(message.contains(TestError.rollback.localizedDescription))
    }

    /// Negative integers previously trapped instead of restoring each slot's default.
    func test_corruptStoredShortcut_fallsBackWithoutTrapping() throws {
        let domain = "scribird.hotkey-corruption.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        for slot in [HotKeyShortcut.Slot.transcriptWindow, .settingsWindow, .microphoneMute] {
            for key: Any in [-1, Int.max, 65_536, "corrupt", [1], false, 0.5] {
                defaults.set(key, forKey: slot.keyCodeKey)
                defaults.set(Int(NSEvent.ModifierFlags.command.rawValue), forKey: slot.modifiersKey)
                XCTAssertEqual(HotKeyShortcut.load(slot, from: defaults), slot.defaultShortcut)
            }
            defaults.set(0, forKey: slot.keyCodeKey)
            for modifiers: Any in [-1, Int.max, "corrupt", [1], false, 0.5] {
                defaults.set(modifiers, forKey: slot.modifiersKey)
                XCTAssertEqual(HotKeyShortcut.load(slot, from: defaults), slot.defaultShortcut)
            }
        }
    }

    func test_numericStringShortcut_retainsInterpretableLegacySelection() throws {
        let domain = "scribird.hotkey-legacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let expected = HotKeyShortcut(keyCode: 12, modifiers: [.command, .option])
        for slot in [HotKeyShortcut.Slot.transcriptWindow, .settingsWindow, .microphoneMute] {
            defaults.set("12", forKey: slot.keyCodeKey)
            defaults.set(String(expected.modifiers.rawValue), forKey: slot.modifiersKey)
            XCTAssertEqual(HotKeyShortcut.load(slot, from: defaults), expected)
        }
    }

    func test_unrepresentablePhysicalKey_doesNotTrapWhileDisplayingOrMatching() throws {
        let shortcut = HotKeyShortcut(keyCode: UInt32.max, modifiers: .command)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 0
        ))
        XCTAssertFalse(shortcut.isValid)
        XCTAssertNotNil(shortcut.validationError)
        XCTAssertFalse(shortcut.matches(event))
        XCTAssertTrue(shortcut.displayName.contains("Key"))
    }

    private enum TestError: String, LocalizedError {
        case requested, rollback
        var errorDescription: String? { rawValue }
    }
}
