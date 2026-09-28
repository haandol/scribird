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
    private var sourceTimelines: [Speaker: AudioRecordingTimeline] = [:]
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

        let existing = sourceConverters[speaker]
        var timeline = sourceTimelines[speaker]
            ?? AudioRecordingTimeline(sampleRate: Self.sampleRate)
        let resetConverter = timeline.beginBuffer(
            captureFrame: hostTime.flatMap { $0 > 0 ? captureFrame(at: $0) : nil },
            inputFrames: Int(buffer.frameLength),
            inputSampleRate: buffer.format.sampleRate,
            formatChanged: existing?.captureFormat != buffer.format
        )
        // A converter can consume a tiny input without producing output yet.
        // Keep its capture clock even when convert() returns nil.
        defer { sourceTimelines[speaker] = timeline }

        let converter: AudioStreamConverter
        if let existing, !resetConverter {
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

        let placement = timeline.place(outputFrames: Int(converted.frameLength))
        add(
            samples: samples,
            frameCount: Int(converted.frameLength),
            placement: placement
        )

        latestEndFrame = max(latestEndFrame, placement.startFrame + Int64(placement.frameCount))
        flushBlocks(endingAtOrBefore: latestEndFrame - Self.reorderFrames)
    }

    private func captureFrame(at hostTime: UInt64) -> Double {
        // Subtract ticks before conversion to avoid cancellation after long
        // system uptime. Negative positions are trimmed, not shifted to zero.
        let ticks = hostTime >= originHostTime
            ? hostTime - originHostTime : originHostTime - hostTime
        let frames = AVAudioTime.seconds(forHostTime: ticks) * Self.sampleRate
        return hostTime >= originHostTime ? frames : -frames
    }

    private func add(
        samples: UnsafePointer<Float>,
        frameCount: Int,
        placement: AudioRecordingTimeline.Placement
    ) {
        let discardBefore = max(placement.discardBefore, nextWriteBlock * Self.blockFrames)
        let skippedFrames = max(0, discardBefore - placement.startFrame)
        guard skippedFrames < Int64(placement.frameCount) else { return }

        // Trim the already-written prefix once, then reuse each mix block for
        // the contiguous slice that fits in it. Keep sample arithmetic in order.
        var index = Int(skippedFrames)
        while index < placement.frameCount {
            let absoluteFrame = placement.startFrame + Int64(index)
            let block = absoluteFrame / Self.blockFrames
            let offset = Int(absoluteFrame % Self.blockFrames)
            let count = min(placement.frameCount - index, Int(Self.blockFrames) - offset)
            let mixed: MixBlock
            if let existing = pendingBlocks[block] {
                mixed = existing
            } else {
                let created = MixBlock()
                pendingBlocks[block] = created
                mixed = created
            }
            for localIndex in 0..<count {
                let sourceIndex = index + localIndex
                let destinationIndex = offset + localIndex
                if placement.frameCount == frameCount {
                    mixed.samples[destinationIndex] += samples[sourceIndex]
                } else {
                    let position = Double(sourceIndex) * Double(frameCount) / Double(placement.frameCount)
                    let lower = Int(position)
                    let upper = min(lower + 1, frameCount - 1)
                    let fraction = Float(position - Double(lower))
                    mixed.samples[destinationIndex] += samples[lower] + (samples[upper] - samples[lower]) * fraction
                }
            }
            index += count
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
        sourceTimelines.removeAll()
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
