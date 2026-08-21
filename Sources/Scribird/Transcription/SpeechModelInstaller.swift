import Foundation
import Speech

/// 로케일 예약 창구. 실제 시스템 예약과 테스트용 대역을 같은 형태로 다루기 위한 것이다.
protocol LocaleInventory: Sendable {
    /// 이미 예약된 로케일이면 false를 돌려준다. 실패는 던진다.
    func reserve(_ locale: Locale) async throws -> Bool
    func release(_ locale: Locale) async -> Bool
    func reservedLocales() async -> [Locale]
}

/// 시스템 예약을 그대로 위임한다.
struct SystemLocaleInventory: LocaleInventory {
    func reserve(_ locale: Locale) async throws -> Bool {
        try await AssetInventory.reserve(locale: locale)
    }

    func release(_ locale: Locale) async -> Bool {
        await AssetInventory.release(reservedLocale: locale)
    }

    func reservedLocales() async -> [Locale] {
        await AssetInventory.reservedLocales
    }
}

/// 온디바이스 전사 모델(에셋)을 확인하고 필요하면 내려받는다.
///
/// `SpeechTranscriber`는 로케일별 모델이 설치돼 있어야 동작한다. 모델이 없으면
/// `bestAvailableAudioFormat`이 nil을 반환하므로 반드시 설치를 먼저 끝내야 한다.
enum SpeechModelInstaller {
    enum InstallError: LocalizedError {
        case localeUnsupported(Locale)
        case installationUnavailable(Locale)
        case incompleteInstallation(Locale)
        /// 예약에 실패했고 모델도 미설치라 다운로드를 붙잡을 수 없는 경우.
        ///
        /// 진단 상태를 함께 들고 다닌다. 실패 원인을 버리고 한도 초과로 단정한 예전 문구가
        /// 예약 0개인 기기에서 "5개를 초과했습니다"라는 오진을 냈고, 그 시점의 상태가 아무
        /// 데도 남지 않아 원인을 사후에 좁힐 수 없었다.
        case reservationFailed(
            locale: Locale,
            reason: String?,
            requested: [Locale],
            reserved: [Locale]
        )

        var errorDescription: String? {
            switch self {
            case .localeUnsupported(let locale):
                tr("\(locale.identifier) 전사를 이 기기에서 지원하지 않습니다.",
                   "This device doesn't support transcription for \(locale.identifier).")
            case .installationUnavailable(let locale):
                tr("\(locale.identifier) 언어 모델 설치 요청을 만들 수 없습니다.",
                   "Couldn't create an installation request for the \(locale.identifier) language model.")
            case .incompleteInstallation(let locale):
                tr(
                    "\(locale.identifier) 언어 모델 설치 요청이 끝났지만 모델을 확인하지 못했습니다. 다시 시도해 주세요.",
                    "The \(locale.identifier) language model request finished, but the model wasn't installed. Try again."
                )
            case .reservationFailed(let locale, let reason, let requested, let reserved):
                tr(
                    """
                    \(locale.identifier) 언어 모델을 확보하지 못했고 모델이 아직 설치되지 \
                    않아 녹취를 시작할 수 없습니다.
                    원인: \(reason ?? "시스템이 원인을 알려주지 않았습니다.")
                    요청한 언어: \(requested.map(\.identifier).joined(separator: ", "))
                    현재 예약: \(Self.describe(reserved)) (한도 \(AssetInventory.maximumReservedLocales)개)
                    """,
                    """
                    Couldn't secure the \(locale.identifier) language model, and the model \
                    isn't installed yet, so recording can't start.
                    Reason: \(reason ?? "the system did not report a reason.")
                    Requested: \(requested.map(\.identifier).joined(separator: ", "))
                    Currently reserved: \(Self.describe(reserved)) (limit \(AssetInventory.maximumReservedLocales))
                    """
                )
            }
        }

        private static func describe(_ locales: [Locale]) -> String {
            locales.isEmpty
                ? tr("없음", "none")
                : locales.map(\.identifier).joined(separator: ", ")
        }
    }

    /// 예약 시도의 결과. 실패했어도 모델이 설치돼 있으면 녹취는 진행한다.
    struct ReservationOutcome {
        /// 실제로 예약된 로케일. 세션 종료 시 해제 대상이다.
        var reserved: [Locale]
        /// 예약하지 못한 로케일과 시스템이 알려준 원인.
        var unreserved: [(locale: Locale, reason: String?)]

        var isComplete: Bool { unreserved.isEmpty }
    }

