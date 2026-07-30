import AVFoundation
import Foundation

/// 캡처된 오디오 원본을 소스별 파일로 남긴다.
///
/// 소스를 섞지 않고 `me.m4a` / `remote.m4a`로 따로 저장하는 이유:
/// 나중에 다른 STT로 다시 돌리거나 화자분리 모델을 붙일 때 화자 정보가
/// 보존된 상태로 재사용할 수 있다. 섞어 버리면 그 정보가 영구히 사라진다.
///
/// 전사 파이프라인과 같은 버퍼를 공유하되 별도 큐에서 쓴다. 디스크 I/O가
/// 캡처 콜백을 막으면 오디오가 드롭되기 때문이다.
final class AudioRecorder: @unchecked Sendable {
    /// AAC(.m4a)로 저장한다.
    ///
    /// mp3가 아닌 이유: Apple은 mp3 **디코딩**만 지원하고 인코딩은 지원하지 않는다.
    /// 실측 시 `kAudioFormatMPEGLayer3`로 파일을 만들면 `'fmt?'`
    /// (kAudioFormatUnsupportedDataFormatError)로 실패한다. mp3로 쓰려면 LAME 같은
    /// 외부 인코더를 번들에 넣어야 하는데, 의존성 없는 온디바이스 앱이라는 성격에
    /// 맞지 않는다. AAC는 같은 비트레이트에서 mp3보다 음질이 좋고 OS가 직접 지원한다.
    private static let fileExtension = "m4a"

    /// 채널당 AAC 비트레이트.
    ///
    /// 64k가 아니라 128k인 이유: 이 파일의 실제 용도는 재전사다. 64k로 저장한
    /// 음성을 다시 전사하면 오인식이 생겼다 — `배포 일정` → `대포 일정`.
    /// 128k와 무손실(ALAC)은 원문과 완전히 일치했다.
    ///
    /// 모노 1시간이 약 54MB다. 저장 공간보다 재처리 정확도가 중요하다고 봤다.
    private static let bitRatePerChannel = 128_000

    /// 소스 하나에 대응하는 출력 파일과 포맷 변환기.
    private struct Sink {
        let file: AVAudioFile
        /// 캡처 포맷과 파일의 `processingFormat`을 잇는 변환기.
        /// `AVAudioFile.write(from:)`은 `processingFormat`과 정확히 같은 버퍼만
        /// 받는다. 캡처 포맷은 그와 다를 수 있으므로 반드시 거친다.
        let converter: AudioStreamConverter?
        let captureFormat: AVAudioFormat
    }

    private var directory: URL
    private let queue = DispatchQueue(label: "com.scribird.recorder.write", qos: .utility)
    private let lock = NSLock()
    private var sinks: [Speaker: Sink] = [:]
    /// 파일 생성이나 변환기 준비에 실패한 소스. 재시도하지 않는다.
    private var failedSpeakers: Set<Speaker> = []
    /// 마지막으로 발생한 쓰기 오류. 세션 종료 시 보고한다.
    private var lastError: (any Error)?

    init(directory: URL) {
        self.directory = directory
    }

    /// 캡처 콜백에서 호출된다. 논블로킹이어야 하므로 쓰기는 큐에 넘긴다.
    ///
    /// - Parameter buffer: 리샘플링 **이전** 원본 버퍼를 넘기는 것이 좋다.
    ///   16kHz 모노로 줄인 뒤 저장하면 나중에 쓸 수 있는 정보가 줄어든다.
    func write(_ buffer: AVAudioPCMBuffer, for speaker: Speaker) {
        // 캡처 콜백이 끝나면 버퍼가 재사용될 수 있으니 복사해서 큐에 넘긴다.
        // AVAudioPCMBuffer는 Sendable이 아니므로 전용 상자에 담아 소유권을 옮긴다.
        guard let copy = buffer.copied() else { return }
        let handoff = BufferHandoff(buffer: copy)
        queue.async { [weak self] in
            guard let self, let buffer = handoff.take() else { return }
            self.writeSync(buffer, for: speaker)
        }
    }

    private func writeSync(_ buffer: AVAudioPCMBuffer, for speaker: Speaker) {
        lock.lock()
        if failedSpeakers.contains(speaker) {
            lock.unlock()
            return
        }
        var sink = sinks[speaker]
        lock.unlock()

        // 캡처 포맷이 바뀌면(입력 장치 전환 등) 변환기를 다시 만들어야 한다.
        if let existing = sink, existing.captureFormat != buffer.format {
            sink = Self.remakeConverter(for: existing, captureFormat: buffer.format)
            if let sink {
                lock.withLock { sinks[speaker] = sink }
            } else {
                lock.withLock { _ = failedSpeakers.insert(speaker) }
                return
            }
        }

        if sink == nil {
            // 첫 버퍼가 도착한 시점에 그 포맷으로 파일을 만든다. 캡처 포맷을
            // 미리 알 수 없으므로 지연 생성이 필요하다.
            do {
                sink = try makeSink(captureFormat: buffer.format, speaker: speaker)
            } catch {
                lock.withLock {
                    _ = failedSpeakers.insert(speaker)
                    lastError = error
                }
                return
            }
            lock.withLock { sinks[speaker] = sink }
        }

        guard let sink else { return }

        // 파일이 요구하는 포맷으로 맞춘 뒤에 쓴다.
        let writable: AVAudioPCMBuffer
        if let converter = sink.converter {
            guard let converted = converter.convert(buffer) else { return }
            writable = converted
        } else {
            writable = buffer
        }

        do {
            try sink.file.write(from: writable)
        } catch {
            // 매 버퍼마다 로그를 쏟지 않도록 마지막 오류만 남긴다.
            lock.withLock { lastError = error }
        }
    }

