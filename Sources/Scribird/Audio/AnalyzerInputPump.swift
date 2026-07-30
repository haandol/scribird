import AVFoundation
import CoreMedia
import Foundation
import Speech

/// 레벨을 읽을 수 있는 캡처 소스.
///
/// 두 캡처 경로는 여는 방식만 다르고 레벨은 같은 형태로 내놓는다. 진단(무음 판정·
/// 레벨 미터)이 소스를 구분하지 않고 한 경로로 처리되게 이 프로토콜을 거친다.
protocol AudioLevelSource {
    /// 세션 전체 최대 진폭. 무음(권한 거부) 판정에 쓴다.
    var peakLevel: Float { get }
    /// 미터 표시와 발화 구간 평균의 원천.
    var level: AudioLevelTracker { get }
}

/// 캡처 버퍼를 전사기 입력 스트림으로 흘려보내는 배관.
///
/// 마이크와 시스템 출력은 **여는 방식만** 다르다 — `AVAudioEngine` 탭이냐 Core Audio
/// process tap이냐. 그 뒤의 처리는 같다: 원본을 저장하고, 진폭을 재고, 리샘플링해서
/// 프레임 기준 시각을 붙여 내보낸다. 그 공통 부분을 여기 한 번만 둔다.
///
/// **소스별로 인스턴스를 따로 갖는다.** 두 경로가 서로 독립이라는 불변식은 이 타입을
/// 공유하는 것이 아니라 각자 하나씩 소유하는 것으로 지킨다. 한 소스의 continuation이
/// 끝나도 다른 소스는 계속 흐른다.
///
/// 오디오 콜백에서 호출되므로 상태는 락으로 보호한다.
final class AnalyzerInputPump: @unchecked Sendable {
    private let speaker: Speaker
    private let targetFormat: AVAudioFormat
    private let audioRecorder: AudioRecorder?

    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AudioStreamConverter?
    /// 변환기를 만든 캡처 포맷. 입력 장치가 바뀌면 다시 만들어야 한다.
    private var sourceFormat: AVAudioFormat?
    /// 지금까지 넘긴 프레임 수. 시간축을 프레임 기준으로 쌓는다.
    private var framesSent: AVAudioFramePosition = 0

    /// 입력 레벨. 미터 표시와 무음 감지에 함께 쓴다.
    let level = AudioLevelTracker()

    init(speaker: Speaker, targetFormat: AVAudioFormat, audioRecorder: AudioRecorder?) {
        self.speaker = speaker
        self.targetFormat = targetFormat
        self.audioRecorder = audioRecorder
    }

    func makeInputStream() -> AsyncStream<AnalyzerInput> {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        lock.withLock { self.continuation = continuation }
        return stream
    }

    /// 캡처 포맷을 미리 알 수 있는 경로(process tap)에서 변환기를 앞당겨 만든다.
    ///
    /// - Returns: 그 포맷을 변환할 수 없으면 false. 캡처를 시작하기 전에 알아야
    ///   부분 초기화 상태를 남기지 않는다.
    func prepare(sourceFormat format: AVAudioFormat) -> Bool {
        let converter = AudioStreamConverter(from: format, to: targetFormat)
        lock.withLock {
            self.converter = converter
            self.sourceFormat = format
        }
        return converter != nil
    }

    /// 스트림을 닫는다. 캡처가 멈춘 뒤에 호출해야 분석기가 마무리에 들어간다.
    func finish() {
        let continuation = lock.withLock {
            let current = self.continuation
            self.continuation = nil
            return current
        }
        continuation?.finish()
    }

    /// 세션 전체 최대 진폭. 0에 가까우면 소리가 없거나 권한이 없다는 뜻.
    ///
    /// macOS는 권한이 거부돼도 콜백을 그대로 보내고 내용만 0으로 채운다. 그래서
    /// "콜백이 온다"만으로는 정상 동작을 판단할 수 없다.
    var peakLevel: Float { level.sessionPeak }

    /// 캡처 콜백에서 받은 버퍼 하나를 처리한다.
    ///
    /// 캡처 포맷이 바뀌면 변환기를 다시 만든다 — 입력 장치를 갈아 끼우면 마이크
    /// 경로에서 실제로 일어난다.
    func submit(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }

        // 원본 저장은 리샘플링 전에 한다. 16kHz 모노로 줄인 뒤 저장하면 재처리
        // 가치가 사라진다.
        audioRecorder?.write(buffer, for: speaker)

        lock.lock()
        if sourceFormat != buffer.format {
            converter = AudioStreamConverter(from: buffer.format, to: targetFormat)
            sourceFormat = buffer.format
        }
        let converter = self.converter
        let continuation = self.continuation
        let startFrame = framesSent
        lock.unlock()

        // 인터리브 배치는 소스와 장치에 따라 다르다. peakAmplitude()가 형식을 보고
        // 알맞게 읽는다. 자체 락을 쓰므로 위 락 밖에서 호출한다.
        level.submit(peak: buffer.peakAmplitude())

        guard let converter, let continuation,
              let converted = converter.convert(buffer)
        else { return }

        // 시간축은 넘긴 프레임 수로 쌓는다. hostTime을 쓰면 장치 지연이 섞인다.
        let startTime = CMTime(
            value: startFrame,
            timescale: CMTimeScale(targetFormat.sampleRate)
        )
        lock.withLock { framesSent += AVAudioFramePosition(converted.frameLength) }

        continuation.yield(AnalyzerInput(buffer: converted, bufferStartTime: startTime))
    }
}
