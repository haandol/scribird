import Foundation
import XCTest
@testable import Scribird

/// 산출물 위치 노출과 종료 시 자동 열기 규칙 테스트.
///
/// 검증 대상 계약: 자동 열기 기본값은 켬이다 / 끄면 열지 않는다 / 세션 경계에서는 열지
/// 않는다 / 여는 대상은 방금 마무리된 세션이다 / 폴더 열기 실패가 종료를 실패로 만들지
/// 않는다 / 녹취 중에는 현재 세션을, 끝난 뒤에는 직전 세션을 표시한다.
///
/// 이 기능이 존재하는 이유는 앱이 메뉴바와 좁은 창으로만 쓰여 산출물 위치를 볼 다른 화면이
/// 없었다는 것이다. 사용자가 녹취가 실제로 저장되는지 확인할 수단이 없었고, 회의는 한 번
/// 일어나고 끝나므로 그 사실을 회의 후에 알아도 되돌릴 수 없다.
///
/// 실제 캡처 없이 검증하기 위해 열기 창구를 갈아 끼운다 — 테스트가 Finder 창을 띄우면
/// 안 되고, `swift test`에는 오디오 하드웨어도 없다.
@MainActor
final class SessionFolderOpeningTests: XCTestCase {

    private var defaults: UserDefaults!
    private let domain = "scribird.folder.tests"

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

    /// 열기 요청을 기록하는 대역. 실제 파일 탐색기를 띄우지 않는다.
    ///
    /// 열기 창구가 메인 액터에 격리돼 있으므로 대역도 같은 격리를 쓴다 — 소스의 격리를
    /// 약하게 만드는 대신 테스트를 맞춘다.
    @MainActor
    private final class OpenLog {
        private(set) var opened: [URL] = []
        var succeeds = true

        func opener() -> SessionFolderOpener {
            SessionFolderOpener { [self] url in
                opened.append(url)
                return succeeds
            }
        }
    }

    // MARK: - 무엇을 여는가

    /// 자동 열기가 켜져 있으면 방금 마무리된 세션의 폴더를 연다.
    ///
    /// 세션 디렉터리가 아니라 상위 폴더를 열면 회의가 쌓인 목록만 보여 방금 끝난 회의를
    /// 사용자가 다시 찾아야 한다 — 그것이 이 기능이 없애려던 상황이다.
    func test_whenEnabled_opensTheSessionThatJustFinished() {
        let log = OpenLog()
        let finished = URL(filePath: "/tmp/Scribird/2026-08-04_120000", directoryHint: .isDirectory)

        SessionFolderPolicy.openIfNeeded(
            finished: finished,
            isEnabled: true,
            using: log.opener()
        )

        XCTAssertEqual(log.opened, [finished],
                       "종료 시 방금 마무리된 세션 폴더가 열리지 않았다")
    }

    /// 끈 사용자에게는 열지 않는다. 연속 회의를 녹취하는 경우 방해가 된다.
    func test_whenDisabled_opensNothing() {
        let log = OpenLog()

        SessionFolderPolicy.openIfNeeded(
            finished: URL(filePath: "/tmp/Scribird/2026-08-04_120000", directoryHint: .isDirectory),
            isEnabled: false,
            using: log.opener()
        )

        XCTAssertTrue(log.opened.isEmpty,
                      "자동 열기를 껐는데도 폴더가 열려 회의마다 창이 끼어든다")
    }

    /// 마무리된 세션이 없으면 열 것이 없다.
    ///
    /// 산출물을 만들지 못한 채 끝난 세션에서 아무 폴더나 열면, 저장되지 않았다는 사실을
    /// 저장된 것처럼 보이게 한다.
    func test_withNoFinishedSession_opensNothing() {
        let log = OpenLog()

        SessionFolderPolicy.openIfNeeded(finished: nil, isEnabled: true, using: log.opener())

        XCTAssertTrue(log.opened.isEmpty,
                      "마무리된 세션이 없는데도 폴더를 열어 저장된 것처럼 보인다")
    }

    /// **폴더를 열지 못해도 종료는 성공이다.**
    ///
    /// 산출물은 이미 디스크에 있고 여는 것은 편의 기능이다. 실패를 전파하면 저장된 회의록을
    /// 잃은 것처럼 보인다.
    func test_whenOpeningFails_doesNotPropagateTheFailure() {
        let log = OpenLog()
        log.succeeds = false
        let finished = URL(filePath: "/tmp/Scribird/2026-08-04_120000", directoryHint: .isDirectory)

        // 던지지 않고 반환값도 요구하지 않는다는 것이 계약이다.
        SessionFolderPolicy.openIfNeeded(finished: finished, isEnabled: true, using: log.opener())

        XCTAssertEqual(log.opened, [finished], "열기를 시도조차 하지 않았다")
    }

    // MARK: - 세션 경계

