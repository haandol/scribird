import Foundation
import XCTest
@testable import Scribird

final class FileTranscriptionCommandTests: XCTestCase {
    func test_arguments_preservePathsWithSpacesAndDefaultLanguage() throws {
        let command = try FileTranscriptionCommand(arguments: [
            "--transcribe", "/tmp/meeting audio.mp3", "--output-root", "/tmp/my transcripts"
        ])
        XCTAssertEqual(command.source.path, "/tmp/meeting audio.mp3")
        XCTAssertEqual(command.outputRoot.path, "/tmp/my transcripts")
        XCTAssertEqual(command.language, .english)
        XCTAssertEqual(command.engine, .speechAnalyzer)
    }

    func test_engineArgument_selectsQwenWithoutChangingLanguage() throws {
        let command = try FileTranscriptionCommand(arguments: [
            "--transcribe", "/tmp/audio.mp3", "--engine", "qwen3", "--language", "korean"
        ])
        XCTAssertEqual(command.engine, .qwen3)
        XCTAssertEqual(command.language, .korean)
        XCTAssertThrowsError(try FileTranscriptionCommand(arguments: [
            "--transcribe", "/tmp/audio.mp3", "--engine", "unrecognized"
        ]))
    }

    func test_invalidArguments_failBeforeStartingSpeech() {
        for arguments in [
            ["--transcribe"], ["--transcribe", ""],
            ["--transcribe", "/tmp/a.mp3", "--unknown", "x"],
            ["--transcribe", "/tmp/a.mp3", "--language", "auto"],
            ["--transcribe", "/tmp/a.mp3", "--language", "english", "--language", "korean"],
        ] {
            XCTAssertThrowsError(try FileTranscriptionCommand(arguments: arguments))
        }
    }

    func test_nonFileInput_isRejected() {
        for url in [URL(string: "https://example.com/meeting.mp3")!, URL(fileURLWithPath: "/tmp")] {
            XCTAssertThrowsError(try FileTranscription.validate(url, language: .english))
        }
    }
}

