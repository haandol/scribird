import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Scribird

/// 설정 창을 여는 단축키 테스트.
///
/// 검증 대상 계약: 기본값은 `⌘,`다 / 사용자가 정한 조합은 앱을 다시 켜도 유지된다 / 두 단축키가
/// 서로의 저장값을 덮지 않는다 / 수정자 없는 조합은 거부한다 / 손상된 저장값은 기본값으로
/// 되돌린다.
///
/// 이 단축키가 바꿀 수 있어야 하는 이유는 실측에서 나왔다 — 메뉴바 유틸리티가 `⌘,`를 전역으로
/// 등록한 환경에서 앱이 반응하지 않았고, 그 유틸리티를 종료하자 즉시 동작했다. 다른 앱이 전역으로
/// 점유한 조합은 앱 안에서 이길 수 없으므로 사용자가 다른 조합을 고를 수 있어야 한다.
final class SettingsHotKeyTests: XCTestCase {

    private var defaults: UserDefaults!
    private let domain = "scribird.settingshotkey.tests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: domain)
        defaults.removePersistentDomain(forName: domain)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: domain)
        defaults = nil
        super.tearDown()
    }

    // MARK: - 기본값

    /// macOS 앱의 설정 단축키 관례를 기본값으로 둔다.
    func test_default_isCommandComma() {
        let shortcut = HotKeyShortcut.Slot.settingsWindow.defaultShortcut

        XCTAssertEqual(shortcut.keyCode, UInt32(kVK_ANSI_Comma))
        XCTAssertEqual(shortcut.modifiers, [.command])
        XCTAssertEqual(shortcut.displayName, "⌘,",
                       "기본 단축키 표시가 macOS 관례와 다르다")
    }

    func test_load_withNothingStored_returnsCommandComma() {
        XCTAssertEqual(
            HotKeyShortcut.load(.settingsWindow, from: defaults),
            HotKeyShortcut.Slot.settingsWindow.defaultShortcut,
            "저장값이 없을 때 기본값이 적용되지 않았다"
        )
    }

    // MARK: - 두 단축키의 독립성

    /// **두 단축키가 서로의 저장값을 덮지 않는다.**
    ///
    /// 같은 키에 저장하면 하나를 바꾸는 순간 다른 하나가 함께 바뀐다. 전사 창 단축키를 바꿨더니
    /// 설정 단축키도 같은 조합이 되면, 두 조합이 충돌해 한쪽이 동작하지 않는다.
    func test_twoSlots_doNotShareStorage() {
        let transcriptShortcut = HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_T), modifiers: [.control, .option]
        )
        let settingsShortcut = HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_P), modifiers: [.command, .shift]
        )

        transcriptShortcut.save(.transcriptWindow, to: defaults)
        settingsShortcut.save(.settingsWindow, to: defaults)

        XCTAssertEqual(HotKeyShortcut.load(.transcriptWindow, from: defaults), transcriptShortcut,
                       "설정 단축키를 저장했더니 전사 창 단축키가 덮였다")
        XCTAssertEqual(HotKeyShortcut.load(.settingsWindow, from: defaults), settingsShortcut,
                       "전사 창 단축키를 저장했더니 설정 단축키가 덮였다")
    }

    /// 한쪽만 저장돼 있으면 다른 쪽은 자기 기본값을 쓴다.
    ///
    /// 두 기본값이 다르므로(⌥⌘S vs ⌘,) 한쪽 저장값을 다른 쪽 기본값으로 오인하면 안 된다.
    func test_savingOneSlot_leavesTheOtherAtItsOwnDefault() {
        HotKeyShortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: [.command])
            .save(.transcriptWindow, to: defaults)

        XCTAssertEqual(
            HotKeyShortcut.load(.settingsWindow, from: defaults),
            HotKeyShortcut.Slot.settingsWindow.defaultShortcut,
            "전사 창 단축키만 저장했는데 설정 단축키 기본값이 달라졌다"
        )
    }

    /// 두 slot의 저장 키가 서로 다르다.
    func test_slotStorageKeys_differ() {
        XCTAssertNotEqual(
            HotKeyShortcut.Slot.transcriptWindow.keyCodeKey,
            HotKeyShortcut.Slot.settingsWindow.keyCodeKey
        )
        XCTAssertNotEqual(
            HotKeyShortcut.Slot.transcriptWindow.modifiersKey,
            HotKeyShortcut.Slot.settingsWindow.modifiersKey
        )
    }

    // MARK: - 저장과 복원

    func test_savedShortcut_isRestored() {
        let custom = HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_Slash), modifiers: [.command, .option]
        )

        custom.save(.settingsWindow, to: defaults)

        XCTAssertEqual(HotKeyShortcut.load(.settingsWindow, from: defaults), custom,
                       "저장한 설정 단축키가 복원되지 않아 매번 초기화된다")
    }

    /// 손상된 저장값은 기본값으로 되돌린다.
    ///
    /// 설정 단축키가 이렇게 되면 설정 창에 도달할 수단이 하나 줄어드는 셈이라, 기능을 잃는 대신
    /// 알려진 기본값으로 되돌리는 편이 낫다.
    func test_storedShortcutWithoutModifiers_fallsBackToDefault() {
        HotKeyShortcut(keyCode: UInt32(kVK_ANSI_Comma), modifiers: [])
            .save(.settingsWindow, to: defaults)

        XCTAssertEqual(
            HotKeyShortcut.load(.settingsWindow, from: defaults),
            HotKeyShortcut.Slot.settingsWindow.defaultShortcut,
            "손상된 저장값이 기본값으로 되돌려지지 않았다"
        )
    }

    // MARK: - 이벤트 판정

    /// 지정한 조합의 키 이벤트를 설정 열기로 판정한다.
    ///
    /// **판정은 키 코드로 한다.** 문자로 비교하면 입력기가 조합 중일 때
    /// `charactersIgnoringModifiers`가 빈 문자열로 와서 놓친다 — 실측에서 키를 주입했을 때
    /// `chars=`(빈 값)인 keyDown이 반복 도착했다.
    @MainActor
    func test_matches_identifiesTheConfiguredCombination() throws {
        let settings = SettingsHotKeySettings(
            shortcut: HotKeyShortcut(keyCode: UInt32(kVK_ANSI_Comma), modifiers: [.command])
        )

        let matching = try XCTUnwrap(Self.keyEvent(
            keyCode: UInt16(kVK_ANSI_Comma), flags: .command, characters: ","
        ))
        XCTAssertTrue(settings.matches(matching), "지정한 조합을 판정하지 못했다")

        // 입력기가 조합 중이면 문자가 비어서 온다. 키 코드로 판정하므로 여전히 맞아야 한다.
        let noCharacters = try XCTUnwrap(Self.keyEvent(
            keyCode: UInt16(kVK_ANSI_Comma), flags: .command, characters: ""
        ))
        XCTAssertTrue(settings.matches(noCharacters),
                      "문자가 비어 있으면 판정하지 못한다 — 한글 입력 중에 동작하지 않는다")
    }

    /// 수정자가 다르면 판정하지 않는다 — 다른 앱의 단축키일 수 있다.
    @MainActor
    func test_matches_rejectsDifferentModifiers() throws {
        let settings = SettingsHotKeySettings(
            shortcut: HotKeyShortcut(keyCode: UInt32(kVK_ANSI_Comma), modifiers: [.command])
        )

        for flags: NSEvent.ModifierFlags in [[.command, .shift], [.command, .option], [.option]] {
            let event = try XCTUnwrap(Self.keyEvent(
                keyCode: UInt16(kVK_ANSI_Comma), flags: flags, characters: ","
            ))
            XCTAssertFalse(settings.matches(event),
                           "\(flags) 조합을 설정 열기로 오판했다")
        }
    }

    /// 사용자가 조합을 바꾸면 그 조합으로 판정한다.
    @MainActor
    func test_matches_followsTheUpdatedShortcut() throws {
        let settings = SettingsHotKeySettings(
            shortcut: HotKeyShortcut(keyCode: UInt32(kVK_ANSI_Comma), modifiers: [.command])
        )
        let oldCombination = try XCTUnwrap(Self.keyEvent(
            keyCode: UInt16(kVK_ANSI_Comma), flags: .command, characters: ","
        ))

        settings.update(to: HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_P), modifiers: [.command, .option]
        ))

        let newCombination = try XCTUnwrap(Self.keyEvent(
            keyCode: UInt16(kVK_ANSI_P), flags: [.command, .option], characters: "p"
        ))
        XCTAssertTrue(settings.matches(newCombination), "바꾼 조합이 반영되지 않았다")
        XCTAssertFalse(settings.matches(oldCombination),
                       "이전 조합이 여전히 설정을 연다 — 바꾼 의미가 없다")
    }

    // MARK: - 유효성

    /// 수정자 없는 조합은 거부한다. 일반 타이핑을 가로채기 때문이다.
    @MainActor
    func test_update_rejectsShortcutWithoutModifiers() {
        let settings = SettingsHotKeySettings(
            shortcut: HotKeyShortcut(keyCode: UInt32(kVK_ANSI_Comma), modifiers: [.command])
        )
        let before = settings.shortcut

        settings.update(to: HotKeyShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: []))

        XCTAssertEqual(settings.shortcut, before,
                       "수정자 없는 조합이 받아들여져 일반 타이핑을 가로챈다")
        XCTAssertNotNil(settings.validationError,
                        "거부했는데 사유를 알리지 않는다")
    }

    /// 기본값으로 되돌릴 수 있다.
    @MainActor
    func test_resetToDefault_returnsToCommandComma() {
        let settings = SettingsHotKeySettings(
            shortcut: HotKeyShortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: [.command, .option])
        )

        settings.resetToDefault()

        XCTAssertEqual(settings.shortcut, HotKeyShortcut.Slot.settingsWindow.defaultShortcut)
    }

    // MARK: - 헬퍼

    private static func keyEvent(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        characters: String
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    }
}
