import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Scribird

/// 전역 단축키 조합 테스트.
///
/// 검증 대상 계약: 기본값은 ⌥⌘S다 / 수정자 없는 조합은 거부한다 / 사용자가 정한
/// 조합은 앱을 다시 켜도 유지된다 / 손상된 저장값은 기본값으로 되돌린다.
///
/// 실제 단축키 등록은 Carbon 이벤트 타깃을 요구하므로 여기서 검증하지 않는다.
/// 등록 성공·충돌은 수동 스모크 테스트의 몫이다.
final class HotKeyShortcutTests: XCTestCase {

    /// 실제 사용자 설정을 오염시키지 않으려고 전용 도메인을 쓴다.
    private var defaults: UserDefaults!
    private let domain = "scribird.hotkey.tests"

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

    /// 사용자가 아무것도 설정하지 않아도 단축키가 바로 동작해야 한다.
    func test_default_isOptionCommandS() {
        XCTAssertEqual(HotKeyShortcut.default.keyCode, UInt32(kVK_ANSI_S))
        XCTAssertEqual(HotKeyShortcut.default.modifiers, [.option, .command])
    }

    /// 표시 이름은 활성 입력 소스가 아니라 물리 키 자리를 보여줘야 한다.
    ///
    /// 등록되는 것은 키 코드(자리)이므로 표시도 그 자리의 이름이어야 한다. 활성 입력
    /// 소스로 읽으면 어긋난다 — 한글 입력 중에 실측한 결과 `⌥⌘S`가 `⌥⌘ㄴ`으로,
    /// `⌘T`가 `⌘ㅅ`으로 표시됐다.
    ///
    /// 이 테스트는 현재 입력 소스가 ASCII일 때는 파괴된 코드에서도 통과한다 —
    /// 한글 입력 소스를 켠 상태로 한 번 확인해야 판별력이 있다.
    func test_displayName_usesPhysicalKeyNotCurrentInputSource() {
        XCTAssertEqual(HotKeyShortcut.default.displayName, "⌥⌘S",
                       "활성 입력 소스로 키 이름을 읽어 한글 입력 중에 어긋난다")
    }

    func test_load_withNothingStored_returnsDefault() {
        XCTAssertEqual(HotKeyShortcut.load(from: defaults), .default,
                       "저장값이 없을 때 기본값이 적용되지 않았다")
    }

    // MARK: - 유효성

    /// 수정자가 없는 조합은 일반 타이핑을 가로챈다.
    func test_shortcutWithoutModifiers_isRejected() {
        let bare = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: [])

        XCTAssertFalse(bare.isValid, "수정자 없는 조합이 허용되면 타이핑이 가로채인다")
    }

    /// Shift만으로는 부족하다 — ⇧S는 대문자 S 입력이다.
    func test_shiftOnlyShortcut_isRejected() {
        let shiftOnly = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: [.shift])

        XCTAssertFalse(shiftOnly.isValid, "Shift만 있는 조합이 허용되면 대문자 입력을 막는다")
    }

    func test_commandOptionControl_areEachSufficient() {
        for modifier in [NSEvent.ModifierFlags.command, .option, .control] {
            let shortcut = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: modifier)
            XCTAssertTrue(shortcut.isValid, "\(modifier)를 포함한 조합이 거부됐다")
        }
    }

    // MARK: - 저장과 복원

    /// 사용자가 정한 조합은 앱을 다시 켜도 유지돼야 한다.
    func test_savedShortcut_isRestored() {
        let custom = HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_T),
            modifiers: [.control, .shift, .command]
        )

        custom.save(to: defaults)

        XCTAssertEqual(HotKeyShortcut.load(from: defaults), custom,
                       "저장한 단축키가 복원되지 않아 설정이 매번 초기화된다")
    }

    /// 저장값이 손상되면 기능을 잃는 대신 기본값으로 되돌린다.
    ///
    /// 수정자 비트가 0으로 남은 값을 그대로 등록하면 일반 키가 가로채이거나
    /// 등록이 실패해 단축키가 아예 동작하지 않는다.
    func test_storedShortcutWithoutModifiers_fallsBackToDefault() {
        HotKeyShortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: []).save(to: defaults)

        XCTAssertEqual(HotKeyShortcut.load(from: defaults), .default,
                       "손상된 저장값이 기본값으로 되돌려지지 않았다")
    }

    // MARK: - 표시 문자열

    /// 수정자 표기 순서는 macOS 관례를 따른다 — ⌃⌥⇧⌘.
    ///
    /// 키는 `Space`로 고른다. 문자 키의 이름은 키보드 레이아웃에서 오므로, 이 테스트가
    /// 활성 입력 소스에 따라 결과가 바뀌면(한글 입력 중 `T` → `ㅅ`) 순서 검증이
    /// 아니라 환경 검사가 된다.
    func test_displayName_ordersModifiersLikeMacOS() {
        let all = HotKeyShortcut(
            keyCode: UInt32(kVK_Space),
            modifiers: [.command, .shift, .option, .control]
        )

        XCTAssertEqual(all.displayName, "⌃⌥⇧⌘Space",
                       "수정자 표기 순서가 macOS 관례와 다르다")
    }

    func test_displayName_namesKeysWithoutCharacters() {
        let space = HotKeyShortcut(keyCode: UInt32(kVK_Space), modifiers: [.command, .shift])

        XCTAssertEqual(space.displayName, "⇧⌘Space",
                       "문자를 내지 않는 키의 이름이 표시되지 않았다")
    }

    // MARK: - Carbon 변환

    /// Carbon은 자체 수정자 비트를 요구한다. 매핑이 틀리면 다른 조합이 등록된다.
    func test_carbonModifiers_mapEachFlag() {
        XCTAssertEqual(
            HotKeyShortcut(keyCode: 0, modifiers: [.command]).carbonModifiers,
            UInt32(cmdKey)
        )
        XCTAssertEqual(
            HotKeyShortcut(keyCode: 0, modifiers: [.option]).carbonModifiers,
            UInt32(optionKey)
        )
        XCTAssertEqual(
            HotKeyShortcut(keyCode: 0, modifiers: [.shift]).carbonModifiers,
            UInt32(shiftKey)
        )
        XCTAssertEqual(
            HotKeyShortcut(keyCode: 0, modifiers: [.control]).carbonModifiers,
            UInt32(controlKey)
        )
    }

    func test_carbonModifiers_combineFlags() {
        let combined = HotKeyShortcut.default.carbonModifiers

        XCTAssertEqual(combined, UInt32(optionKey) | UInt32(cmdKey),
                       "기본 단축키의 Carbon 수정자 비트가 ⌥⌘와 다르다")
    }

    func test_carbonModifiers_withNoFlags_isZero() {
        XCTAssertEqual(HotKeyShortcut(keyCode: 0, modifiers: []).carbonModifiers, 0)
    }
}
