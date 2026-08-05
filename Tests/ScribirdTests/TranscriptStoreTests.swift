import Foundation
import XCTest
@testable import Scribird

/// 회의록 저장 테스트.
///
/// 검증 대상 계약: 확정 발화만 기록된다 / 확정 즉시 디스크에 남아 크래시에도
/// 살아남는다 / 읽기용 회의록은 화자·언어 경계에서 단락이 끊긴다.
///
/// 실제 홈 디렉터리를 오염시키지 않으려고 `HOME`을 임시 디렉터리로 바꿔 실행한다.
/// 저장 위치가 `~/Documents` 기준이므로 이 방법이 유일하게 격리된다.
final class TranscriptStoreTests: XCTestCase {

    private var sandbox: URL!
    private var originalHome: String?

    override func setUpWithError() throws {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "scribird-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", sandbox.path, 1)
    }

    override func tearDownWithError() throws {
        if let originalHome { setenv("HOME", originalHome, 1) }
        try? FileManager.default.removeItem(at: sandbox)
    }

    /// 기본 저장 루트에 세션을 연다.
    ///
    /// `HOME`을 임시 디렉터리로 바꿔 두었으므로 기본 위치가 그 안으로 들어온다 — 저장 루트를
    /// 사용자가 고를 수 있게 된 뒤에도 이 테스트들이 검증하는 것은 기본 위치의 동작이다.
    private func makeStore(startedAt: Date = Date()) throws -> TranscriptStore {
        try TranscriptStore(
            startedAt: startedAt,
            root: TranscriptRootLocation.standardDirectory()
        )
    }

    private func segment(
        _ speaker: Speaker, _ text: String, _ start: Double, _ end: Double,
        locale: String? = "ko-KR", isFinal: Bool = true
    ) -> TranscriptSegment {
        TranscriptSegment(
            speaker: speaker, range: Fixture.range(start, end),
            text: text, isFinal: isFinal, confidence: 0.9, localeIdentifier: locale
        )
    }

    private func jsonlLines(_ directory: URL) throws -> [[String: Any]] {
        let data = try String(contentsOf: directory.appending(path: "transcript.jsonl"),
                             encoding: .utf8)
        return data.split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    // MARK: - 즉시 append (크래시 내구성)

    func test_finalSegment_isOnDiskBeforeSessionEnds() async throws {
        let store = try makeStore()

        await store.append(segment(.me, "첫 발화입니다.", 0, 1.5))

        // finalize를 부르지 않은 상태에서 이미 읽혀야 한다 — 크래시 내구성의 핵심.
        let lines = try jsonlLines(await store.sessionDirectory)
        XCTAssertEqual(lines.count, 1, "확정 즉시 디스크에 남지 않아 크래시 시 유실된다")
        XCTAssertEqual(lines[0]["text"] as? String, "첫 발화입니다.")
    }

    func test_multipleSegments_appendInOrderOneLineEach() async throws {
        let store = try makeStore()

        await store.append(segment(.me, "하나", 0, 1))
        await store.append(segment(.remote, "둘", 1, 2))
        await store.append(segment(.me, "셋", 2, 3))

        let lines = try jsonlLines(await store.sessionDirectory)
        XCTAssertEqual(lines.map { $0["text"] as? String }, ["하나", "둘", "셋"])
    }

    func test_volatileSegment_isNotWritten() async throws {
        let store = try makeStore()

        await store.append(segment(.me, "말하는 중", 0, 1, isFinal: false))

        let lines = try jsonlLines(await store.sessionDirectory)
        XCTAssertTrue(lines.isEmpty, "잠정 결과가 저장되면 같은 말이 중복으로 남는다")
    }

    func test_record_carriesSpeakerAndTiming() async throws {
        let store = try makeStore()

        await store.append(segment(.remote, "상대방 발언", 2.5, 4.0))

        let lines = try jsonlLines(await store.sessionDirectory)
        XCTAssertEqual(lines[0]["speaker"] as? String, "remote")
        XCTAssertEqual(lines[0]["start"] as? Double ?? -1, 2.5, accuracy: 0.01)
        XCTAssertEqual(lines[0]["end"] as? Double ?? -1, 4.0, accuracy: 0.01)
        XCTAssertEqual(lines[0]["locale"] as? String, "ko-KR")
    }

    /// 파일 핸들이 열려 있는 상태에서 **다른 프로세스가 읽어도** 내용이 보여야 한다.
    ///
    /// 이것이 크래시 내구성의 실질적 조건이다. flush 없이 버퍼에만 남으면 프로세스가
    /// 죽는 순간 마지막 구간이 사라진다. 같은 프로세스 안에서 읽으면 커널 페이지
    /// 캐시 덕에 flush 여부와 무관하게 보이므로, 별도 프로세스로 읽어 확인한다.
    func test_appendedSegments_areVisibleToAnotherProcessBeforeFinalize() async throws {
        let store = try makeStore()
        await store.append(segment(.me, "크래시 전에 남아야 한다", 0, 1.5))
        let path = await store.sessionDirectory.appending(path: "transcript.jsonl").path

        // 외부 프로세스로 읽는다 — 우리 프로세스의 버퍼를 거치지 않는다.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.arguments = [path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let contents = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(contents.contains("크래시 전에 남아야 한다"),
                      "확정 발화가 디스크에 도달하지 않았다 — 크래시 시 유실된다")
    }

    // MARK: - 세션 디렉터리

    func test_sessionDirectory_isCreatedUnderDocuments() async throws {
        let store = try makeStore()
        let directory = await store.sessionDirectory

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(directory.path.contains("Scribird"),
                      "세션 디렉터리가 앱 폴더 아래에 없다")
    }

    func test_twoSessionsAtDifferentTimes_useDifferentDirectories() async throws {
        let first = try makeStore(startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = try makeStore(startedAt: Date(timeIntervalSince1970: 1_700_003_600))
        let firstDirectory = await first.sessionDirectory
        let secondDirectory = await second.sessionDirectory

        XCTAssertNotEqual(firstDirectory, secondDirectory,
                          "다른 세션이 같은 폴더를 쓰면 회의록이 덮어써진다")
    }

    // MARK: - 읽기용 회의록

    func test_finalize_writesMarkdownAlongsideJSONL() async throws {
        let store = try makeStore()
        await store.append(segment(.me, "안녕하세요.", 0, 1))

        let directory = await store.finalize(audioFiles: [])

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory.appending(path: "transcript.md").path),
            "읽기용 회의록이 생성되지 않았다"
        )
    }

    func test_markdown_groupsConsecutiveSameSpeakerIntoOneBlock() async throws {
        let store = try makeStore()
        await store.append(segment(.me, "첫 문장.", 0, 1))
        await store.append(segment(.me, "이어지는 문장.", 1, 2))

        let directory = await store.finalize(audioFiles: [])
        let markdown = try String(contentsOf: directory.appending(path: "transcript.md"),
                                  encoding: .utf8)

        // 같은 화자의 연속 발화는 헤딩 하나 아래로 묶인다.
        //
        // 라벨을 `archiveName`으로 비교한다 — 회의록 형식은 화면 언어와 무관하게 고정이므로,
        // 문구를 그대로 적으면 이 테스트가 언어 설정에 따라 깨진다.
        XCTAssertEqual(
            markdown.components(separatedBy: "**\(Speaker.me.archiveName)**").count - 1, 1,
            "같은 화자 연속 발화가 단락으로 묶이지 않았다"
        )
        XCTAssertTrue(markdown.contains("첫 문장. 이어지는 문장."))
    }

    func test_markdown_splitsWhenSpeakerChanges() async throws {
        let store = try makeStore()
        await store.append(segment(.me, "제 말입니다.", 0, 1))
        await store.append(segment(.remote, "제 답입니다.", 1, 2))

        let directory = await store.finalize(audioFiles: [])
        let markdown = try String(contentsOf: directory.appending(path: "transcript.md"),
                                  encoding: .utf8)

        XCTAssertTrue(markdown.contains("**\(Speaker.me.archiveName)**"))
        XCTAssertTrue(markdown.contains("**\(Speaker.remote.archiveName)**"))
    }

    func test_markdown_splitsWhenLanguageChanges() async throws {
        let store = try makeStore()
        await store.append(segment(.me, "한국어 발화.", 0, 1, locale: "ko-KR"))
        await store.append(segment(.me, "English utterance.", 1, 2, locale: "en-US"))

        let directory = await store.finalize(audioFiles: [])
        let markdown = try String(contentsOf: directory.appending(path: "transcript.md"),
                                  encoding: .utf8)

        // 코드스위칭이 보여야 한다 — 같은 화자라도 언어 경계에서 끊는다.
        XCTAssertEqual(
            markdown.components(separatedBy: "**\(Speaker.me.archiveName)**").count - 1, 2,
            "언어가 바뀌는 지점에서 단락이 끊기지 않았다"
        )
        XCTAssertTrue(markdown.contains("ko-KR"), "인식된 언어가 머리말에 없다")
        XCTAssertTrue(markdown.contains("en-US"),
                      "두 언어가 섞인 회의인데 머리말에 둘 다 적히지 않았다")
    }

    func test_markdown_ordersBlocksByTime() async throws {
        let store = try makeStore()
        // 뒤늦게 도착한 발화를 나중에 append 한다.
        await store.append(segment(.me, "나중 발화", 10, 11))
        await store.append(segment(.remote, "이른 발화", 1, 2))

        let directory = await store.finalize(audioFiles: [])
        let markdown = try String(contentsOf: directory.appending(path: "transcript.md"),
                                  encoding: .utf8)

        let earlyIndex = markdown.range(of: "이른 발화")!.lowerBound
        let lateIndex = markdown.range(of: "나중 발화")!.lowerBound
        XCTAssertLessThan(earlyIndex, lateIndex, "회의록이 시간순으로 정렬되지 않았다")
    }

    func test_markdown_linksSavedAudioFiles() async throws {
        let store = try makeStore()
        await store.append(segment(.me, "발화", 0, 1))
        let audio = await store.sessionDirectory.appending(path: "me.m4a")

        let directory = await store.finalize(audioFiles: [audio])
        let markdown = try String(contentsOf: directory.appending(path: "transcript.md"),
                                  encoding: .utf8)

        XCTAssertTrue(markdown.contains("me.m4a"), "원본 오디오 링크가 없다")
    }

    func test_markdown_withNoSegments_stillProducesFile() async throws {
        let store = try makeStore()

        let directory = await store.finalize(audioFiles: [])

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory.appending(path: "transcript.md").path),
            "발화가 없어도 회의록 파일은 남아야 한다"
        )
    }

    func test_singleLanguageSession_omitsLanguageHeader() async throws {
        let store = try makeStore()
        await store.append(segment(.me, "한국어만.", 0, 1, locale: "ko-KR"))
        await store.append(segment(.remote, "역시 한국어.", 1, 2, locale: "ko-KR"))

        let directory = await store.finalize(audioFiles: [])
        let markdown = try String(contentsOf: directory.appending(path: "transcript.md"),
                                  encoding: .utf8)

        XCTAssertFalse(markdown.contains("Languages:"),
                       "단일 언어 회의에 불필요한 언어 표기가 들어갔다")
    }
}
