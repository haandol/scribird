import Foundation
import XCTest
@testable import Scribird

/// 저장 루트 선택 테스트.
///
/// 검증 대상 계약: 정한 적 없으면 기본 위치다 / 고른 폴더를 쓸 수 있으면 그것을 쓴다 / 쓸 수
/// 없으면 기본 위치로 되돌리되 선택은 보존한다 / 되돌림은 사용자에게 알린다 / 선택은 앱을 다시
/// 켜도 유지된다.
///
/// **되돌림이 이 결정의 급소다.** 외장 볼륨을 뽑아 둔 것을 잊은 사용자가 회의를 시작할 때 세션을
/// 접으면 그 회의를 통째로 잃고, 회의는 재생성 불가능하다. 회의록이 예상한 곳에 없는 것은 위치를
/// 알려주면 회복되는 불편이지만, 녹취되지 않은 것은 되돌릴 수 없다.
final class TranscriptRootLocationTests: XCTestCase {

    private var sandbox: URL!
    private var originalHome: String?
    private var defaults: UserDefaults!
    private let domain = "scribird.root.tests"

    override func setUpWithError() throws {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "scribird-root-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        // 기본 위치가 실제 홈을 오염시키지 않도록 임시 디렉터리로 옮긴다.
        originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", sandbox.path, 1)

        defaults = UserDefaults(suiteName: domain)
        defaults.removePersistentDomain(forName: domain)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: domain)
        defaults = nil
        if let originalHome { setenv("HOME", originalHome, 1) }
        try? FileManager.default.removeItem(at: sandbox)
    }

    /// 실제로 쓸 수 있는 폴더를 만들어 돌려준다.
    private func makeUsableDirectory(_ name: String) throws -> URL {
        let url = sandbox.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - 기본값

    /// 아무것도 고르지 않으면 기본 위치를 쓴다.
    ///
    /// 이것이 이 기능의 안전한 기본값이다 — 설정을 만지지 않은 사용자의 동작은 바뀌지 않는다.
    func test_withNoChoice_usesStandardDirectory() throws {
        let resolution = TranscriptRootLocation.resolve(defaults: defaults)

        XCTAssertEqual(resolution, .standard(try TranscriptRootLocation.standardDirectory()))
        XCTAssertFalse(try XCTUnwrap(resolution).usesChosenDirectory)
        XCTAssertNil(TranscriptRootLocation.warning(for: try XCTUnwrap(resolution)),
                     "기본 위치를 쓰는 것은 경고할 일이 아니다")
    }

    /// 기본 위치는 앱 전용 폴더를 가리킨다 — 문서 폴더 최상위에 흩뿌리지 않는다.
    func test_standardDirectory_isUnderAppFolder() throws {
        let standard = try TranscriptRootLocation.standardDirectory()
        XCTAssertEqual(standard.lastPathComponent, "Scribird")
        XCTAssertTrue(standard.path.contains("Documents"))
    }

    // MARK: - 고른 폴더

    func test_withUsableChoice_usesChosenDirectory() throws {
        let chosen = try makeUsableDirectory("내회의록")
        RecordingPreferences.save(transcriptRoot: chosen, to: defaults)

        let resolution = try XCTUnwrap(TranscriptRootLocation.resolve(defaults: defaults))

        // 경로로 비교한다 — 저장은 경로 문자열이라 되읽은 URL의 끝 슬래시 여부가 다를 수 있다.
        XCTAssertEqual(resolution.directory.path(percentEncoded: false),
                       chosen.path(percentEncoded: false))
        XCTAssertTrue(resolution.usesChosenDirectory)
        XCTAssertNil(TranscriptRootLocation.warning(for: resolution))
    }

    /// 선택은 앱을 다시 켜도 유지된다 — 저장소를 새로 읽어도 같은 결과가 나온다.
    func test_choice_survivesRelaunch() throws {
        let chosen = try makeUsableDirectory("유지되는폴더")
        RecordingPreferences.save(transcriptRoot: chosen, to: defaults)

        // 같은 도메인을 새 인스턴스로 읽는다 — 앱을 다시 켠 것과 같다.
        let reopened = try XCTUnwrap(UserDefaults(suiteName: domain))
        XCTAssertEqual(
            RecordingPreferences.transcriptRoot(from: reopened)?.path(percentEncoded: false),
            chosen.path(percentEncoded: false)
        )
    }

    func test_clearingChoice_returnsToStandard() throws {
        let chosen = try makeUsableDirectory("잠깐쓴폴더")
        RecordingPreferences.save(transcriptRoot: chosen, to: defaults)
        RecordingPreferences.save(transcriptRoot: nil, to: defaults)

        XCTAssertNil(RecordingPreferences.transcriptRoot(from: defaults))
        XCTAssertEqual(
            TranscriptRootLocation.resolve(defaults: defaults),
            .standard(try TranscriptRootLocation.standardDirectory())
        )
    }

    // MARK: - 되돌림 (고른 폴더를 쓸 수 없을 때)

    /// **고른 폴더가 사라졌으면 기본 위치로 되돌린다.** 접지 않는다.
    ///
    /// 외장 볼륨을 뽑아 둔 상태가 이 경우다. 경로 문자열은 그대로 남아 있으므로, 존재를 확인하지
    /// 않으면 없는 폴더에 세션을 열려 하고 그 실패가 녹취를 잃는 결과로 이어진다.
    func test_missingChosenDirectory_fallsBackToStandard() throws {
        // 볼륨 자체가 없는 경로를 쓴다. 임시 폴더 아래의 없는 하위는 부모가 살아 있어 만들어지므로
        // (실측: 중간 경로 생성이 성공한다) 분리된 볼륨을 흉내내지 못한다.
        let unreachable = URL(filePath: "/없는볼륨/회의록", directoryHint: .isDirectory)
        RecordingPreferences.save(transcriptRoot: unreachable, to: defaults)

        let resolution = try XCTUnwrap(TranscriptRootLocation.resolve(defaults: defaults))
        let standard = try TranscriptRootLocation.standardDirectory()

        XCTAssertEqual(resolution.directory, standard,
                       "쓸 수 없는 폴더로 세션을 열면 그 회의를 잃는다")
        XCTAssertFalse(resolution.usesChosenDirectory)
        XCTAssertFalse(TranscriptRootLocation.isUsable(unreachable))
    }

    /// **되돌려도 선택은 지우지 않는다.**
    ///
    /// 볼륨을 다시 연결하면 그 선택으로 돌아가야 한다. 되돌림을 이유로 선택을 지우면 사용자가
    /// 정한 것을 앱이 조용히 버리는 것이 된다 — 캡처 장치 고정이 장치 부재를 다루는 방식과 같다.
    func test_fallback_preservesTheUserChoice() throws {
        let chosen = URL(filePath: "/없는볼륨/회의록", directoryHint: .isDirectory)
        RecordingPreferences.save(transcriptRoot: chosen, to: defaults)

        _ = TranscriptRootLocation.resolve(defaults: defaults)

        // 경로로 비교한다 — 저장은 경로 문자열이므로 되읽은 URL의 끝 슬래시 여부가 다를 수 있다.
        XCTAssertEqual(
            RecordingPreferences.transcriptRoot(from: defaults)?.path(percentEncoded: false),
            chosen.path(percentEncoded: false),
            "되돌림이 선택을 지우면 볼륨을 다시 연결해도 그 폴더로 돌아가지 않는다"
        )
    }

    /// 볼륨이 다시 연결되면 고른 폴더로 돌아간다.
    func test_choiceBecomingUsableAgain_isHonored() throws {
        let chosen = sandbox.appending(path: "돌아온볼륨", directoryHint: .isDirectory)
        RecordingPreferences.save(transcriptRoot: chosen, to: defaults)

        // 지금은 없다 — 다만 부모가 있으므로 만들 수 있어, 되돌림 대상이 아니다.
        // 실제 부재 상태를 만들려면 만들 수 없는 경로여야 한다.
        let unreachable = URL(filePath: "/없는볼륨/회의록")
        RecordingPreferences.save(transcriptRoot: unreachable, to: defaults)
        XCTAssertFalse(try XCTUnwrap(TranscriptRootLocation.resolve(defaults: defaults))
            .usesChosenDirectory)

        // 다시 연결된 상태 — 쓸 수 있는 폴더로 바뀌었다.
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        RecordingPreferences.save(transcriptRoot: chosen, to: defaults)
        XCTAssertTrue(try XCTUnwrap(TranscriptRootLocation.resolve(defaults: defaults))
            .usesChosenDirectory)
    }

    /// **되돌린 것을 사용자에게 알려야 한다.**
    ///
    /// 알리지 않으면 사용자는 자기가 고른 폴더를 계속 보며 회의록이 사라졌다고 판단한다. 암호화
    /// 볼륨을 고른 경우에는 민감한 회의록이 기본 위치에 남은 것을 모른 채 회의를 마친다.
    func test_fallback_warnsWithBothLocations() throws {
        RecordingPreferences.save(transcriptRoot: URL(filePath: "/없는볼륨/비밀회의"), to: defaults)

        let resolution = try XCTUnwrap(TranscriptRootLocation.resolve(defaults: defaults))
        let warning = try XCTUnwrap(
            TranscriptRootLocation.warning(for: resolution),
            "되돌림을 알리지 않으면 사용자는 고른 폴더에 저장되고 있다고 믿는다"
        )

        XCTAssertTrue(warning.contains("비밀회의"), "어느 폴더를 쓸 수 없었는지가 없다")
        XCTAssertTrue(warning.contains("Scribird"), "어디에 기록되는지가 없다")
    }

    // MARK: - 쓸 수 있는지 판정

    /// 파일을 고른 경우는 저장 루트로 쓸 수 없다.
    func test_isUsable_rejectsAFile() throws {
        let file = sandbox.appending(path: "회의록.txt")
        try "내용".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertFalse(TranscriptRootLocation.isUsable(file),
                       "파일을 저장 루트로 받아들이면 세션 디렉터리를 만들 수 없다")
    }

    /// 없는 폴더라도 만들 수 있으면 쓸 수 있다.
    ///
    /// 사용자가 고른 시점에는 있었지만 그 뒤 지워진 경우가 이에 해당한다 — 부모가 살아 있으면
    /// 다시 만들어 진행하는 편이 되돌리는 것보다 사용자의 의도에 가깝다.
    func test_isUsable_createsMissingDirectoryWhenParentExists() throws {
        let notYet = sandbox.appending(path: "새로만들폴더", directoryHint: .isDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: notYet.path))

        XCTAssertTrue(TranscriptRootLocation.isUsable(notYet))
        XCTAssertTrue(FileManager.default.fileExists(atPath: notYet.path))
    }

    /// 쓸 수 없는 곳은 거부한다 — 시스템 폴더가 대표적이다.
    func test_isUsable_rejectsUnwritableLocation() {
        XCTAssertFalse(TranscriptRootLocation.isUsable(URL(filePath: "/없는볼륨/회의록")))
        XCTAssertFalse(TranscriptRootLocation.isUsable(URL(filePath: "/usr/scribird-회의록")))
    }
}
