import XCTest
@testable import Scribird

final class TranscriptMarkdownTests: XCTestCase {
    func test_mixedLanguages_groupsConsecutiveSpeechAndKeepsArchiveLabels() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [
            record(.remote, "답변", 3, "ko-KR"),
            record(.me, "second", 1, "en-US"),
            record(.me, " first ", 0, "en-US"),
            record(.me, "언어 전환", 2, "ko-KR"),
        ]

        let rendered = TranscriptMarkdown.render(
            startedAt: startedAt, segments: records,
            audioFiles: [URL(filePath: "/unused/meeting.m4a")]
        )

        XCTAssertEqual(rendered, """
        # Meeting Transcript — \(startedAt.formatted(date: .long, time: .shortened))

        Meeting audio: [meeting.m4a](meeting.m4a)

        Languages: en-US, ko-KR

        **Me** `00:00:00` _en-US_

        first second

        **Me** `00:00:02` _ko-KR_

        언어 전환

        **Remote** `00:00:03` _ko-KR_

        답변

        """)
    }

    func test_emptyTranscript_hasOnlyHeader() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(
            TranscriptMarkdown.render(startedAt: startedAt, segments: [], audioFiles: []),
            "# Meeting Transcript — \(startedAt.formatted(date: .long, time: .shortened))\n"
        )
    }

    private func record(
        _ speaker: Speaker, _ text: String, _ start: Double, _ locale: String
    ) -> TranscriptSegment.Record {
        Fixture.segmentWithoutTokens(
            speaker: speaker, locale: locale, text: text, start, start + 1, confidence: 0.9
        ).record
    }
}