    /// **세션 경계에서는 열지 않는다.**
    ///
    /// 경계를 끊는 것은 회의를 계속하겠다는 뜻이라 산출물을 확인할 시점이 아니고, 경계를
    /// 여러 번 끊으면 그만큼 창이 열려 회의 화면을 가린다. 회의 중에 화면을 빼앗는 것은
    /// 이 앱이 하지 않아야 할 일이다.
    func test_atSessionBoundary_opensNothingEvenWhenEnabled() {
        let log = OpenLog()
        let rotated = URL(filePath: "/tmp/Scribird/2026-08-04_120000", directoryHint: .isDirectory)

        SessionFolderPolicy.openAtBoundary(
            finished: rotated,
            isEnabled: true,
            using: log.opener()
        )

        XCTAssertTrue(log.opened.isEmpty,
                      "세션 경계에서 폴더가 열렸다 — 경계를 여러 번 끊으면 회의 중 창이 반복적으로 끼어든다")
    }

    /// 경계를 세 번 끊어도 한 번도 열리지 않는다.
    ///
    /// 한 번의 호출만 확인하면 "경계마다 열린다"는 구현도 통과할 수 있다.
    func test_repeatedBoundaries_neverOpen() {
        let log = OpenLog()

        for index in 0..<3 {
            SessionFolderPolicy.openAtBoundary(
                finished: URL(
                    filePath: "/tmp/Scribird/session-\(index)",
                    directoryHint: .isDirectory
                ),
                isEnabled: true,
                using: log.opener()
            )
        }

        XCTAssertTrue(log.opened.isEmpty,
                      "경계를 반복해 끊자 창이 그만큼 열렸다. 열린 것: \(log.opened.map(\.lastPathComponent))")
    }

    // MARK: - 표시할 위치

    private var root: URL {
        URL(filePath: "/tmp/Scribird", directoryHint: .isDirectory)
    }

    /// 녹취 중에는 **지금 쌓이는 세션**을 표시한다.
    ///
    /// 확인이 필요한 시점은 회의 중이고, 그때 직전 회의의 폴더를 보여주면 확인하려던 것과
    /// 다른 것을 알려준다.
    func test_whileRecording_displaysTheCurrentSession() {
        let current = URL(filePath: "/tmp/Scribird/now", directoryHint: .isDirectory)
        let previous = URL(filePath: "/tmp/Scribird/before", directoryHint: .isDirectory)

        let shown = SessionFolderPolicy.displayed(current: current, last: previous, root: root)

        XCTAssertEqual(shown.directory, current,
                       "녹취 중에 직전 회의 폴더를 표시했다 — 지금 저장되는 곳을 확인할 수 없다")
    }

    /// 녹취가 끝난 뒤에는 직전 세션을 표시한다. 방금 끝낸 회의에 도달할 수 있어야 한다.
    func test_afterStopping_displaysTheLastSession() {
        let previous = URL(filePath: "/tmp/Scribird/before", directoryHint: .isDirectory)

        let shown = SessionFolderPolicy.displayed(current: nil, last: previous, root: root)

        XCTAssertEqual(shown.directory, previous,
                       "녹취가 끝난 뒤 직전 회의 폴더가 표시되지 않았다")
    }

    /// **한 번도 녹취하지 않았어도 표시는 있다.**
    ///
    /// 조건부로 나타나는 버튼은 사용자가 그 존재를 학습하지 못하게 만들고, 산출물이 어디에
    /// 저장될지는 첫 녹취를 시작하기 전에도 알고 싶은 것이다. 가리킬 세션이 없으면 세션들이
    /// 모이는 루트를 가리킨다.
    func test_beforeAnyRecording_stillDisplaysTheRoot() {
        let shown = SessionFolderPolicy.displayed(current: nil, last: nil, root: root)

        XCTAssertEqual(shown.directory, root,
                       "녹취한 적이 없을 때 표시가 사라졌다 — 사용자가 이 수단의 존재를 배우지 못한다")
    }

    /// 세 상태를 라벨로 구분한다.
    ///
    /// 같은 문구면 방금 끝난 회의와 지금 쌓이는 회의가 헷갈리고, 아직 비어 있는 루트를
    /// 회의록이 있는 폴더로 오인한다.
    func test_theThreeStates_areLabelledDistinctly() {
        let labels = [
            SessionFolderPolicy.displayed(
                current: URL(filePath: "/tmp/a", directoryHint: .isDirectory),
                last: nil,
                root: root
            ).label,
            SessionFolderPolicy.displayed(
                current: nil,
                last: URL(filePath: "/tmp/b", directoryHint: .isDirectory),
                root: root
            ).label,
            SessionFolderPolicy.displayed(current: nil, last: nil, root: root).label,
        ]

        XCTAssertEqual(Set(labels).count, 3,
                       "세 상태가 서로 구분되지 않는다: \(labels)")
    }
}