final class FileTranscriptArchiveTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "scribird-file-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func test_repeatedImports_keepExistingFilesAndUseDistinctDirectories() async throws {
        let source = root.appending(path: "original.mp3")
        try Data("original bytes".utf8).write(to: source)
        let first = try FileTranscriptArchive(root: root)
        let second = try FileTranscriptArchive(root: root)
        let firstDirectory = await first.directory
        let secondDirectory = await second.directory
        XCTAssertNotEqual(firstDirectory, secondDirectory)
        try await first.append(.init(start: 0, end: 1, text: "First import.", locale: "en_US"))
        let result = try await first.finish(source: source, duration: 1, language: .english)
        await second.close()
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "original bytes")
        XCTAssertEqual(result.text, "First import.")
        XCTAssertEqual(result.segments.first?.speaker, "unknown")
    }

    func test_finalRecord_isPersistedBeforeCompletionAndRetainedOnFailure() async throws {
        let archive = try FileTranscriptArchive(root: root)
        try await archive.append(.init(start: 2, end: 3, text: "Saved before completion.", locale: "en_US"))
        let directory = await archive.directory
        let data = try Data(contentsOf: directory.appending(path: "transcript.jsonl"))
        let record = try JSONDecoder().decode(FileTranscriptRecord.self, from: data)
        XCTAssertEqual(record.text, "Saved before completion.")
        await archive.close()
        XCTAssertEqual(try Data(contentsOf: directory.appending(path: "transcript.jsonl")), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "result.json").path))
        do {
            try await archive.append(record)
            XCTFail("Appending to a closed archive must fail")
        } catch { XCTAssertTrue(error is FileTranscriptionError) }
    }

    func test_completion_preservesLastSegmentAndWritesConsistentArtifacts() async throws {
        let archive = try FileTranscriptArchive(root: root)
        try await archive.append(.init(start: 3, end: 4, text: "Last sentence.", locale: "en_US"))
        try await archive.append(.init(start: 0, end: 2, text: "Opening sentence.", locale: "en_US"))
        let result = try await archive.finish(source: root.appending(path: "sample.mp3"), duration: 4, language: .english)
        XCTAssertEqual(result.text, "Opening sentence.\nLast sentence.")
        let markdown = try String(contentsOfFile: result.markdownPath, encoding: .utf8)
        XCTAssertTrue(markdown.contains("Last sentence."))
        XCTAssertTrue(markdown.contains("**Unknown**"))
        XCTAssertFalse(markdown.contains("**Remote**"))
        let metadata = try JSONDecoder().decode(FileTranscriptionResult.self, from: Data(
            contentsOf: URL(fileURLWithPath: result.outputDirectory).appending(path: "result.json")
        ))
        XCTAssertEqual(metadata.text, result.text)
        XCTAssertEqual(metadata.segments.count, 2)
    }

    func test_writeFailure_isNotReportedAsSuccess() async throws {
        let archive = try FileTranscriptArchive(root: root)
        let directory = await archive.directory
        try FileManager.default.createDirectory(
            at: directory.appending(path: "transcript.md"), withIntermediateDirectories: false
        )
        do {
            _ = try await archive.finish(source: root.appending(path: "a.wav"), duration: 1, language: .english)
            XCTFail("Markdown write failure must propagate")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "result.json").path))
        }
    }

    func test_emptyRecognition_writesExplicitEmptyTranscript() async throws {
        let archive = try FileTranscriptArchive(root: root)
        let result = try await archive.finish(source: root.appending(path: "silence.wav"), duration: 1, language: .english)
        XCTAssertEqual(result.text, "")
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertTrue(try String(contentsOfFile: result.markdownPath, encoding: .utf8).contains("No speech recognized."))
    }

    func test_fileTranscription_recognizesGeneratedSpeechThroughFinalSentence() async throws {
        guard let path = ProcessInfo.processInfo.environment["SCRIBIRD_FILE_FIXTURE"] else {
            throw XCTSkip("Set SCRIBIRD_FILE_FIXTURE to the generated English smoke-test audio.")
        }
        let source = URL(fileURLWithPath: path)
        let before = try Data(contentsOf: source)
        let result = try await FileTranscription.transcribe(source: source, language: .english, outputRoot: root)
        XCTAssertTrue(result.text.lowercased().contains("project meeting"))
        XCTAssertTrue(result.text.lowercased().contains("final transcript"))
        XCTAssertTrue(result.segments.allSatisfy { $0.speaker == "unknown" && $0.start >= 0 && $0.end <= result.durationSeconds + 1 })
        XCTAssertEqual(try Data(contentsOf: source), before)
        let jsonl = try String(contentsOfFile: result.jsonlPath, encoding: .utf8)
        XCTAssertEqual(jsonl.split(separator: "\n").count, result.segments.count)
    }

    func test_cancelAfterFirstResult_preservesPartialArchiveWithoutSuccessMetadata() async throws {
        guard let path = ProcessInfo.processInfo.environment["SCRIBIRD_FILE_FIXTURE"] else {
            throw XCTSkip("Set SCRIBIRD_FILE_FIXTURE to generated speech audio.")
        }
        let (ready, signalReady) = AsyncStream<Void>.makeStream()
        let (release, signalRelease) = AsyncStream<Void>.makeStream()
        let directory = LockedBox<URL?>(nil)
        let source = URL(fileURLWithPath: path)
        let outputRoot = root!
        let task = Task {
            defer { signalReady.finish() }
            return try await FileTranscription.transcribe(
                source: source, language: .english, outputRoot: outputRoot,
                onOutputDirectory: { url in directory.mutate { $0 = url } },
                onSegment: { _ in
                    signalReady.yield()
                    for await _ in release { break }
                }
            )
        }
        for await _ in ready { break }
        task.cancel()
        signalRelease.finish()
        do {
            _ = try await task.value
            XCTFail("Cancelled transcription must not return success")
        } catch {
            let folder = try XCTUnwrap(directory.value)
            XCTAssertGreaterThan(try Data(contentsOf: folder.appending(path: "transcript.jsonl")).count, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: "result.json").path))
        }
    }

    func test_qwenEngine_returnsRequestedModelAndChunkTimestamps() async throws {
        guard ProcessInfo.processInfo.environment["SCRIBIRD_QWEN_TESTS"] == "1",
              ProcessInfo.processInfo.environment["HF_HUB_OFFLINE"] == "1",
              ProcessInfo.processInfo.environment["SCRIBIRD_QWEN_PYTHON"] != nil,
              let path = ProcessInfo.processInfo.environment["SCRIBIRD_FILE_FIXTURE"] else {
            throw XCTSkip("Set SCRIBIRD_QWEN_TESTS=1, HF_HUB_OFFLINE=1, SCRIBIRD_QWEN_PYTHON and SCRIBIRD_FILE_FIXTURE for cached Qwen tests.")
        }
        let result = try await FileTranscription.transcribe(
            source: URL(fileURLWithPath: path), language: .english, outputRoot: root, engine: .qwen3
        )
        XCTAssertEqual(result.engine, .qwen3)
        XCTAssertEqual(result.model, "Alkd/Qwen3-ASR-1.7B-MLX-8bit")
        XCTAssertEqual(result.timestampGranularity, "chunk")
        XCTAssertTrue(result.text.lowercased().contains("final transcript"))
        XCTAssertEqual(result.segments.first?.start, 0)
    }
}
