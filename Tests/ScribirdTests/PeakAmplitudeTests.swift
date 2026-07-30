import AVFoundation
import XCTest
@testable import Scribird

/// 진폭 측정 테스트.
///
/// 이 경로에 실제 버그가 있었다. 흔한 `floatChannelData[0][frame]` 접근은
/// **디인터리브** 배치를 가정하는데 프로세스 탭은 Float32 **인터리브**로 준다.
/// 배치를 구분하지 않으면 엉뚱한 위치를 읽어 시스템 오디오가 항상 무음으로
/// 오진된다. 그래서 배치별 테스트가 이 파일의 핵심이다.
final class PeakAmplitudeTests: XCTestCase {

    private func format(
        _ commonFormat: AVAudioCommonFormat, channels: AVAudioChannelCount, interleaved: Bool
    ) -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: commonFormat, sampleRate: 48000,
            channels: channels, interleaved: interleaved
        )!
    }

    private func buffer(_ format: AVAudioFormat, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        return buffer
    }

    // MARK: - Float32 인터리브 (프로세스 탭이 주는 형식)

    func test_float32Interleaved_readsPeakFromBothChannels() {
        let buffer = buffer(format(.pcmFormatFloat32, channels: 2, interleaved: true), frames: 512)
        let samples = buffer.floatChannelData![0]

        // L 채널은 조용하고 R 채널에만 신호가 있다. 배치를 잘못 읽으면 놓친다.
        for frame in 0..<512 {
            samples[frame * 2] = 0.01       // L
            samples[frame * 2 + 1] = 0.75   // R
        }

        XCTAssertEqual(buffer.peakAmplitude(), 0.75, accuracy: 0.001,
                       "인터리브 배치에서 R 채널 신호를 놓쳤다")
    }

    func test_float32Interleaved_silenceReadsAsZero() {
        let buffer = buffer(format(.pcmFormatFloat32, channels: 2, interleaved: true), frames: 512)
        let samples = buffer.floatChannelData![0]
        for index in 0..<(512 * 2) { samples[index] = 0 }

        XCTAssertEqual(buffer.peakAmplitude(), 0, accuracy: 0.00001,
                       "무음을 무음으로 읽지 못하면 권한 판정이 무너진다")
    }

    func test_float32Interleaved_negativePeakIsMeasuredAsMagnitude() {
        let buffer = buffer(format(.pcmFormatFloat32, channels: 2, interleaved: true), frames: 256)
        let samples = buffer.floatChannelData![0]
        for index in 0..<(256 * 2) { samples[index] = -0.6 }

        XCTAssertEqual(buffer.peakAmplitude(), 0.6, accuracy: 0.001,
                       "음의 진폭을 절대값으로 읽지 않았다")
    }

    // MARK: - Float32 디인터리브 (마이크 경로에서 흔한 형식)

    func test_float32Deinterleaved_readsPeakFromSecondChannel() {
        let buffer = buffer(format(.pcmFormatFloat32, channels: 2, interleaved: false), frames: 512)
        let channels = buffer.floatChannelData!

        for frame in 0..<512 {
            channels[0][frame] = 0.02
            channels[1][frame] = 0.65
        }

        XCTAssertEqual(buffer.peakAmplitude(), 0.65, accuracy: 0.001,
                       "디인터리브 배치에서 두 번째 채널을 읽지 못했다")
    }

    func test_float32Deinterleaved_mono() {
        let buffer = buffer(format(.pcmFormatFloat32, channels: 1, interleaved: false), frames: 256)
        let samples = buffer.floatChannelData![0]
        for frame in 0..<256 { samples[frame] = 0.33 }

        XCTAssertEqual(buffer.peakAmplitude(), 0.33, accuracy: 0.001)
    }

    // MARK: - Int16 (일부 입력 장치가 주는 형식)

    func test_int16Interleaved_scalesToUnitRange() {
        let buffer = buffer(format(.pcmFormatInt16, channels: 2, interleaved: true), frames: 256)
        let samples = buffer.int16ChannelData![0]

        for frame in 0..<256 {
            samples[frame * 2] = 0
            samples[frame * 2 + 1] = Int16.max / 2
        }

        XCTAssertEqual(buffer.peakAmplitude(), 0.5, accuracy: 0.01,
                       "Int16을 0...1 범위로 정규화하지 못했다")
    }

    func test_int16Deinterleaved_scalesToUnitRange() {
        let buffer = buffer(format(.pcmFormatInt16, channels: 1, interleaved: false), frames: 256)
        let samples = buffer.int16ChannelData![0]
        for frame in 0..<256 { samples[frame] = Int16.max }

        XCTAssertEqual(buffer.peakAmplitude(), 1.0, accuracy: 0.01)
    }

    func test_int16_silence() {
        let buffer = buffer(format(.pcmFormatInt16, channels: 2, interleaved: true), frames: 256)
        let samples = buffer.int16ChannelData![0]
        for index in 0..<(256 * 2) { samples[index] = 0 }

        XCTAssertEqual(buffer.peakAmplitude(), 0, accuracy: 0.00001)
    }

    // MARK: - Int32

    func test_int32Interleaved_scalesToUnitRange() {
        let buffer = buffer(format(.pcmFormatInt32, channels: 2, interleaved: true), frames: 256)
        let samples = buffer.int32ChannelData![0]

        for frame in 0..<256 {
            samples[frame * 2] = 0
            samples[frame * 2 + 1] = Int32.max / 4
        }

        XCTAssertEqual(buffer.peakAmplitude(), 0.25, accuracy: 0.01)
    }

    // MARK: - 경계 조건

    func test_emptyBuffer_readsAsZero() {
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format(.pcmFormatFloat32, channels: 2, interleaved: true),
            frameCapacity: 512
        )!
        buffer.frameLength = 0

        XCTAssertEqual(buffer.peakAmplitude(), 0,
                       "빈 버퍼에서 진폭을 읽으려 하면 안 된다")
    }

    /// 표본 추출이 신호를 놓치지 않는지.
    ///
    /// 전수 검사가 아니라 일정 간격으로 뽑으므로, 신호가 드문드문 있으면 이론상
    /// 놓칠 수 있다. 무음/유음을 가르는 목적에는 충분하다는 판단이지만, 넓게 퍼진
    /// 신호는 반드시 잡아야 한다.
    func test_sustainedSignal_isFoundBySampling() {
        let buffer = buffer(format(.pcmFormatFloat32, channels: 1, interleaved: false), frames: 4096)
        let samples = buffer.floatChannelData![0]
        for frame in 0..<4096 { samples[frame] = 0.4 }

        XCTAssertEqual(buffer.peakAmplitude(), 0.4, accuracy: 0.001,
                       "지속되는 신호를 표본 추출이 놓쳤다")
    }

    func test_largeBufferWithSignalThroughout_isDetected() {
        let buffer = buffer(format(.pcmFormatFloat32, channels: 2, interleaved: true), frames: 8192)
        let samples = buffer.floatChannelData![0]
        // 전 구간에 걸쳐 신호가 있고 중간중간 더 큰 값이 섞인다.
        for frame in 0..<8192 {
            let value: Float = frame % 100 == 0 ? 0.9 : 0.3
            samples[frame * 2] = value
            samples[frame * 2 + 1] = value
        }

        XCTAssertGreaterThan(buffer.peakAmplitude(), 0.25,
                            "큰 버퍼에서 신호를 전혀 잡지 못했다")
    }
}
