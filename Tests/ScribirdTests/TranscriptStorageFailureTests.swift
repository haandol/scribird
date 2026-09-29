import XCTest
@testable import Scribird

@MainActor
final class TranscriptStorageFailureTests: XCTestCase {
    func test_failedAppendOrSync_doesNotPublishAFinalizedSegment() async throws {
        for failSync in [false, true] {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            var io = TranscriptStoreIO()
            if failSync { io.synchronize = { _ in throw CocoaError(.fileWriteOutOfSpace) } }
            else { io.write = { _, _ in throw CocoaError(.fileWriteOutOfSpace) } }
            let store = try TranscriptStore(startedAt: Date(), root: root, io: io)
            let timeline = TranscriptTimeline()
            let segment = Fixture.segmentWithoutTokens(speaker: .me, locale: "en-US", text: "must be saved", 0, 1, confidence: nil)
            do {
                try await MeetingRecorder.commit(segment, to: timeline, store: store)
                XCTFail("Failed persistence cannot publish a finalized result")
            } catch { XCTAssertTrue(timeline.finalized.isEmpty) }
            do { _ = try await store.finalize(audioFiles: []); XCTFail("Storage failure must remain visible") }
            catch {}
            let directory = await store.sessionDirectory
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: "transcript.jsonl").path))
        }
    }

    func test_markdownFailure_preservesSavedJSONLAndReturnsTheError() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var io = TranscriptStoreIO()
        io.writeMarkdown = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        let store = try TranscriptStore(startedAt: Date(), root: root, io: io)
        try await store.append(Fixture.segmentWithoutTokens(locale: "en-US", text: "retained", 0, 1, confidence: nil))
        do { _ = try await store.finalize(audioFiles: []); XCTFail("Markdown failure must be returned") }
        catch {}
        let directory = await store.sessionDirectory
        let json = try String(contentsOf: directory.appending(path: "transcript.jsonl"), encoding: .utf8)
        XCTAssertTrue(json.contains("retained"))
    }
}
