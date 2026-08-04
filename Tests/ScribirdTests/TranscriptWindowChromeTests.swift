import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Scribird

/// 전사 창의 닫기 단축키와 앞자리 양보 테스트.
///
/// 검증 대상 계약: `⌘W`로 창이 닫힌다 / 수정자가 정확히 `⌘`일 때만 닫는다 / 문자가 아니라 키
/// 코드로 판정한다 / 앱이 폴더를 열 때 창이 앞자리를 넘긴다.
///
/// **앞자리 양보는 관측된 증상에서 나왔다.** 녹취를 끝내면 산출물 폴더를 열어 주는데 전사 창이
/// 그 위를 덮어, 폴더를 열어 준 목적이 사라졌다. 실측한 화면 순서:
///
/// ```
/// 창 레벨 유지  → [0] 전사 창(L3) / [1] Finder(L0)   ← 가려진다
/// 레벨을 일반으로 → [0] Finder(L0) / [1] 전사 창(L0)   ← 폴더가 앞에 온다
/// ```
///
/// Finder를 활성화하는 것만으로는 부족하다 — 활성화는 되지만 레벨이 높으면 그대로 가려진다.
@MainActor
final class TranscriptWindowChromeTests: XCTestCase {

    // MARK: - 닫기 단축키

    func test_commandW_isRecognizedAsClose() {
        XCTAssertTrue(
            WindowCloseShortcut.matches(keyCode: UInt16(kVK_ANSI_W), modifiers: .command),
            "⌘W가 닫기로 인식되지 않아 사용자가 아는 조작으로 창을 치울 수 없다"
        )
    }

    /// 수정자 없는 `W`는 그냥 타이핑이다. 가로채면 입력을 삼킨다.
    func test_plainW_isNotClose() {
        XCTAssertFalse(
            WindowCloseShortcut.matches(keyCode: UInt16(kVK_ANSI_W), modifiers: []),
            "수정자 없는 W를 닫기로 봤다 — 일반 타이핑을 가로챈다"
        )
    }

    /// 다른 수정자가 섞인 조합은 다른 앱에서 다른 뜻을 가진다. 넉넉하게 받으면 의도하지 않은
    /// 닫기가 일어난다.
    func test_otherModifierCombinations_areNotClose() {
        let combinations: [(String, NSEvent.ModifierFlags)] = [
            ("⇧⌘W", [.command, .shift]),
            ("⌥⌘W", [.command, .option]),
            ("⌃⌘W", [.command, .control]),
            ("⌥W", [.option]),
        ]

        for (name, modifiers) in combinations {
            XCTAssertFalse(
                WindowCloseShortcut.matches(keyCode: UInt16(kVK_ANSI_W), modifiers: modifiers),
                "\(name)를 닫기로 봤다 — 사용자가 의도하지 않은 닫기가 일어난다"
            )
        }
    }

    /// 다른 키에 `⌘`가 붙은 것은 닫기가 아니다.
    func test_otherKeysWithCommand_areNotClose() {
        for keyCode in [kVK_ANSI_Q, kVK_ANSI_S, kVK_ANSI_Comma, kVK_ANSI_A] {
            XCTAssertFalse(
                WindowCloseShortcut.matches(keyCode: UInt16(keyCode), modifiers: .command),
                "키코드 \(keyCode)를 닫기로 봤다"
            )
        }
    }

    /// **판정은 키 코드 기준이다.**
    ///
    /// 한글 입력기가 켜져 있으면 `charactersIgnoringModifiers`가 비어 도착한다(이 앱의 다른
    /// 단축키에서 실측된 동작). 문자로 비교하면 조합 중에 조용히 멈춘다. 키 코드는 입력기와
    /// 무관하므로, 문자 정보가 전혀 없어도 판정이 성립한다.
    func test_matching_dependsOnKeyCodeNotCharacters() {
        // 문자를 넘기는 인자가 애초에 없다는 것이 이 계약의 구현이다.
        // 같은 키 코드는 어떤 입력 소스에서도 같은 결과를 낸다.
        XCTAssertTrue(
            WindowCloseShortcut.matches(keyCode: UInt16(kVK_ANSI_W), modifiers: .command),
            "키 코드만으로 판정되지 않는다 — 한글 입력 중에 단축키가 멈춘다"
        )
    }

    // MARK: - 앞자리 양보

    /// 폴더를 여는 동작이 창의 앞자리 양보를 함께 일으킨다.
    ///
    /// 조정자는 "폴더를 연다"만 알고 어떤 창이 비켜야 하는지는 모른다. 그 연결이 끊기면 증상이
    /// 그대로 돌아오므로, 열기와 양보가 한 동작인지 확인한다.
    /// 기록용 상자. 양보와 열기가 실제로 어떤 순서로 일어났는지 남긴다.
    private final class Trace {
        var events: [String] = []
        var openedURLs: [URL] = []
    }

    private func tracingOpener(_ trace: Trace) -> SessionFolderOpener {
        SessionFolderOpener { url in
            trace.events.append("open")
            trace.openedURLs.append(url)
            return true
        }
    }

    func test_openingFolder_alsoYieldsTheFront() {
        let trace = Trace()
        let opener = SessionFolderOpener.yieldingFront(
            to: tracingOpener(trace),
            yield: { trace.events.append("yield") }
        )

        let directory = URL(filePath: "/tmp/Scribird/session", directoryHint: .isDirectory)
        XCTAssertTrue(opener.open(directory))

        XCTAssertTrue(trace.events.contains("yield"),
                      "폴더를 열 때 창이 앞자리를 넘기지 않았다 — 열어 준 폴더가 전사 창에 덮인다")
        XCTAssertEqual(trace.openedURLs, [directory], "양보만 하고 폴더를 열지 않았다")
    }

    /// 양보가 **열기보다 먼저** 일어나야 한다.
    ///
    /// 나중에 낮추면 폴더가 이미 창 뒤에 떠 버린 뒤라 한 번 가려진 화면을 사용자가 본다.
    func test_yielding_happensBeforeOpening() {
        let trace = Trace()
        let opener = SessionFolderOpener.yieldingFront(
            to: tracingOpener(trace),
            yield: { trace.events.append("yield") }
        )

        _ = opener.open(URL(filePath: "/tmp/x", directoryHint: .isDirectory))

        XCTAssertEqual(trace.events, ["yield", "open"],
                       "열기가 양보보다 먼저다 — 폴더가 창 뒤에 뜬 뒤 낮춰진다")
    }
}
