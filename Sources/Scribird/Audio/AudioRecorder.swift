import AVFoundation
import AudioToolbox
import Foundation

/// 두 캡처 소스를 녹음 중 공통 시간축의 모노 파일 하나로 합성한다.
///
/// 캡처 콜백에서는 버퍼를 복사해 전용 큐로 넘기기만 한다. 장치별 포맷 변환,
/// 타임라인 정렬, 합성, 디스크 쓰기가 전사 입력을 막아서는 안 된다.
final class AudioRecorder: @unchecked Sendable {
    private static let fileName = "meeting.m4a"
    private static let sampleRate = 48_000.0
    private static let bitRate = 128_000
    private static let blockFrames: Int64 = 960
    /// 서로 다른 장치의 콜백 도착 순서를 흡수하는 저장 지연이다.
    private static let reorderFrames: Int64 = 24_000

    private static let mixFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    )!

    private struct SourceConverter {
        let captureFormat: AVAudioFormat
        let converter: AudioStreamConverter
    }

    private struct Sink {
        let file: AVAudioFile
        let converter: AudioStreamConverter?
    }

    private final class MixBlock {
        var samples = Array(repeating: Float.zero, count: Int(AudioRecorder.blockFrames))
    }

    private var directory: URL
    private var originHostTime: UInt64
    private let queue = DispatchQueue(label: "com.scribird.recorder.mix", qos: .utility)
    private let errorLock = NSLock()

    /// 아래 상태는 모두 `queue`에서만 접근한다.
    private var sink: Sink?
    private var sourceConverters: [Speaker: SourceConverter] = [:]
    private var sourceNextFrame: [Speaker: Int64] = [:]
    private var pendingBlocks: [Int64: MixBlock] = [:]
    private var nextWriteBlock: Int64 = 0
    private var latestEndFrame: Int64 = 0
    private var failed = false

    private var lastError: (any Error)?

    init(
        directory: URL,
        originHostTime: UInt64 = AudioGetCurrentHostTime()
    ) {
        self.directory = directory
        self.originHostTime = originHostTime
    }

    /// 캡처 콜백에서 호출된다. 변환과 파일 쓰기는 저장 전용 큐에서 수행한다.
    func write(
        _ buffer: AVAudioPCMBuffer,
        for speaker: Speaker,
        atHostTime hostTime: UInt64? = nil
    ) {
        guard let copy = buffer.copied() else { return }
        let handoff = OneShotBuffer(copy)
        queue.async { [weak self] in
            guard let self, let buffer = handoff.take() else { return }
            self.writeSync(buffer, for: speaker, atHostTime: hostTime)
        }
    }

    private func writeSync(
        _ buffer: AVAudioPCMBuffer,
        for speaker: Speaker,
        atHostTime hostTime: UInt64?
    ) {
        guard !failed else { return }

        let converter: AudioStreamConverter
        if let existing = sourceConverters[speaker],
           existing.captureFormat == buffer.format {
            converter = existing.converter
        } else {
            guard let replacement = AudioStreamConverter(
                from: buffer.format,
                to: Self.mixFormat
            ) else {
                fail(RecorderError.converterUnavailable(
                    from: buffer.format,
                    to: Self.mixFormat
                ))
                return
            }
            sourceConverters[speaker] = SourceConverter(
                captureFormat: buffer.format,
                converter: replacement
            )
            converter = replacement
        }

        guard let converted = converter.convert(buffer),
              let samples = converted.floatChannelData?[0]
        else { return }

        let startFrame = framePosition(
            for: speaker,
            hostTime: hostTime,
            frameCount: Int64(converted.frameLength)
        )
        add(
            samples: samples,
            frameCount: Int(converted.frameLength),
            at: startFrame
        )

        latestEndFrame = max(latestEndFrame, startFrame + Int64(converted.frameLength))
        flushBlocks(endingAtOrBefore: latestEndFrame - Self.reorderFrames)
    }

    private func framePosition(
        for speaker: Speaker,
        hostTime: UInt64?,
        frameCount: Int64
    ) -> Int64 {
        let start: Int64
        if let hostTime, hostTime > 0 {
            let origin = AVAudioTime.seconds(forHostTime: originHostTime)
            let current = AVAudioTime.seconds(forHostTime: hostTime)
            start = max(0, Int64(((current - origin) * Self.sampleRate).rounded()))
        } else {
            start = sourceNextFrame[speaker] ?? 0
        }
        sourceNextFrame[speaker] = start + frameCount
        return start
    }

    private func add(
        samples: UnsafePointer<Float>,
        frameCount: Int,
        at startFrame: Int64
    ) {
        for index in 0..<frameCount {
            let absoluteFrame = startFrame + Int64(index)
            guard absoluteFrame >= 0 else { continue }
            let block = absoluteFrame / Self.blockFrames
            let offset = Int(absoluteFrame % Self.blockFrames)
            let mixed: MixBlock
            if let existing = pendingBlocks[block] {
                mixed = existing
            } else {
                let created = MixBlock()
                pendingBlocks[block] = created
                mixed = created
            }
            mixed.samples[offset] += samples[index]
        }
    }

    private func flushBlocks(endingAtOrBefore frame: Int64) {
        guard frame > 0 else { return }
        while (nextWriteBlock + 1) * Self.blockFrames <= frame {
            guard writeBlock(nextWriteBlock) else { return }
            nextWriteBlock += 1
        }
    }

    @discardableResult
    private func writeBlock(_ blockIndex: Int64) -> Bool {
        guard !failed else { return false }
        do {
            let sink = try ensureSink()
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: Self.mixFormat,
                frameCapacity: AVAudioFrameCount(Self.blockFrames)
            ), let output = buffer.floatChannelData?[0]
            else {
                throw RecorderError.bufferUnavailable
            }

            buffer.frameLength = AVAudioFrameCount(Self.blockFrames)
            let samples = pendingBlocks.removeValue(forKey: blockIndex)?.samples
                ?? Array(repeating: 0, count: Int(Self.blockFrames))
            for index in samples.indices {
                output[index] = min(1, max(-1, samples[index]))
            }

            let writable: AVAudioPCMBuffer
            if let converter = sink.converter {
                guard let converted = converter.convert(buffer) else {
                    throw RecorderError.converterUnavailable(
                        from: Self.mixFormat,
                        to: sink.file.processingFormat
                    )
                }
                writable = converted
            } else {
                writable = buffer
            }
            try sink.file.write(from: writable)
            return true
        } catch {
            fail(error)
            return false
        }
    }

    private func ensureSink() throws -> Sink {
        if let sink { return sink }

        let url = directory.appending(path: Self.fileName)
        let file: AVAudioFile
        do {
            file = try Self.makeFile(at: url, lossless: false)
        } catch {
            try? FileManager.default.removeItem(at: url)
            file = try Self.makeFile(at: url, lossless: true)
        }

        let converter = file.processingFormat == Self.mixFormat
            ? nil
            : AudioStreamConverter(from: Self.mixFormat, to: file.processingFormat)
        if file.processingFormat != Self.mixFormat, converter == nil {
            throw RecorderError.converterUnavailable(
                from: Self.mixFormat,
                to: file.processingFormat
            )
        }

        let created = Sink(file: file, converter: converter)
        sink = created
        return created
    }

    private static func makeFile(at url: URL, lossless: Bool) throws -> AVAudioFile {
        var settings: [String: Any] = [
            AVFormatIDKey: lossless ? kAudioFormatAppleLossless : kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        if !lossless {
            settings[AVEncoderBitRateKey] = bitRate
        }
        return try AVAudioFile(forWriting: url, settings: settings)
    }

    private func fail(_ error: any Error) {
        failed = true
        pendingBlocks.removeAll()
        errorLock.withLock { lastError = error }
    }

    /// 현재 세션 파일을 닫은 뒤 같은 캡처 스트림을 새 세션 파일로 이어 쓴다.
    func rotate(to newDirectory: URL) -> [URL] {
        queue.sync {
            let finished = finishSync()
            directory = newDirectory
            originHostTime = AudioGetCurrentHostTime()
            resetForNextSession()
            return finished
        }
    }

    /// 큐에 남은 합성과 쓰기를 끝내고 재생 가능한 파일만 반환한다.
    func finish() -> [URL] {
        queue.sync { finishSync() }
    }

    private func finishSync() -> [URL] {
        if !failed, latestEndFrame > 0 {
            let finalBlock = (latestEndFrame + Self.blockFrames - 1) / Self.blockFrames
            while nextWriteBlock < finalBlock {
                guard writeBlock(nextWriteBlock) else { break }
                nextWriteBlock += 1
            }
        }

        let url = sink?.file.url
        sink = nil
        guard let url else { return [] }

        guard (try? AVAudioFile(forReading: url)) != nil else {
            errorLock.withLock {
                lastError = RecorderError.fileNotFinalized(url.lastPathComponent)
            }
            return []
        }
        return [url]
    }

    private func resetForNextSession() {
        sink = nil
        sourceConverters.removeAll()
        sourceNextFrame.removeAll()
        pendingBlocks.removeAll()
        nextWriteBlock = 0
        latestEndFrame = 0
        failed = false
        errorLock.withLock { lastError = nil }
    }

    var storageError: (any Error)? {
        errorLock.withLock { lastError }
    }

    enum RecorderError: LocalizedError {
        case converterUnavailable(from: AVAudioFormat, to: AVAudioFormat)
        case bufferUnavailable
        case fileNotFinalized(String)

        var errorDescription: String? {
            switch self {
            case .converterUnavailable:
                tr("회의 음성을 저장할 형식으로 변환할 수 없습니다.",
                   "Couldn't convert the meeting audio into a format that can be saved.")
            case .bufferUnavailable:
                tr("회의 음성을 합성할 버퍼를 만들 수 없습니다.",
                   "Couldn't create a buffer for the meeting audio mix.")
            case .fileNotFinalized(let name):
                tr("\(name)을 재생 가능한 파일로 마무리하지 못했습니다.",
                   "Couldn't finalize \(name) into a playable file.")
            }
        }
    }
}

extension AVAudioPCMBuffer {
    /// 같은 포맷·같은 길이의 무음 버퍼를 만든다.
    func silentCopy() -> AVAudioPCMBuffer? {
        guard frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength)
        else { return nil }
        copy.frameLength = frameLength

        let source = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }

        for index in 0..<source.count {
            guard let destinationData = destination[index].mData else { return nil }
            let byteCount = min(
                Int(source[index].mDataByteSize),
                Int(destination[index].mDataByteSize)
            )
            memset(destinationData, 0, byteCount)
            destination[index].mDataByteSize = UInt32(byteCount)
        }
        return copy
    }

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
