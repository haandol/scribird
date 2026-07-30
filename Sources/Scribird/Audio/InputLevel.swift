import Foundation

/// 소스 하나의 실시간 입력 레벨. 미터 표시와 레벨 진단에 쓴다.
struct InputLevel: Sendable {
    /// 0...1로 정규화된 미터 값 (dBFS 기반).
    let meter: Float
    /// 사람이 읽는 dBFS. 레벨이 적정한지 판단할 근거.
    let decibels: Float

    /// 녹음 레벨 진단.
    ///
    /// 음성 녹음의 통상 권장치는 피크 -12~-6 dBFS다. 그보다 훨씬 낮으면
    /// 전사는 되더라도 나중에 사람이 듣거나 재처리할 때 아쉽다.
    enum Quality: Equatable, Sendable {
        case silent
        case tooQuiet
        case good
        case tooLoud
    }

    var quality: Quality {
        switch decibels {
        case ..<(-50): .silent
        case ..<(-24): .tooQuiet
        case ..<(-3): .good
        default: .tooLoud
        }
    }
}
