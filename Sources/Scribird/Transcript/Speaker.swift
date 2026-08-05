import Foundation

/// 화자 구분.
///
/// Apple Speech 프레임워크에는 화자분리(diarization) API가 없다. 대신 회의 오디오가
/// 물리적으로 두 갈래로 들어온다는 사실을 이용한다. 마이크 입력은 반드시 나이고,
/// 시스템 출력(Zoom/Teams가 재생하는 소리)은 반드시 상대방이다. 소스를 나눠서
/// 각각 전사하면 100% 정확한 2화자 분리를 얻는다.
enum Speaker: String, Codable, CaseIterable, Sendable {
    /// 마이크로 들어온 내 목소리.
    case me
    /// 시스템 출력으로 재생된 원격 참석자 목소리.
    case remote

    /// 화면에 보여줄 이름. 화면 언어를 따른다.
    var displayName: String { displayName(language: .current) }

    /// 언어를 지정해 읽는다. 테스트가 실행 환경의 시스템 언어에 좌우되지 않으려면 필요하다.
    func displayName(language: AppLanguage) -> String {
        switch self {
        case .me: tr("나", "Me", language: language)
        case .remote: tr("상대방", "Remote", language: language)
        }
    }

    /// 산출물(회의록)에 적히는 이름. **화면 언어와 무관하게 고정이다.**
    ///
    /// 회의록은 파일로 남아 나중에 다른 도구와 사람이 함께 읽는다. 형식이 설정에 의존하면 한
    /// 폴더 안에서 어휘가 섞이고, 그것을 읽는 도구는 어느 설정으로 만들어졌는지 알 수 없어 두
    /// 어휘를 모두 다뤄야 한다 — 이 저장소의 화자 세분화 도구가 그 처지가 된다. 기계가 읽는
    /// 화자 필드(`rawValue`)가 이미 쓰는 어휘와 같은 계열로 둔다.
    var archiveName: String {
        switch self {
        case .me: "Me"
        case .remote: "Remote"
        }
    }

    /// 사이드바·라벨에 쓰는 짧은 기호.
    var symbol: String {
        switch self {
        case .me: "mic.fill"
        case .remote: "speaker.wave.2.fill"
        }
    }
}
