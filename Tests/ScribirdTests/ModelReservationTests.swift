import Foundation
import XCTest
@testable import Scribird

/// 언어 모델 예약 테스트.
///
/// 검증 대상 계약: 예약 실패의 실제 원인을 보존한다 / 이미 예약된 로케일을 실패로 보지 않는다 /
/// 실패하면 이번 세션이 쓰지 않는 예약을 회수해 재시도한다 / 회수는 이번 세션이 쓰는 예약을
/// 건드리지 않는다 / 해제 대상은 실제로 잡힌 것만이다.
///
/// 이 테스트가 존재하는 이유는 실측된 오진이다. 예약이 **0개**인 기기에서 앱이
/// "ko_KR 언어 모델을 확보하지 못했습니다. 예약 가능한 로케일 수(5개)를 초과했습니다"를
/// 띄웠다. 원인을 버리고 예약 목록에 없다는 사실만으로 한도 초과라고 단정한 결과다.
///
/// 실측값을 그대로 쓴다:
/// - 한도 초과의 실제 에러는 `SFSpeechErrorDomain` 코드 11,
///   "Too many allocated locales, 5 maximum."
/// - 한도는 5이고 **앱 단위**로 계산된다 (한 앱이 5개를 채운 상태에서 다른 앱이 추가 예약 성공).
/// - 이 앱이 한 번에 쓰는 로케일은 최대 2개(`ko_KR` + `en_US`)이므로 단독으로는 한도에
///   닿을 수 없다 — 잔여 예약이 자리를 채운 경우에만 닿는다.
/// - 예약은 프로세스 수명을 넘어 남는다 (한 실행이 예약한 로케일이 종료 후 별개 실행에서 조회됨).
final class ModelReservationTests: XCTestCase {

    private let korean = Locale(identifier: "ko_KR")
    private let english = Locale(identifier: "en_US")

    /// 실측된 한도 초과 에러를 그대로 재현한다. 이 문구·도메인·코드가 사용자에게 보존돼야
    /// 하는 원인이다.
    private static func limitError() -> NSError {
        NSError(
            domain: "SFSpeechErrorDomain",
            code: 11,
            userInfo: [NSLocalizedDescriptionKey: "Too many allocated locales, 5 maximum."]
        )
    }

    // MARK: - 정상 경로

    /// 빈 상태에서 두 로케일을 예약하면 둘 다 잡힌다.
    func test_withRoomAvailable_reservesEveryLocale() async {
        let inventory = StubLocaleInventory(limit: 5)

        let outcome = await SpeechModelInstaller.reserve(
            locales: [korean, english],
            using: inventory
        )

        XCTAssertTrue(outcome.isComplete, "자리가 남아 있는데도 예약에 실패했다")
        XCTAssertEqual(Set(outcome.reserved.map(\.identifier)), ["ko_KR", "en_US"])
        XCTAssertTrue(outcome.unreserved.isEmpty)
    }

    /// **이미 예약된 로케일은 실패가 아니다.**
    ///
    /// 시스템의 `reserve`는 집합 의미라 이미 예약된 로케일에 `false`를 반환한다(실측).
    /// 반환값을 실패로 읽으면 두 번째 녹취부터 항상 에러가 난다.
    func test_withLocaleAlreadyReserved_doesNotTreatFalseAsFailure() async {
        let inventory = StubLocaleInventory(limit: 5, preReserved: [korean, english])

        let outcome = await SpeechModelInstaller.reserve(
            locales: [korean, english],
            using: inventory
        )

        XCTAssertTrue(outcome.isComplete,
                      "이미 예약된 로케일을 실패로 판정했다 — 두 번째 녹취부터 항상 실패한다")
        XCTAssertEqual(Set(outcome.reserved.map(\.identifier)), ["ko_KR", "en_US"])
    }

