import Foundation
import Speech

/// 온디바이스 전사 모델(에셋)을 확인하고 필요하면 내려받는다.
///
/// `SpeechTranscriber`는 로케일별 모델이 설치돼 있어야 동작한다. 모델이 없으면
/// `bestAvailableAudioFormat`이 nil을 반환하므로 반드시 설치를 먼저 끝내야 한다.
enum SpeechModelInstaller {
    enum InstallError: LocalizedError {
        case localeUnsupported(Locale)
        case reservationLimitReached(Locale)

        var errorDescription: String? {
            switch self {
            case .localeUnsupported(let locale):
                "\(locale.identifier) 전사를 이 기기에서 지원하지 않습니다."
            case .reservationLimitReached(let locale):
                "\(locale.identifier) 언어 모델을 확보하지 못했습니다. 예약 가능한 로케일 수(\(AssetInventory.maximumReservedLocales)개)를 초과했습니다."
            }
        }
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
    static func reserve(locales: [Locale]) async throws {
        for locale in locales {
            _ = try? await AssetInventory.reserve(locale: locale)
        }
        let reserved = Set(await AssetInventory.reservedLocales.map(\.identifier))
        for locale in locales where !reserved.contains(locale.identifier) {
            throw InstallError.reservationLimitReached(locale)
        }
    }

    /// 모듈들이 필요한 에셋을 보장한다. 다운로드가 필요하면 진행률을 콜백으로 보고한다.
    ///
    /// 여러 로케일 모듈을 한 번에 넘기면 필요한 에셋을 묶어서 한 요청으로 받는다.
    static func ensureModels(
        for modules: [any SpeechModule],
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let status = await AssetInventory.status(forModules: modules)
        guard status != .installed else {
            onProgress(1.0)
            return
        }

        guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules)
        else {
            // 설치할 것이 없다는 뜻 — 이미 준비된 상태로 취급한다.
            onProgress(1.0)
            return
        }

        // Progress는 KVO 기반이라 폴링으로 읽는다. 다운로드가 끝나면 태스크를 접는다.
        let progress = request.progress
        let reporter = Task.detached {
            while !Task.isCancelled, !progress.isFinished {
                onProgress(progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { reporter.cancel() }

        try await request.downloadAndInstall()
        onProgress(1.0)
    }

    static func release(locales: [Locale]) async {
        for locale in locales {
            _ = await AssetInventory.release(reservedLocale: locale)
        }
    }
}
