import AVFoundation
import CoreMedia
import Speech
import XCTest
@testable import Scribird

/// 캡처 배관 테스트.
///
/// 이 코드는 마이크와 시스템 출력이 **함께 쓴다**. 한쪽을 고치려다 깨면 두 소스가
/// 동시에 망가지므로, 소스별 클래스에 흩어져 있던 때보다 오히려 테스트가 더 필요하다.
///
/// 하드웨어는 쓰지 않는다 — 버퍼를 직접 만들어 넣고 나오는 결과를 본다.
final class AnalyzerInputPumpTests: XCTestCase {

    /// 전사기가 요구하는 형식. 실제 파이프라인과 같은 16kHz 모노다.
    private var targetFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                      channels: 1, interleaved: false)!
    }

    /// 캡처 원본으로 흔한 48kHz 스테레오.
    private func captureFormat(
        sampleRate: Double = 48000,
        channels: AVAudioChannelCount = 2,
        interleaved: Bool = true
    ) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                      channels: channels, interleaved: interleaved)!
    }

    /// 일정 진폭으로 채운 버퍼.
    private func buffer(
        _ format: AVAudioFormat,
        frames: AVAudioFrameCount,
        amplitude: Float
    ) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channels = Int(format.channelCount)
        let samples = buffer.floatChannelData!
        if format.isInterleaved {
            for index in 0..<(Int(frames) * channels) { samples[0][index] = amplitude }
        } else {
            for channel in 0..<channels {
                for frame in 0..<Int(frames) { samples[channel][frame] = amplitude }
            }
        }
        return buffer
    }

    private func pump(speaker: Speaker = .me) -> AnalyzerInputPump {
        AnalyzerInputPump(speaker: speaker, targetFormat: targetFormat, audioRecorder: nil)
    }

    /// 스트림에서 지정 개수만큼 받아 온다. 끝나면 받은 것까지만 돌려준다.
    private func collect(
        _ stream: AsyncStream<AnalyzerInput>,
        count: Int
    ) async -> [AnalyzerInput] {
        var received: [AnalyzerInput] = []
        for await input in stream {
            received.append(input)
            if received.count == count { break }
        }
        return received
    }

    // MARK: - 시간축 (프레임 누적)

    /// 각 버퍼의 시작 시각이 **앞서 넘긴 프레임 수**로 정해져야 한다.
    ///
    /// hostTime을 쓰면 장치 지연이 섞여 두 소스의 시간축이 서로 어긋난다. 그래서
    /// 넘긴 프레임을 누적해 쓴다. 이 값이 세그먼트 시각의 근거이므로, 틀리면 회의록
    /// 타임코드 전체가 밀린다.
    ///
    /// 간격을 고정값으로 못박지 않는다. 실측하면 4800 입력 프레임이 1600이 아니라
    /// 1360~1366으로 나온다 — 리샘플러 내부 지연 때문에 초반에 덜 내놓고 시간이
    /// 지나며 따라잡는다. 같은 조건으로 측정한 수렴 곡선:
    ///
    /// ```
    ///  10버퍼( 1초): 0.9316초  오차 6.84%
    ///  50버퍼( 5초): 4.9741초  오차 0.52%
    /// 200버퍼(20초): 19.9759초 오차 0.12%
    /// ```
    ///
    /// 회의는 분 단위이므로 이 오차는 실사용에 영향이 없다. 그래서 고정 간격이 아니라
    /// **누적 방식 자체**를 검증한다: 0에서 시작하고, 단조증가하며, 충분한 길이에서
    /// 실제 오디오 시간에 수렴할 것. 50버퍼를 쓰는 것은 위 표에서 0.5% 안으로
    /// 들어오는 첫 지점이기 때문이다.
    func test_bufferStartTimes_accumulateByFramesSent() async {
        let pump = pump()
        let stream = pump.makeInputStream()
        let format = captureFormat()

        // 버퍼 하나가 0.1초(48kHz에서 4800 프레임)다. 50개면 5초.
        let count = 50
        for _ in 0..<count {
            pump.submit(buffer(format, frames: 4800, amplitude: 0.5))
        }
        let received = await collect(stream, count: count)

        XCTAssertEqual(received.count, count, "넣은 버퍼가 스트림에 다 오지 않았다")

        let starts = received.compactMap { $0.bufferStartTime?.seconds }
        XCTAssertEqual(starts.count, count, "시작 시각이 붙지 않은 버퍼가 있다")

        XCTAssertEqual(starts[0], 0, accuracy: 0.001,
                       "첫 버퍼가 0이 아니면 회의록이 0부터 시작하지 않는다")

        // 시각이 뒤로만 가야 한다. 누적을 빼먹으면 전부 0에 머물러 발화가 겹친다.
        for index in 1..<starts.count {
            XCTAssertGreaterThan(starts[index], starts[index - 1],
                                 "시각이 누적되지 않았다 — 모든 발화가 같은 지점에 쌓인다")
        }

        // 마지막 버퍼의 시작은 앞선 49개 길이(4.9초)에 수렴해야 한다.
        let expected = Double(count - 1) * 0.1
        XCTAssertEqual(starts[count - 1], expected, accuracy: expected * 0.01,
                       "누적 시각이 실제 오디오 길이에서 벗어났다 — 타임코드가 밀린다")
    }

    /// 시각의 timescale이 목표 샘플레이트여야 한다.
    ///
    /// 캡처 샘플레이트로 매기면 리샘플링 후 프레임 수와 단위가 어긋나 시각이 3배
    /// 틀어진다(48k vs 16k).
    func test_bufferStartTime_usesTargetSampleRateAsTimescale() async {
        let pump = pump()
        let stream = pump.makeInputStream()

        pump.submit(buffer(captureFormat(), frames: 4800, amplitude: 0.5))
        pump.submit(buffer(captureFormat(), frames: 4800, amplitude: 0.5))
        let received = await collect(stream, count: 2)

        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[1].bufferStartTime?.timescale, 16000,
                       "timescale이 목표 샘플레이트가 아니면 시각이 배수로 틀어진다")
    }

    // MARK: - 리샘플링

    func test_submit_convertsToTargetFormat() async {
        let pump = pump()
        let stream = pump.makeInputStream()

        pump.submit(buffer(captureFormat(), frames: 4800, amplitude: 0.5))
        let received = await collect(stream, count: 1)

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].buffer.format.sampleRate, 16000)
        XCTAssertEqual(received[0].buffer.format.channelCount, 1,
                       "스테레오가 모노로 합쳐지지 않았다")
    }

    /// 캡처 포맷이 도중에 바뀌면 변환기를 다시 만들어야 한다.
    ///
    /// 입력 장치를 갈아 끼우면 실제로 일어난다. 변환기를 그대로 쓰면 이후 버퍼가
    /// 전부 버려져 그 소스의 전사가 조용히 멈춘다.
    func test_submit_rebuildsConverterWhenCaptureFormatChanges() async {
        let pump = pump()
        let stream = pump.makeInputStream()

        pump.submit(buffer(captureFormat(sampleRate: 48000), frames: 4800, amplitude: 0.5))
        // 장치 전환: 44.1kHz 모노로 바뀐다.
        pump.submit(
            buffer(captureFormat(sampleRate: 44100, channels: 1, interleaved: false),
                   frames: 4410, amplitude: 0.5)
        )
        let received = await collect(stream, count: 2)

        XCTAssertEqual(received.count, 2,
                       "포맷이 바뀐 뒤 버퍼가 버려졌다 — 장치 전환 후 전사가 멈춘다")
        XCTAssertTrue(received.allSatisfy { $0.buffer.format.sampleRate == 16000 })
    }

    // MARK: - 레벨 측정

    /// 진폭은 **리샘플링 전** 원본에서 재야 한다.
    ///
    /// 미터와 무음 판정이 이 값을 쓴다. 변환 후 버퍼에서 재면 채널 병합으로 값이
    /// 달라져 권한 판정 기준(0.0005)과 어긋난다.
    func test_submit_tracksLevelFromCaptureBuffer() {
        let pump = pump()
        _ = pump.makeInputStream()

        pump.submit(buffer(captureFormat(), frames: 4800, amplitude: 0.5))

        XCTAssertEqual(pump.peakLevel, 0.5, accuracy: 0.01,
                       "원본 진폭이 그대로 잡히지 않았다")
    }

    /// 무음 버퍼는 무음으로 기록돼야 한다. 권한 거부 감지의 전제다.
    func test_submit_silentBufferLeavesPeakAtZero() {
        let pump = pump()
        _ = pump.makeInputStream()

        // 실측된 권한 거부 상태: 콜백은 오지만 내용이 전부 0이다.
        for _ in 0..<10 {
            pump.submit(buffer(captureFormat(), frames: 4800, amplitude: 0))
        }

        XCTAssertLessThan(pump.peakLevel, SilenceCriteria.threshold,
                          "무음 콜백을 무음으로 읽지 못하면 권한 거부를 놓친다")
    }

    /// 인터리브 배치의 진폭도 정확히 읽어야 한다. process tap이 주는 형식이다.
    func test_submit_readsInterleavedCaptureBuffer() {
        let pump = pump(speaker: .remote)
        _ = pump.makeInputStream()

        let format = captureFormat(interleaved: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        let samples = buffer.floatChannelData![0]
        // L은 조용하고 R에만 신호가 있다. 배치를 잘못 읽으면 놓친다.
        for frame in 0..<4800 {
            samples[frame * 2] = 0.001
            samples[frame * 2 + 1] = 0.8
        }

        pump.submit(buffer)

        XCTAssertEqual(pump.peakLevel, 0.8, accuracy: 0.01,
                       "인터리브 배치에서 신호를 놓쳤다 — 시스템 오디오가 무음으로 오진된다")
    }

    // MARK: - 경계 조건

    func test_submit_ignoresEmptyBuffer() {
        let pump = pump()
        _ = pump.makeInputStream()

        pump.submit(buffer(captureFormat(), frames: 0, amplitude: 0.5))

        XCTAssertEqual(pump.peakLevel, 0)
    }

    /// 스트림을 열기 전에 온 버퍼도 레벨은 잡아야 한다.
    ///
    /// 캡처가 먼저 뜨고 전사 세션이 붙는 순서라 실제로 생긴다. 레벨을 놓치면 시작
    /// 직후 구간이 무음 판정에서 빠진다.
    func test_submit_beforeStreamExists_stillTracksLevel() {
        let pump = pump()

        pump.submit(buffer(captureFormat(), frames: 4800, amplitude: 0.6))

        XCTAssertEqual(pump.peakLevel, 0.6, accuracy: 0.01)
    }

    /// `finish()` 후에는 스트림이 끝나야 한다.
    ///
    /// 이것이 닫히지 않으면 분석기가 입력을 계속 기다려 마무리에 들어가지 않고,
    /// 회의록 저장이 제한 시간까지 매달린다.
    func test_finish_terminatesStream() async {
        let pump = pump()
        let stream = pump.makeInputStream()

        pump.submit(buffer(captureFormat(), frames: 4800, amplitude: 0.5))
        pump.finish()

        var count = 0
        for await _ in stream { count += 1 }

        // 넣은 것까지는 받고, 그 뒤로 끝난다 — 루프가 반환된 것이 종료의 증거다.
        XCTAssertLessThanOrEqual(count, 1)
    }

    /// 한 pump의 종료가 다른 pump에 영향을 주지 않아야 한다.
    ///
    /// **두 캡처 경로 독립**이 배관을 공유하면서도 지켜지는지 확인한다. 소스별로
    /// 인스턴스를 따로 갖는 것이 그 근거다.
    func test_twoPumps_areIndependent() async {
        let microphone = pump(speaker: .me)
        let systemAudio = pump(speaker: .remote)
        let microphoneStream = microphone.makeInputStream()
        _ = systemAudio.makeInputStream()

        // 마이크 쪽만 닫는다.
        microphone.finish()

        // 시스템 오디오는 계속 흘러야 한다.
        systemAudio.submit(buffer(captureFormat(), frames: 4800, amplitude: 0.7))

        XCTAssertEqual(systemAudio.peakLevel, 0.7, accuracy: 0.01,
                       "한 소스를 닫으니 다른 소스도 멈췄다")
        XCTAssertEqual(microphone.peakLevel, 0, accuracy: 0.0001)

        var microphoneCount = 0
        for await _ in microphoneStream { microphoneCount += 1 }
        XCTAssertEqual(microphoneCount, 0)
    }

    // MARK: - prepare (process tap 경로)

    func test_prepare_acceptsKnownCaptureFormat() {
        let pump = pump(speaker: .remote)

        XCTAssertTrue(pump.prepare(sourceFormat: captureFormat()),
                      "흔한 탭 포맷을 변환할 수 없다고 보고했다")
    }

    /// 미리 준비한 변환기로 첫 버퍼부터 바로 흘려보내야 한다.
    func test_prepare_thenSubmit_yieldsImmediately() async {
        let pump = pump(speaker: .remote)
        let stream = pump.makeInputStream()
        let format = captureFormat()

        XCTAssertTrue(pump.prepare(sourceFormat: format))
        pump.submit(buffer(format, frames: 4800, amplitude: 0.5))
        let received = await collect(stream, count: 1)

        XCTAssertEqual(received.count, 1, "미리 준비했는데 첫 버퍼가 흐르지 않았다")
    }
}