    /// 첫 시도에 다 잡혔으면 **아무것도 회수하지 않는다.**
    ///
    /// 회수는 자리가 없을 때의 복구 수단이다. 성공했는데도 회수가 돌면 건드릴 이유가 없는
    /// 예약을 해제한다. 이 테스트가 판별하는 것은 실패 판정의 근거다 — 시스템의 `reserve`가
    /// 이미 예약된 로케일에 `false`를 반환하므로(실측), 반환값을 실패로 읽으면 모든 것이
    /// 정상인 두 번째 녹취에서도 회수와 재시도가 돌아간다.
    func test_whenFirstAttemptSucceeds_reclaimsNothing() async {
        let unrelated = Locale(identifier: "ja_JP")
        let inventory = StubLocaleInventory(
            limit: 5,
            preReserved: [korean, english, unrelated]
        )

        let outcome = await SpeechModelInstaller.reserve(
            locales: [korean, english],
            using: inventory
        )

        XCTAssertTrue(outcome.isComplete)
        let released = await inventory.released
        XCTAssertTrue(released.isEmpty,
                      "성공했는데도 회수가 돌았다 — 반환값을 실패로 읽고 있다. 해제된 것: \(released.map(\.identifier))")
        let reserved = Set(await inventory.reservedLocales().map(\.identifier))
        XCTAssertTrue(reserved.contains("ja_JP"),
                      "건드릴 이유가 없는 예약을 해제했다")
    }

    /// 던졌지만 실제로는 잡혀 있는 로케일은 실패가 아니다.
    ///
    /// 판정 근거는 예약 목록이지 반환값·예외가 아니다. 목록으로 걸러내지 않으면 정상 상태가
    /// 실패로 보여 불필요한 회수와 재시도가 돌아간다.
    func test_whenReserveThrowsButLocaleIsHeld_treatsItAsSuccess() async {
        let unrelated = Locale(identifier: "ja_JP")
        let inventory = StubLocaleInventory(
            limit: 5,
            preReserved: [korean, unrelated],
            limitError: Self.limitError(),
            throwsAlways: true
        )

        let outcome = await SpeechModelInstaller.reserve(
            locales: [korean],
            using: inventory
        )

        XCTAssertTrue(outcome.isComplete,
                      "이미 잡혀 있는데도 예외 때문에 실패로 판정했다")
        let released = await inventory.released
        XCTAssertTrue(released.isEmpty,
                      "실제 예약 목록으로 걸러내지 않아 회수가 돌았다. 해제된 것: \(released.map(\.identifier))")
    }

    // MARK: - 잔여 예약 회수

    /// 비정상 종료가 남긴 예약이 한도를 채우고 있으면, 그것을 회수해 자리를 만들고 재시도한다.
    ///
    /// 실측 조건을 그대로 쓴다: 한도 5, 이 앱이 필요한 것은 2개. 남은 예약 5개가 자리를
    /// 전부 채운 상태다. 회수하지 않으면 사용자가 할 수 있는 조치는 앱 재시작뿐이고, 그
    /// 사실을 알 방법도 없다.
    func test_withStaleReservationsFillingLimit_reclaimsThemAndSucceeds() async {
        let stale = ["ja_JP", "zh_CN", "fr_FR", "de_DE", "it_IT"].map { Locale(identifier: $0) }
        let inventory = StubLocaleInventory(
            limit: 5,
            preReserved: stale,
            limitError: Self.limitError()
        )

        let outcome = await SpeechModelInstaller.reserve(
            locales: [korean, english],
            using: inventory
        )

        XCTAssertTrue(outcome.isComplete,
                      "잔여 예약을 회수하지 않아 시작이 막혔다 — 사용자는 앱 재시작 말고 할 수 있는 것이 없다")
        XCTAssertEqual(Set(outcome.reserved.map(\.identifier)), ["ko_KR", "en_US"])
        let reserved = Set(await inventory.reservedLocales().map(\.identifier))
        XCTAssertEqual(reserved, ["ko_KR", "en_US"],
                       "회수 후 남은 예약이 이번 세션의 로케일만이 아니다")
    }

