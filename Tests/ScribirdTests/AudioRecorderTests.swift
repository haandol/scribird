import AVFoundation
import XCTest
@testable import Scribird

final class AudioRecorderTests: XCTestCase {
    func test_write_deviceFormats_savesSinglePlayableMonoAACAtFixedFormat() throws {
        let formats: [(Double, AVAudioChannelCount, Bool)] = [
            (16_000, 1, false),
            (22_050, 1, false),
            (24_000, 2, true),
            (32_000, 1, false),
            (44_100, 2, false),
            (48_000, 2, true),
            (96_000, 2, false),
        ]

        for (sampleRate, channels, interleaved) in formats {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let recorder = AudioRecorder(directory: directory)
            let source = try XCTUnwrap(
                buffer(
                    sampleRate: sampleRate,
                    channels: channels,
                    interleaved: interleaved,
                    amplitude: 0.25
                )
            )
            let repetitions = sampleRate == 24_000 || sampleRate == 96_000 ? 300 : 20
            for _ in 0..<repetitions {
                recorder.write(source, for: .remote)
            }

            let files = recorder.finish()

            XCTAssertNil(recorder.storageError, "\(sampleRate)Hz 저장 실패")
            XCTAssertEqual(files.map(\.lastPathComponent), ["meeting.m4a"])
            let file = try AVAudioFile(forReading: try XCTUnwrap(files.first))
            XCTAssertEqual(file.fileFormat.sampleRate, 48_000)
            XCTAssertEqual(file.fileFormat.channelCount, 1)
            XCTAssertEqual(
                file.fileFormat.streamDescription.pointee.mFormatID,
                kAudioFormatMPEG4AAC
            )
            XCTAssertGreaterThan(file.length, 0)
        }
    }

    func test_write_twoSourcesAtSameHostTime_mixesThemIntoOneFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let origin = AVAudioTime.hostTime(forSeconds: 100)
        let recorder = AudioRecorder(directory: directory, originHostTime: origin)
        let microphone = try XCTUnwrap(
            buffer(sampleRate: 48_000, channels: 1, amplitude: 0.2)
        )
        let systemAudio = try XCTUnwrap(
            buffer(sampleRate: 48_000, channels: 2, amplitude: 0.3)
        )

        recorder.write(microphone, for: .me, atHostTime: origin)
        recorder.write(systemAudio, for: .remote, atHostTime: origin)

        let decoded = try decodedBuffer(from: try XCTUnwrap(recorder.finish().first))
        XCTAssertGreaterThan(decoded.peakAmplitude(), 0.35,
                             "동시 발화가 한쪽 소리만 남았다")
    }

    func test_write_mutedMicrophone_keepsSystemAudioInMeetingFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let origin = AVAudioTime.hostTime(forSeconds: 100)
        let recorder = AudioRecorder(directory: directory, originHostTime: origin)
        let microphone = try XCTUnwrap(
            buffer(sampleRate: 48_000, channels: 1, amplitude: 0.8)
        )
        let systemAudio = try XCTUnwrap(
            buffer(sampleRate: 48_000, channels: 1, amplitude: 0.4)
        )

        recorder.write(
            try XCTUnwrap(microphone.silentCopy()),
            for: .me,
            atHostTime: origin
        )
        recorder.write(systemAudio, for: .remote, atHostTime: origin)

        let decoded = try decodedBuffer(from: try XCTUnwrap(recorder.finish().first))
        XCTAssertGreaterThan(decoded.peakAmplitude(), 0.2,
                             "마이크 음소거가 시스템 오디오까지 지웠다")
        XCTAssertLessThan(decoded.peakAmplitude(), 0.65,
                          "음소거된 마이크 내용이 합본에 남았다")
    }

    func test_write_hostTimeGap_preservesSilenceBetweenBuffers() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let originSeconds = 100.0
        let origin = AVAudioTime.hostTime(forSeconds: originSeconds)
        let recorder = AudioRecorder(directory: directory, originHostTime: origin)
        let source = try XCTUnwrap(
            buffer(sampleRate: 48_000, channels: 1, amplitude: 0.3)
        )

        recorder.write(source, for: .remote, atHostTime: origin)
        recorder.write(
            source,
            for: .remote,
            atHostTime: AVAudioTime.hostTime(forSeconds: originSeconds + 0.5)
        )

        let file = try AVAudioFile(forReading: try XCTUnwrap(recorder.finish().first))
        XCTAssertGreaterThanOrEqual(
            file.length,
            AVAudioFramePosition(48_000 * 0.55),
            "콜백 사이의 실제 공백이 제거됐다"
        )
    }

    func test_write_captureFormatChanges_finishesPlayableMeetingFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = AudioRecorder(directory: directory)

        for sampleRate in [48_000.0, 24_000.0, 96_000.0, 48_000.0] {
            let source = try XCTUnwrap(
                buffer(sampleRate: sampleRate, channels: 2, amplitude: 0.25)
            )
            for _ in 0..<20 {
                recorder.write(source, for: .remote)
            }
        }

        let url = try XCTUnwrap(recorder.finish().first)
        let file = try AVAudioFile(forReading: url)
        XCTAssertNil(recorder.storageError)
        XCTAssertEqual(url.lastPathComponent, "meeting.m4a")
        XCTAssertEqual(file.fileFormat.sampleRate, 48_000)
        XCTAssertGreaterThan(file.length, 0)
    }

    func test_rotate_finishesEachMeetingFileBeforeChangingDirectory() throws {
        let firstDirectory = try temporaryDirectory()
        let secondDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstDirectory)
            try? FileManager.default.removeItem(at: secondDirectory)
        }
        let recorder = AudioRecorder(directory: firstDirectory)
        let source = try XCTUnwrap(
            buffer(sampleRate: 48_000, channels: 1, amplitude: 0.3)
        )

        recorder.write(source, for: .me)
        let firstFiles = recorder.rotate(to: secondDirectory)
        recorder.write(source, for: .remote)
        let secondFiles = recorder.finish()

        XCTAssertEqual(firstFiles.map(\.lastPathComponent), ["meeting.m4a"])
        XCTAssertEqual(secondFiles.map(\.lastPathComponent), ["meeting.m4a"])
        XCTAssertNoThrow(try AVAudioFile(forReading: try XCTUnwrap(firstFiles.first)))
        XCTAssertNoThrow(try AVAudioFile(forReading: try XCTUnwrap(secondFiles.first)))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "scribird-audio-recorder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func decodedBuffer(from url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            )
        )
        try file.read(into: buffer)
        return buffer
    }

    private func buffer(
        sampleRate: Double,
        channels: AVAudioChannelCount,
        interleaved: Bool = false,
        amplitude: Float
    ) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: interleaved
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(sampleRate / 10)
        ) else { return nil }

        buffer.frameLength = buffer.frameCapacity
        guard let samples = buffer.floatChannelData else { return nil }
        if interleaved {
            for frame in 0..<Int(buffer.frameLength) {
                for channel in 0..<Int(channels) {
                    samples[0][frame * Int(channels) + channel] = amplitude
                }
            }
        } else {
            for channel in 0..<Int(channels) {
                for frame in 0..<Int(buffer.frameLength) {
                    samples[channel][frame] = amplitude
                }
            }
        }
        return buffer
    }
}
