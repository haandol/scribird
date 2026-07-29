import AVFoundation
import CoreMedia
import Foundation
import Speech

/// 마이크를 `AVAudioEngine`으로 직접 캡처한다.
///
/// 시스템 출력 캡처(`SystemAudioCapture`)와 완전히 독립된 경로다. 한쪽 권한이
/// 없어도 다른 쪽은 계속 돌아간다. 마이크는 마이크 권한만 필요하므로 회의 앱이
/// 없어도, 오디오 캡처 권한이 없어도 혼자 말하는 것이 바로 전사된다.
final class MicrophoneCapture: @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case noInputDevice
        case permissionDenied
        case engineFailed(any Error)

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                "사용할 수 있는 마이크를 찾지 못했습니다. 시스템 설정 > 사운드에서 입력 장치를 확인해 주세요."
            case .permissionDenied:
                "마이크 권한이 필요합니다. 시스템 설정 > 개인정보 보호 및 보안 > 마이크에서 Scribird를 허용해 주세요."
            case .engineFailed(let error):
                "마이크를 열 수 없습니다: \(error.localizedDescription)"
            }
        }
    }

    private let engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat
    private let audioRecorder: AudioRecorder?
    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AudioStreamConverter?
    private var lastInputFormat: AVAudioFormat?
    /// 마이크 타임라인의 원점. 첫 버퍼가 도착한 시점으로 잡는다.
    private var startHostTime: UInt64?
    /// 지금까지 넘긴 프레임 수. 시간축을 프레임 기준으로 쌓는다.
    private var framesSent: AVAudioFramePosition = 0
    /// 실제로 소리가 들어왔는지. 무음만 오면 권한 거부를 의심할 근거가 된다.
    private var observedPeak: Float = 0

    init(targetFormat: AVAudioFormat, audioRecorder: AudioRecorder?) {
        self.targetFormat = targetFormat
        self.audioRecorder = audioRecorder
    }

    /// 마이크 권한을 확인하고 필요하면 요청한다.
    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func makeInputStream() -> AsyncStream<AnalyzerInput> {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        lock.withLock { self.continuation = continuation }
        return stream
    }

    func start() throws {
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)

        // 입력 장치가 없으면 샘플레이트가 0으로 온다.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            self?.handle(buffer, at: time)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineFailed(error)
        }
    }

    func stop() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        let continuation = lock.withLock {
            let current = self.continuation
            self.continuation = nil
            return current
        }
        continuation?.finish()
    }

    /// 캡처된 소리의 최대 진폭. 0에 가까우면 권한 거부를 의심한다.
    ///
    /// macOS는 마이크 권한이 거부돼도 콜백은 그대로 보내고 내용만 0으로 채운다.
    /// 그래서 "콜백이 온다"만으로는 정상 동작을 판단할 수 없다.
    var peakLevel: Float {
        lock.withLock { observedPeak }
    }

    private func handle(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard buffer.frameLength > 0 else { return }

        // 원본 저장은 리샘플링 전에 한다.
        audioRecorder?.write(buffer, for: .me)

        lock.lock()
        if startHostTime == nil {
            startHostTime = time.hostTime
        }
        if lastInputFormat != buffer.format {
            converter = AudioStreamConverter(from: buffer.format, to: targetFormat)
            lastInputFormat = buffer.format
        }
        let converter = self.converter
        let continuation = self.continuation
        let startFrame = framesSent

        // 무음 여부를 판단할 진폭. 입력 장치에 따라 인터리브 배치가 다를 수 있어
        // peakAmplitude()가 형식을 보고 알맞게 읽는다.
        observedPeak = max(observedPeak, buffer.peakAmplitude())
        lock.unlock()

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