    /// 회수는 **이번 세션이 쓰는 예약을 건드리지 않는다.**
    ///
    /// 쓸 것까지 해제하면 방금 확보한 모델을 스스로 놓아주는 셈이다.
    func test_whenReclaiming_keepsLocalesThisSessionNeeds() async {
        // ko_KR은 이미 잡혀 있고, en_US는 자리가 없어 실패하는 상태.
        let stale = ["ja_JP", "zh_CN", "fr_FR", "de_DE"].map { Locale(identifier: $0) }
        let inventory = StubLocaleInventory(
            limit: 5,
            preReserved: [korean] + stale,
            limitError: Self.limitError()
        )

        let outcome = await SpeechModelInstaller.reserve(
            locales: [korean, english],
            using: inventory
        )

        XCTAssertTrue(outcome.isComplete)
        let released = Set(await inventory.released.map(\.identifier))
        XCTAssertTrue(released.contains("ja_JP"),
                      "이번 세션이 쓰지 않는 예약을 회수하지 않았다")
        XCTAssertFalse(released.contains("ko_KR"),
                       "이번 세션이 쓰는 예약을 해제했다 — 확보한 모델을 스스로 놓아준다")
    }

    // MARK: - 원인 보존

    /// 회수해도 자리가 나지 않으면(다른 신원이 붙잡은 경우) **시스템이 준 원인을 그대로 싣는다.**
    func test_whenReservationFails_preservesTheSystemReason() async {
        let inventory = StubLocaleInventory(
            limit: 0,
            limitError: Self.limitError()
        )

        let outcome = await SpeechModelInstaller.reserve(
            locales: [korean, english],
            using: inventory
        )

        XCTAssertFalse(outcome.isComplete)
        XCTAssertTrue(outcome.reserved.isEmpty)
        XCTAssertEqual(outcome.unreserved.count, 2)
        for failure in outcome.unreserved {
            XCTAssertEqual(failure.reason, "Too many allocated locales, 5 maximum.",
                           "시스템이 준 실제 원인이 버려졌다 — 사용자는 해결할 수 없는 안내를 받는다")
        }
    }

    /// 한도 초과가 **아닌** 원인은 한도 초과로 보고되지 않는다.
    ///
    /// 관측된 오진의 본질이 이것이다. 예약 목록에 없다는 사실 하나로 한도 초과를 단정하면,
    /// 예약이 0개인 기기에서도 "5개를 초과했습니다"가 나온다.
    func test_withNonLimitFailure_doesNotReportLimitExceeded() async {
        let other = NSError(
            domain: "SFSpeechErrorDomain",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Asset locale not supported."]
        )
        let inventory = StubLocaleInventory(limit: 0, limitError: other)

        let outcome = await SpeechModelInstaller.reserve(
            locales: [korean],
            using: inventory
        )

        let reason = outcome.unreserved.first?.reason
        XCTAssertEqual(reason, "Asset locale not supported.")
        XCTAssertFalse(reason?.contains("maximum") ?? false,
                       "한도와 무관한 실패가 한도 초과로 보고됐다")

        // 사용자에게 보이는 문구에도 그 원인이 실려야 한다.
        let warning = MeetingRecorder.retentionWarning(for: outcome.unreserved)
        XCTAssertTrue(warning.contains("Asset locale not supported."),
                      "경고 문구가 실제 원인을 버렸다")
        XCTAssertFalse(warning.contains("초과"),
                       "한도와 무관한 실패인데 경고가 한도 초과를 말한다")
    }

    /// 세션을 접을 때의 오류 문구는 진단 상태를 함께 남긴다 — 실패 원인, 요청한 로케일,
    /// 그 시점의 예약 목록. 관측된 오진이 상태를 남기지 않아 원인을 사후에 좁힐 수 없었다.
    func test_reservationFailureError_carriesDiagnosticState() {
        let error = SpeechModelInstaller.InstallError.reservationFailed(
            locale: korean,
            reason: "Too many allocated locales, 5 maximum.",
            requested: [korean, english],
            reserved: [Locale(identifier: "ja_JP")]
        )

        let message = error.errorDescription ?? ""
        XCTAssertTrue(message.contains("ko_KR"), "실패한 로케일이 빠졌다")
        XCTAssertTrue(message.contains("Too many allocated locales, 5 maximum."),
                      "시스템이 준 원인이 빠졌다")
        XCTAssertTrue(message.contains("en_US"), "요청한 로케일 목록이 빠졌다")
        XCTAssertTrue(message.contains("ja_JP"),
                      "그 시점의 예약 목록이 빠졌다 — 원인을 사후에 좁힐 수 없다")
    }