    private func makeSink(captureFormat: AVAudioFormat, speaker: Speaker) throws -> Sink {
        // 경계에서 디렉터리가 바뀔 수 있으므로 락 안에서 읽는다.
        let directory = lock.withLock { self.directory }
        let url = directory.appending(path: "\(speaker.rawValue).\(Self.fileExtension)")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: captureFormat.sampleRate,
            AVNumberOfChannelsKey: captureFormat.channelCount,
            AVEncoderBitRateKey: Self.bitRatePerChannel * Int(captureFormat.channelCount),
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)

        // processingFormat은 보통 Float32 디인터리브드다. 캡처가 Int16
        // 인터리브드로 오면 그대로 쓰면 -50 오류가 난다.
        let needsConversion = file.processingFormat != captureFormat
        let converter = needsConversion
            ? AudioStreamConverter(from: captureFormat, to: file.processingFormat)
            : nil
        if needsConversion, converter == nil {
            throw RecorderError.converterUnavailable(from: captureFormat, to: file.processingFormat)
        }

        return Sink(file: file, converter: converter, captureFormat: captureFormat)
    }

    private static func remakeConverter(for sink: Sink, captureFormat: AVAudioFormat) -> Sink? {
        guard sink.file.processingFormat != captureFormat else {
            return Sink(file: sink.file, converter: nil, captureFormat: captureFormat)
        }
        guard let converter = AudioStreamConverter(
            from: captureFormat,
            to: sink.file.processingFormat
        ) else { return nil }
        return Sink(file: sink.file, converter: converter, captureFormat: captureFormat)
    }

    /// 지금까지의 파일을 마무리하고, 이후 버퍼를 새 디렉터리에 쓰기 시작한다.
    ///
    /// 세션 경계에서 쓰인다. 캡처는 끊기지 않으므로 콜백은 계속 들어오는데, 그
    /// 버퍼가 가야 할 파일만 바뀐다. 실패한 소스 표시와 누적 오류도 함께 비워
    /// 새 세션이 이전 세션의 실패를 물려받지 않게 한다.
    ///
    /// - Returns: 닫힌 세션의 재생 가능한 오디오 파일 경로들.
    func rotate(to newDirectory: URL) -> [URL] {
        let finished = finish()
        lock.withLock {
            directory = newDirectory
            failedSpeakers.removeAll()
            lastError = nil
        }
        return finished
    }

    /// 큐에 남은 쓰기를 모두 끝내고 파일을 닫는다.
    ///
    /// - Returns: 실제로 재생 가능한 오디오 파일 경로들.
    func finish() -> [URL] {
        // 큐를 동기로 비워 마지막 버퍼까지 디스크에 안착시킨다.
        queue.sync {}

        let urls: [URL] = lock.withLock {
            let collected = sinks.values.map(\.file.url)
            // AVAudioFile은 마지막 참조가 사라질 때 컨테이너를 닫고 moov atom을
            // 쓴다. 이걸 놓치면 데이터는 있어도 열 수 없는 파일이 남는다.
            sinks.removeAll()
            return collected
        }

        // 실제로 열리는지 확인한다. 여기서 걸러야 "저장했다"는 보고가 정직해진다.
        var valid: [URL] = []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if (try? AVAudioFile(forReading: url)) != nil {
                valid.append(url)
            } else {
                lock.withLock {
                    lastError = RecorderError.fileNotFinalized(url.lastPathComponent)
                }
            }
        }
        return valid
    }

    /// 세션 중 발생한 마지막 저장 오류. UI에서 경고를 띄우는 데 쓴다.
    var storageError: (any Error)? {
        lock.withLock { lastError }
    }

    enum RecorderError: LocalizedError {
        case converterUnavailable(from: AVAudioFormat, to: AVAudioFormat)
        case fileNotFinalized(String)

        var errorDescription: String? {
            switch self {
            case .converterUnavailable:
                "오디오 원본을 저장할 형식으로 변환할 수 없습니다."
            case .fileNotFinalized(let name):
                "\(name)을 재생 가능한 파일로 마무리하지 못했습니다."
            }
        }
    }
}

/// 논-Sendable 버퍼를 큐 경계 너머로 한 번만 넘기는 상자.
///
/// 캡처 스레드가 복사본을 만들어 넣고 쓰기 큐가 꺼내 간다. 두 곳이 동시에
/// 같은 버퍼를 만지지 않는다는 것이 `take()`의 1회성으로 보장된다.
private final class BufferHandoff: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        lock.withLock {
            defer { buffer = nil }
            return buffer
        }
    }
}

extension AVAudioPCMBuffer {
    /// 같은 포맷·같은 내용의 독립 버퍼를 만든다.
    func copied() -> AVAudioPCMBuffer? {
        guard frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength)
        else { return nil }
        copy.frameLength = frameLength

        let source = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }

        for index in 0..<source.count {
            guard let sourceData = source[index].mData,
                  let destinationData = destination[index].mData
            else { return nil }
            let byteCount = min(
                Int(source[index].mDataByteSize),
                Int(destination[index].mDataByteSize)
            )
            memcpy(destinationData, sourceData, byteCount)
            destination[index].mDataByteSize = UInt32(byteCount)
        }
        return copy
    }
}
