import XCTest
@testable import Scribird

/// 버전 비교 테스트.
///
/// 검증 대상 계약: 자리별 숫자로 비교한다 / 릴리즈 태그 표기(`v` 접두사, 프리릴리즈
/// 꼬리표)를 해석한다 / 자리 수가 달라도 같은 버전을 같다고 본다.
///
/// 문자열 비교로 판정하면 새 버전을 구 버전으로 오인해 업데이트를 알리지 못한다.
/// 이 테스트의 핵심 사례가 그 실패다.
final class AppVersionTests: XCTestCase {

    private func version(_ raw: String) throws -> AppVersion {
        try XCTUnwrap(AppVersion(raw), "\(raw)를 버전으로 해석하지 못했다")
    }

    // MARK: - 자리별 비교

    /// 문자열 비교의 반례.
    ///
    /// `"0.10.0" < "0.9.0"`은 문자열로는 참이다 — `1` < `9`이기 때문이다. 그대로 쓰면
    /// 0.9.0 사용자에게 0.10.0 릴리즈를 알리지 못한다.
    func test_minorVersionTenIsNewerThanNine() throws {
        let ten = try version("0.10.0")
        let nine = try version("0.9.0")

        XCTAssertGreaterThan(ten, nine,
                             "문자열 비교로 판정해 0.10.0을 0.9.0보다 낮게 봤다")
    }

    /// 패치 자리에서도 같은 함정이 있다.
    func test_patchVersionTwelveIsNewerThanTwo() throws {
        XCTAssertGreaterThan(try version("1.0.12"), try version("1.0.2"),
                             "패치 자리를 문자열로 비교했다")
    }

    func test_majorVersionDominatesLowerPositions() throws {
        XCTAssertGreaterThan(try version("1.0.0"), try version("0.99.99"))
    }

    func test_sameVersion_isEqual() throws {
        XCTAssertEqual(try version("0.1.0"), try version("0.1.0"))
    }

    // MARK: - 자리 수가 다를 때

    /// 릴리즈 태그가 `0.2`로 붙어도 `0.2.0`과 같은 버전이다.
    func test_missingPositions_areTreatedAsZero() throws {
        XCTAssertEqual(try version("1.2"), try version("1.2.0"))
        XCTAssertEqual(try version("1"), try version("1.0.0"))
    }

    func test_missingPositions_stillCompareCorrectly() throws {
        XCTAssertGreaterThan(try version("1.2.1"), try version("1.2"))
        XCTAssertLessThan(try version("1.2"), try version("1.3"))
    }

    // MARK: - 태그 표기 해석

    /// 릴리즈 태그는 `v0.1.0` 형태다. 접두사를 걷어내지 않으면 해석에 실패해
    /// 업데이트 확인이 항상 실패한다.
    func test_tagWithVPrefix_isParsed() throws {
        XCTAssertEqual(try version("v0.1.0"), try version("0.1.0"),
                       "릴리즈 태그의 v 접두사를 걷어내지 못했다")
    }

    func test_tagWithUppercaseVPrefix_isParsed() throws {
        XCTAssertEqual(try version("V2.0.0"), try version("2.0.0"))
    }

    func test_tagWithSurroundingWhitespace_isParsed() throws {
        XCTAssertEqual(try version(" 0.1.0\n"), try version("0.1.0"))
    }

    /// 프리릴리즈 꼬리표는 자리 비교에서 제외한다.
    func test_prereleaseSuffix_isIgnoredInComparison() throws {
        XCTAssertEqual(try version("0.2.0-beta.1"), try version("0.2.0"))
        XCTAssertGreaterThan(try version("v0.2.0-rc.1"), try version("0.1.0"))
    }

    // MARK: - 해석 실패

    /// 해석할 수 없는 표기는 nil로 돌려 조회를 실패로 다루게 한다. 0으로 눌러 담으면
    /// 모든 릴리즈가 구 버전으로 판정된다.
    func test_nonNumericVersion_isRejected() {
        XCTAssertNil(AppVersion("latest"))
        XCTAssertNil(AppVersion("v"))
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("1.x.0"))
    }

    // MARK: - 표시

    func test_description_dropsTagDecoration() throws {
        XCTAssertEqual(try version("v0.1.0").description, "0.1.0",
                       "사용자에게 보이는 버전에 태그 접두사가 남았다")
    }
}