    /// 예약이 하나도 없을 때 문구가 "없음"이라고 말해야 한다.
    ///
    /// 관측된 오진의 상태가 정확히 이것이었다 — 예약 0개인데 한도 초과라고 보고됐다.
    func test_reservationFailureError_withNoReservations_saysSo() {
        let error = SpeechModelInstaller.InstallError.reservationFailed(
            locale: korean,
            reason: nil,
            requested: [korean],
            reserved: []
        )

        let message = error.errorDescription ?? ""
        // 예약이 없다는 사실이 두 언어 모두에서 드러나야 한다 — 한쪽만 적히면 그 언어를 쓰지
        // 않는 사용자에게는 관측된 오진이 그대로 재현된다.
        XCTAssertTrue(message.contains("없음") || message.lowercased().contains("none"),
                      "예약이 0개인 상태가 문구에 드러나지 않는다 — 관측된 오진이 이 상태였다")
    }

    // MARK: - 해제 대상

    /// 해제 대상은 **실제로 잡힌 것만**이다.
    ///
    /// 잡히지 않은 로케일을 해제 목록에 넣어도 무해하지만(실측: 예약하지 않은 로케일 해제는
    /// false 반환), 잡힌 로케일이 목록에서 빠지면 그대로 붙잡힌 채 남아 다음 실행의 한도를
    /// 잠식한다. 예약은 프로세스 수명을 넘어 남으므로(실측) 그 잠식이 앱을 다시 켤 때까지
    /// 이어진다.
    func test_partialReservation_reportsOnlyWhatWasActuallyHeld() async {
        // ko_KR 하나만 들어갈 자리가 있는 상태.
        let inventory = StubLocaleInventory(limit: 1, limitError: Self.limitError())

        let outcome = await SpeechModelInstaller.reserve(
            locales: [korean, english],
            using: inventory
        )

        XCTAssertFalse(outcome.isComplete)
        XCTAssertEqual(outcome.reserved.map(\.identifier), ["ko_KR"],
                       "실제로 잡힌 로케일이 해제 대상에서 빠졌다 — 다음 실행까지 붙잡힌 채 남는다")
        XCTAssertEqual(outcome.unreserved.map(\.locale.identifier), ["en_US"])
    }
}

/// 시스템 예약을 흉내내는 대역. 한도와 실패 원인을 테스트가 정한다.
///
/// 실측된 두 성질을 그대로 재현한다: 이미 예약된 로케일에 `false`를 반환하고, 한도를 넘으면
/// 던진다.
private actor StubLocaleInventory: LocaleInventory {
    private let limit: Int
    private let limitError: Error
    /// 이미 잡혀 있어도 예외를 던지는 구성. 판정 근거가 예외가 아니라 예약 목록임을 검증한다.
    private let throwsAlways: Bool
    private var reserved: [Locale]
    private(set) var released: [Locale] = []

    init(
        limit: Int,
        preReserved: [Locale] = [],
        limitError: Error? = nil,
        throwsAlways: Bool = false
    ) {
        self.limit = limit
        self.reserved = preReserved
        self.throwsAlways = throwsAlways
        self.limitError = limitError ?? NSError(
            domain: "SFSpeechErrorDomain",
            code: 11,
            userInfo: [NSLocalizedDescriptionKey: "Too many allocated locales, 5 maximum."]
        )
    }

    func reserve(_ locale: Locale) async throws -> Bool {
        if throwsAlways { throw limitError }
        // 집합 의미: 이미 잡혀 있으면 false. 실패가 아니다.
        if reserved.contains(where: { $0.identifier == locale.identifier }) { return false }
        guard reserved.count < limit else { throw limitError }
        reserved.append(locale)
        return true
    }

    func release(_ locale: Locale) async -> Bool {
        released.append(locale)
        let before = reserved.count
        reserved.removeAll { $0.identifier == locale.identifier }
        return reserved.count < before
    }

    func reservedLocales() async -> [Locale] { reserved }
}
