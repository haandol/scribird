import Foundation

/// 화면에 쓰는 언어.
///
/// 전사 언어(`TranscriptionLanguage`)와 **다른 값이다.** 화면을 읽는 언어와 회의에서 말하는
/// 언어는 같을 이유가 없다 — 시스템을 영어로 쓰면서 한국어 회의를 녹취하는 구성이 실재한다.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case korean
    case english

    var id: String { rawValue }

    /// 설정 화면의 항목 이름. **자기 언어로 적는다.**
    ///
    /// 읽을 수 없는 언어로 적힌 항목은 고를 수 없다 — 영어 화면에서 「한국어」를 찾는 것도,
    /// 한국어 화면에서 「English」를 찾는 것도 그 언어를 아는 사람에게 자명해야 한다.
    var displayName: String {
        switch self {
        case .korean: "한국어"
        case .english: "English"
        }
    }

    /// 시스템 언어에 맞는 값.
    ///
    /// **이것이 기본값인 이유**: 영어권 사용자가 한국어 화면에서 언어 설정을 찾아내야 하는
    /// 상태를 만들지 않기 위해서다 — 읽을 수 없는 화면에서 설정을 찾는 것이 이 기능이 풀려는
    /// 문제 그 자체다.
    ///
    /// 시스템이 선호 언어를 여러 개 들고 있으므로 첫 항목만 본다. 한국어가 두 번째라면 그것은
    /// 한국어보다 앞선 언어가 있다는 뜻이므로 영어 화면이 맞다.
    static func matchingSystem(
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> AppLanguage {
        guard let first = preferredLanguages.first,
              Locale(identifier: first).language.languageCode?.identifier == "ko"
        else { return .english }
        return .korean
    }

    /// 지금 화면에 쓰이는 언어.
    ///
    /// **전역으로 두는 이유**: 오류 문구는 `LocalizedError`가 만드는데, 그 타입들은 오디오
    /// 콜백이나 액터 밖에서 살아 설정 객체에 닿을 수 없다. 실패 문구를 번역하지 않으면 이 결정이
    /// 풀려는 문제의 핵심이 남으므로(정작 문제가 생겼을 때 읽을 수 없는 화면), 언어를 읽는 경로가
    /// 격리를 넘어야 한다.
    ///
    /// 화면 갱신은 이 값이 아니라 관찰 가능한 설정이 담당한다 — 여기는 문구를 만들 때 읽는
    /// 출처일 뿐이다.
    private static let lock = NSLock()
    private nonisolated(unsafe) static var storage: AppLanguage?

    static var current: AppLanguage {
        lock.withLock {
            if let storage { return storage }
            let resolved = RecordingPreferences.appLanguage() ?? matchingSystem()
            storage = resolved
            return resolved
        }
    }

    /// 화면 언어를 바꾼다. 설정이 이것을 호출한다.
    static func setCurrent(_ language: AppLanguage) {
        lock.withLock { storage = language }
    }
}

/// 언어별 문구를 고른다.
///
/// 두 문구를 **한 자리에 나란히 둔다.** 언어별로 파일을 나누면 한쪽에만 있는 문구가 생기고, 그
/// 누락은 그 언어로 앱을 쓰는 사람에게만 보여 개발 중에는 드러나지 않는다. 나란히 두면 빠진 것이
/// 컴파일 단계에서 드러난다.
func tr(_ korean: String, _ english: String, language: AppLanguage = .current) -> String {
    switch language {
    case .korean: korean
    case .english: english
    }
}
