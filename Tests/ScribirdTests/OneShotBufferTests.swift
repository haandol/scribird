import AVFoundation
import XCTest
@testable import Scribird

/// 1회용 버퍼 상자 테스트.
///
/// 이 상자의 1회성이 두 곳의 안전을 떠받친다. 원본 저장에서는 캡처 스레드와 쓰기 큐가
/// 같은 버퍼를 동시에 만지지 않는 근거이고, 리샘플링에서는 변환기가 입력을 한 번만
/// 받아 `noDataNow`로 넘어가게 하는 장치다. 두 번째 `take()`가 nil이 아니면 전자는
/// 데이터 경합, 후자는 무한 루프가 된다.
final class OneShotBufferTests: XCTestCase {

    private func buffer(frames: AVAudioFrameCount = 128) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
                                   channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        return buffer
    }

    func test_take_returnsTheBufferOnce() {
        let original = buffer()
        let box = OneShotBuffer(original)

        XCTAssertTrue(box.take() === original, "넣은 버퍼가 그대로 나오지 않았다")
    }

    /// 두 번째 호출은 반드시 nil이어야 한다.
    ///
    /// 리샘플링에서 이 값이 nil이 아니면 변환기가 같은 입력을 계속 받아 `noDataNow`에
    /// 도달하지 못한다.
    func test_take_returnsNilOnSecondCall() {
        let box = OneShotBuffer(buffer())

        XCTAssertNotNil(box.take())
        XCTAssertNil(box.take(), "두 번 꺼내지면 변환기가 같은 입력을 반복해서 받는다")
        XCTAssertNil(box.take())
    }

    /// 여러 스레드가 동시에 꺼내도 딱 하나만 성공해야 한다.
    ///
    /// 원본 저장 경로는 캡처 콜백과 쓰기 큐를 실제로 건넌다. 둘이 같은 버퍼를 받으면
    /// 한쪽이 쓰는 동안 다른 쪽이 읽어 데이터 경합이 된다.
    func test_take_isExclusiveUnderConcurrentAccess() {
        for _ in 0..<200 {
            let box = OneShotBuffer(buffer())
            let counter = Counter()

            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                if box.take() != nil { counter.increment() }
            }

            XCTAssertEqual(counter.value, 1,
                           "동시에 \(counter.value)곳이 같은 버퍼를 받았다 — 데이터 경합")
        }
    }

    /// 여러 스레드에서 세는 카운터. 이 자체는 검사 대상이 아니므로 락으로 단순히 막는다.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
}