    /// 요청한 로케일 중 실제로 쓸 수 있는 것으로 보정한다.
    /// 예: `ko-KR`을 요청했는데 시스템이 `ko_KR`만 알고 있는 경우.
    static func resolveLocale(_ requested: Locale) async throws -> Locale {
        if let matched = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
            return matched
        }
        throw InstallError.localeUnsupported(requested)
    }

    static func resolveLocales(_ requested: [Locale]) async throws -> [Locale] {
        var resolved: [Locale] = []
        for locale in requested {
            resolved.append(try await resolveLocale(locale))
        }
        return resolved
    }

    /// 로케일 모델을 시스템이 정리하지 않도록 붙잡아 둔다.
    ///
    /// `reserve`는 집합 의미라 **이미 예약된 로케일에는 false를 반환**한다.
    /// 이를 실패로 보면 두 번째 실행부터 항상 에러가 나므로, 반환값이 아니라
    /// 실제 예약 목록을 확인해서 판정한다.
    ///
    /// 실패하면 **이번 세션이 쓰지 않는 예약을 회수해 자리를 만든 뒤 한 번 더 시도한다.**
    /// 예약은 프로세스 수명을 넘어 남으므로(실측: 한 실행이 예약한 로케일이 종료 후 별개
    /// 실행에서 그대로 조회됨) 비정상 종료가 남긴 예약이 한도를 잠식한 상태로 시작할 수
    /// 있다. 회수하지 않으면 사용자가 할 수 있는 조치가 앱 재시작뿐이고, 그 사실을 알
    /// 방법도 없다.
    ///
    /// 던지지 않는다 — 예약 실패가 전사 불가를 뜻하지 않기 때문이다. 실측에서 예약 0개
    /// 상태로도 최적 오디오 포맷 질의가 `16000 Hz, Int16`을 반환하고 분석기 준비가
    /// 성공했다. 계속할지 접을지는 모델 설치 여부를 아는 호출자가 판단한다.
    static func reserve(locales: [Locale]) async -> ReservationOutcome {
        await reserve(locales: locales, using: SystemLocaleInventory())
    }

    /// 예약 절차. `AssetInventory`를 인터페이스로 갈라 테스트가 실제 시스템 예약을 건드리지
    /// 않고 이 순서와 판정을 검증할 수 있게 한다.
    static func reserve(
        locales: [Locale],
        using inventory: some LocaleInventory
    ) async -> ReservationOutcome {
        var reasons = await attemptReserve(locales, using: inventory)
        if !reasons.isEmpty {
            await releaseUnrelated(keeping: locales, using: inventory)
            reasons = await attemptReserve(locales, using: inventory)
        }

        let reserved = Set(await inventory.reservedLocales().map(\.identifier))
        return ReservationOutcome(
            reserved: locales.filter { reserved.contains($0.identifier) },
            unreserved: locales
                .filter { !reserved.contains($0.identifier) }
                .map { ($0, reasons[$0.identifier]) }
        )
    }

    /// 예약을 시도하고, 붙잡지 못한 로케일의 원인을 로케일 식별자별로 돌려준다.
    ///
    /// 원인을 버리지 않는 것이 이 함수의 존재 이유다. 한도 초과는 다른 실패와 구분되는
    /// 원인(실측: `SFSpeechErrorDomain` 코드 11, "Too many allocated locales, 5
    /// maximum.")이므로, 삼켜 버리면 한도에 닿지 않은 실패까지 한도 초과로 보고된다.
    ///
    /// 반환값이 아니라 실제 예약 목록으로 판정한다 — `reserve`는 집합 의미라 **이미 예약된
    /// 로케일에 false를 반환**하므로(실측) 반환값을 실패로 읽으면 두 번째 실행부터 항상
    /// 에러가 난다.
    private static func attemptReserve(
        _ locales: [Locale],
        using inventory: some LocaleInventory
    ) async -> [String: String] {
        var reasons: [String: String] = [:]
        for locale in locales {
            do {
                _ = try await inventory.reserve(locale)
            } catch {
                reasons[locale.identifier] = error.localizedDescription
            }
        }
        let reserved = Set(await inventory.reservedLocales().map(\.identifier))
        return reasons.filter { !reserved.contains($0.key) }
    }

    /// 이번 세션이 쓰지 않는 예약을 해제해 한도에 자리를 만든다.
    private static func releaseUnrelated(
        keeping locales: [Locale],
        using inventory: some LocaleInventory
    ) async {
        let keep = Set(locales.map(\.identifier))
        for locale in await inventory.reservedLocales()
        where !keep.contains(locale.identifier) {
            _ = await inventory.release(locale)
        }
    }

    /// 모듈들의 모델이 이미 설치돼 있는지. 예약 없이 진행해도 되는지의 판단 근거다.
    static func isInstalled(modules: [any SpeechModule]) async -> Bool {
        await AssetInventory.status(forModules: modules) == .installed
    }

    /// 설치 상태를 묻고 다운로드를 요청하기 위한 모듈. 결과를 받는 데는 쓰지 않는다.
    ///
    /// 에셋 API가 로케일이 아니라 모듈을 받으므로 필요하다. 이 인스턴스를 분석기에 물리지
    /// 않는 것이 중요하다 — 녹취 중 전환에서는 살아 있는 세션이 자기 전사기를 따로 만든다.
    static func transcriberModule(for locale: Locale) -> any SpeechModule {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    }

    /// 이 로케일들의 모델이 모두 설치돼 있는지.
    ///
    /// **녹취 중 언어 전환은 이 판정을 먼저 통과해야 한다.** 미설치 로케일을 살아 있는
    /// 분석기에 넣으면 그 분석기가 회복 불가능하게 죽는다 — 실측: 교체가 실패를 던진 뒤에도
    /// 모듈 목록에는 그것이 남았고("No GeneralASR asset for language ja", modules=2),
    /// 원래 구성으로 되돌리는 교체는 성공을 반환하면서 실제로 복구하지 못했으며, 아무 문제
    /// 없던 기존 로케일의 결과 스트림까지 같은 에러로 닫혀 진행 중이던 발화가 사라졌다.
    /// 그러므로 시도해 보고 되돌리는 방식은 쓸 수 없고, 넣기 전에 확인하는 것만이 안전하다.
    static func areInstalled(locales: [Locale]) async -> Bool {
        allInstalled(
            requested: locales,
            installedIdentifiers: await SpeechTranscriber.installedLocales.map(\.identifier)
        )
    }

    /// 설치 판정. 시스템 조회에서 떼어내 테스트가 실측된 목록을 그대로 넣을 수 있게 한다.
    ///
    /// **하나라도 미설치면 전체가 미설치다.** 설치된 쪽만 보고 교체를 진행하면 미설치 쪽이
    /// 분석기에 들어가고, 그 실패는 되돌릴 수 없다.
    ///
    /// 시스템은 설치 목록을 밑줄 표기(`ko_KR`)로 돌려주고 이 앱은 붙임표 표기(`ko-KR`)로
    /// 요청한다(실측). 구분자를 통일하지 않으면 설치된 모델을 미설치로 오판해 전환마다
    /// 다운로드를 기다린다.
    static func allInstalled(requested: [Locale], installedIdentifiers: [String]) -> Bool {
        let installed = Set(installedIdentifiers.map(normalized))
        return !requested.isEmpty
            && requested.allSatisfy { installed.contains(normalized($0.identifier)) }
    }

    private static func normalized(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    static func installedLocaleIdentifiers() async -> [String] {
        await SpeechTranscriber.installedLocales.map(\.identifier)
    }

    static func reservedLocales() async -> [Locale] {
        await AssetInventory.reservedLocales
    }

    static func install(locale requestedLocale: Locale) async throws {
        let locale = try await resolveLocale(requestedLocale)
        if await areInstalled(locales: [locale]) {
            return
        }

        let module = transcriberModule(for: locale)
        try await installModules([module], locale: locale)
    }

    private static func installModules(
        _ modules: [any SpeechModule],
        locale: Locale
    ) async throws {
        let status = await AssetInventory.status(forModules: modules)
        guard status != .installed else { return }

        guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules)
        else {
            throw InstallError.installationUnavailable(locale)
        }

        // Progress 취소는 언어 구독 해제와 설치된 에셋 회수로 이어질 수 있다.
        try await request.downloadAndInstall()
        guard await AssetInventory.status(forModules: modules) == .installed else {
            throw InstallError.incompleteInstallation(locale)
        }
    }

    /// 테스트 픽스처가 명시적으로 요구한 모듈을 설치할 때 쓴다.
    static func ensureModels(for modules: [any SpeechModule]) async throws {
        try await installModules(
            modules,
            locale: Locale(identifier: "und")
        )
    }

    static func release(locales: [Locale]) async {
        for locale in locales {
            _ = await AssetInventory.release(reservedLocale: locale)
        }
    }
}
