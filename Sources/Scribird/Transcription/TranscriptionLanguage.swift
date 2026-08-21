import Foundation

/// 회의 전사에 쓸 언어 구성.
///
/// `SpeechTranscriber`는 인스턴스 하나당 로케일 하나만 담당한다. 여러 언어를
/// 다루려면 로케일별 전사기를 만들어 같은 `SpeechAnalyzer`에 함께 물린다.
/// 검증 결과 두 로케일 전사기가 한 분석기에서 공존하며 각자 결과를 낸다.
enum TranscriptionLanguage: String, CaseIterable, Identifiable, Sendable {
    case korean
    case english
    /// 한국어와 영어를 동시에 돌리고 신뢰도로 승자를 고른다.
    case auto

    var id: String { rawValue }

    var displayName: String {
        switch self {
        // 전사 언어는 자기 언어로 적는다 — 화면 언어와 무관하게 어느 언어로 인식되는지가
        // 이 값의 정보이고, 언어 이름은 그 언어로 적는 것이 관례다.
        case .korean: "한국어"
        case .english: "English"
        case .auto: "한국어 + English"
        }
    }

    /// 이 구성이 요구하는 로케일들. `auto`는 둘 다 필요하다.
    var locales: [Locale] {
        switch self {
        case .korean: [Locale(identifier: "ko-KR")]
        case .english: [Locale(identifier: "en-US")]
        case .auto: [Locale(identifier: "ko-KR"), Locale(identifier: "en-US")]
        }
    }

    /// 언어가 둘 이상이면 결과 중재가 필요하다.
    var needsArbitration: Bool { locales.count > 1 }

    /// 설치된 로케일로 실제 구성할 수 있는 회의 언어만 돌려준다.
    static func available(installedIdentifiers: [String]) -> [TranscriptionLanguage] {
        let preferredOrder: [TranscriptionLanguage] = [.english, .korean, .auto]
        return preferredOrder.filter {
            SpeechModelInstaller.allInstalled(
                requested: $0.locales,
                installedIdentifiers: installedIdentifiers
            )
        }
    }

    /// 한 구성에서 다른 구성으로 옮길 때 실제로 바뀌는 로케일.
    ///
    /// **양쪽에 다 있는 로케일은 어디에도 넣지 않는다.** 그 전사기를 그대로 두는 것이
    /// 규칙이라서다 — 새로 만들면 진행 중이던 그 언어의 발화까지 잃는다. 같은 구성으로
    /// 바꾸면 양쪽이 비어, 분석기를 건드릴 이유가 없다는 것이 이 값으로 드러난다.
    func localeDifference(
        from previous: TranscriptionLanguage
    ) -> (added: [Locale], removed: [Locale]) {
        let before = previous.locales
        let after = locales
        return (
            added: after.filter { locale in
                !before.contains { $0.identifier == locale.identifier }
            },
            removed: before.filter { locale in
                !after.contains { $0.identifier == locale.identifier }
            }
        )
    }
}
