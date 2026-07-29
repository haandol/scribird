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

    var displayName: String {
        switch self {
        case .me: "나"
        case .remote: "상대방"
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
