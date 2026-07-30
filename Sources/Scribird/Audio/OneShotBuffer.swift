import AVFoundation
import Foundation

/// 논-Sendable 오디오 버퍼를 딱 한 번만 내주는 상자.
///
/// `AVAudioPCMBuffer`는 `Sendable`이 아니어서 클로저 경계를 넘길 수 없다. 참조 뒤에
/// 숨기고 `take()`가 소유권을 옮기게 해서, 두 곳이 같은 버퍼를 동시에 만지지 않는다는
/// 것을 1회성으로 보장한다. 쓰이는 두 곳:
///
/// - 원본 저장: 캡처 스레드가 복사본을 넣고 쓰기 큐가 꺼내 간다 — **정말로 다른
///   스레드를 건넌다.**
/// - 리샘플링: `AVAudioConverter`의 입력 블록이 `@Sendable`이라 지역 변수를 변경
///   캡처할 수 없다. 실제 호출은 `convert(to:error:)` 안에서 동기로 일어난다.
///
/// 두 경우가 필요로 하는 동기화 수준은 다르지만 락을 그대로 둔다. 어느 쪽으로
/// 쓰이는지를 사용처가 알아야 안전해지는 타입은 다음 사람이 틀리게 쓰기 쉽다.
final class OneShotBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    /// 버퍼를 꺼낸다. 두 번째 호출부터는 nil이다.
    func take() -> AVAudioPCMBuffer? {
        lock.withLock {
            defer { buffer = nil }
            return buffer
        }
    }
}
