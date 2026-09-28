import AVFoundation
import XCTest
@testable import Scribird

final class FileAudioNormalizerTests: XCTestCase {
    func test_rightChannelOnly_isPreservedInMonoWithOriginalDuration() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "scribird-mono-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appending(path: "stereo.wav")
        let output = root.appending(path: "mono.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 10_000))
        buffer.frameLength = 10_000
        for frame in 0..<10_000 {
            buffer.floatChannelData![0][frame] = 0
            buffer.floatChannelData![1][frame] = 0.5
        }
        func writeInput() throws {
            let file = try AVAudioFile(forWriting: input, settings: format.settings)
            try file.write(from: buffer)
        }
        try writeInput()
        let before = try Data(contentsOf: input)
        let duration = try FileAudioNormalizer.writeMono(source: input, destination: output)
        let file = try AVAudioFile(forReading: output)
        XCTAssertEqual(file.length, 10_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        XCTAssertEqual(duration, 10_000.0 / 48_000.0, accuracy: 0.00001)
        let mono = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 10_000))
        try file.read(into: mono)
        XCTAssertEqual(mono.floatChannelData![0][0], 0.25, accuracy: 0.00001)
        XCTAssertEqual(mono.floatChannelData![0][9999], 0.25, accuracy: 0.00001)
        XCTAssertEqual(try Data(contentsOf: input), before)
    }
}
