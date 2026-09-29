import AVFoundation
import Observation
import Speech
import XCTest
@testable import Scribird

@MainActor
final class MeetingRecorderLifecycleTests: XCTestCase {
    private var root: URL!
    private var originalHome: String?
    private var savedPreferences: [String: Any] = [:]
    private let preferenceKeys = [
        "transcriptionLanguage", "savesOriginalAudio", "opensSessionFolderOnStop",
        "transcriptRootPath", "pinnedInputDeviceUID", "pinnedOutputDeviceUID",
        "liveTranscriptionEngine",
    ]

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", root.path, 1)
        for key in preferenceKeys {
            savedPreferences[key] = UserDefaults.standard.object(forKey: key)
        }
        RecordingPreferences.save(language: .english)
        RecordingPreferences.save(engine: .speechAnalyzer)
        RecordingPreferences.save(savesAudio: false)
        RecordingPreferences.save(opensFolderOnStop: false)
    }

    override func tearDown() async throws {
        for key in preferenceKeys {
            if let value = savedPreferences[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        if let originalHome { setenv("HOME", originalHome, 1) }
        else { unsetenv("HOME") }
        try FileManager.default.removeItem(at: root)
    }

    func test_oneCaptureFails_otherSourceRecordsAndFinalizes() async throws {
        let harness = RecordingHarness(root: root)
        harness.failingSources = [.me]
        let recorder = harness.makeRecorder()

        await recorder.start()
        XCTAssertEqual(recorder.state, .recording)
        XCTAssertEqual(recorder.activeSources, [.remote])
        XCTAssertNotNil(recorder.sourceWarning)
        let remote = try XCTUnwrap(harness.provider.latest[.remote])
        await remote.emit(segment("remaining source", speaker: .remote))
        await recorder.stop()

        let directory = try XCTUnwrap(recorder.lastSessionDirectory)
        XCTAssertTrue(try markdown(directory).contains("remaining source"))
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertEqual(harness.captures[.remote]?.first?.stopCount, 1)
    }

    func test_engineChangeWhileRecording_preservesActiveAndStoredEngine() async throws {
        let harness = RecordingHarness(root: root)
        let recorder = harness.makeRecorder()
        await recorder.start()
        recorder.chooseEngine(.qwen3)
        XCTAssertEqual(recorder.engine, .speechAnalyzer)
        XCTAssertEqual(RecordingPreferences.engine(), .speechAnalyzer)
        XCTAssertNotNil(recorder.engineWarning)
        await recorder.stop()
        recorder.chooseEngine(.qwen3)
        XCTAssertEqual(harness.makeRecorder().engine, .qwen3)
    }

    func test_qwenSelection_allowsAllMeetingLanguagesWithoutAppleAssets() async throws {
        let harness = RecordingHarness(root: root)
        let recorder = harness.makeRecorder(models: MissingModels())
        XCTAssertFalse(recorder.canStartRecording)
        recorder.chooseEngine(.qwen3)
        XCTAssertTrue(recorder.canStartRecording)
        XCTAssertEqual(Set(recorder.availableLanguages), Set(TranscriptionLanguage.allCases))
        await recorder.chooseLanguage(.auto)
        await recorder.start()
        XCTAssertEqual(recorder.state, .recording)
        XCTAssertEqual(harness.qwenProvider.prepareCount, 1)
        XCTAssertEqual(harness.provider.prepareCount, 0)
        await recorder.chooseLanguage(.korean)
        XCTAssertEqual(recorder.language, .korean)
        await recorder.stop()
    }

    func test_reclaimedRequestedLanguage_failsBeforePreparingAnotherLanguage() async {
        RecordingPreferences.save(language: .auto)
        let harness = RecordingHarness(root: root)
        let recorder = harness.makeRecorder(models: EnglishOnlyModels())
        await recorder.start()
        guard case .failed = recorder.state else { return XCTFail("Missing Korean must not silently select English") }
        XCTAssertEqual(recorder.language, .auto)
        XCTAssertEqual(RecordingPreferences.language(), .auto)
        XCTAssertEqual(harness.provider.prepareCount, 0)
        XCTAssertTrue(harness.captures.isEmpty)
    }

    func test_secondSourceLanguageFailure_restoresTheFirstSource() async throws {
        let harness = RecordingHarness(root: root)
        let recorder = harness.makeRecorder()
        recorder.chooseEngine(.qwen3)
        await recorder.start()
        let remote = try XCTUnwrap(harness.qwenProvider.latest[.remote])
        await remote.failLanguageChanges()
        await recorder.chooseLanguage(.korean)
        XCTAssertEqual(recorder.language, .english)
        XCTAssertEqual(RecordingPreferences.language(), .english)
        let microphoneChanges = await harness.qwenProvider.latest[.me]?.localeChanges
        XCTAssertEqual(microphoneChanges, [["ko-KR"], ["en-US"]])
        XCTAssertNotNil(recorder.languageSwitchWarning)
        await recorder.stop()
    }

    func test_engineChangesDuringPreparationAndStopping_areRejected() async throws {
        let harness = RecordingHarness(root: root)
        let entered = expectation(description: "preparing capture")
        let release = AsyncTestGate()
        harness.beforeCapture = { speaker in
            if speaker == .me { entered.fulfill(); await release.wait() }
        }
        let recorder = harness.makeRecorder()
        let start = Task { await recorder.start() }
        await fulfillment(of: [entered], timeout: 2)
        recorder.chooseEngine(.qwen3)
        XCTAssertEqual(recorder.engine, .speechAnalyzer)
        XCTAssertEqual(RecordingPreferences.engine(), .speechAnalyzer)
        await release.open()
        await start.value
        harness.provider.blocksCleanup = true
        // These sessions were already constructed. Block their finalization explicitly.
        let finishGate = AsyncTestGate()
        for session in harness.provider.latest.values { await session.blockFinish(on: finishGate) }
        let stop = Task { await recorder.stop() }
        await harness.provider.finishStarted.wait()
        XCTAssertEqual(recorder.state, .stopping)
        recorder.chooseEngine(.qwen3)
        XCTAssertEqual(recorder.engine, .speechAnalyzer)
        XCTAssertEqual(RecordingPreferences.engine(), .speechAnalyzer)
        await finishGate.open()
        await stop.value
    }

    func test_languageValidationCompletingAfterStop_doesNotChangeNextRecordingPreferences() async throws {
        let harness = RecordingHarness(root: root)
        let recorder = harness.makeRecorder()
        recorder.chooseEngine(.qwen3)
        await recorder.start()
        let gate = AsyncTestGate()
        harness.qwenProvider.switchRelease = gate
        let change = Task { await recorder.chooseLanguage(.korean) }
        await harness.qwenProvider.switchStarted.wait()
        await recorder.stop()
        await gate.open()
        await change.value
        XCTAssertEqual(recorder.language, .english)
        XCTAssertEqual(RecordingPreferences.language(), .english)
    }

    func test_oldLanguageRollback_cannotWarnOrFailANewRecording() async throws {
        let harness = RecordingHarness(root: root)
        let recorder = harness.makeRecorder()
        recorder.chooseEngine(.qwen3)
        await recorder.start()
        let old = harness.qwenProvider.latest
        let entered = AsyncTestGate()
        let release = AsyncTestGate()
        for session in old.values { await session.rejectChangesAfterCancellation() }
        await old[.remote]?.gateLanguageChange(entered: entered, release: release)
        let changing = Task { await recorder.chooseLanguage(.korean) }
        await entered.wait()
        await recorder.stop()
        await recorder.start()
        XCTAssertEqual(recorder.state, .recording)
        XCTAssertNil(recorder.transcriptionWarning)
        await release.open()
        await changing.value
        XCTAssertNil(recorder.transcriptionWarning)
        XCTAssertEqual(recorder.language, .english)
        XCTAssertEqual(RecordingPreferences.language(), .english)
        await recorder.stop()
        XCTAssertEqual(recorder.state, .idle)
    }

    func test_bothCapturesFail_releasesPreparedSessions() async {
        let harness = RecordingHarness(root: root)
        harness.failingSources = Set(Speaker.allCases)
        let recorder = harness.makeRecorder()

        await recorder.start()

        guard case .failed = recorder.state else {
            return XCTFail("두 소스 실패 시 세션을 접어야 한다")
        }
        XCTAssertNil(recorder.currentSessionDirectory)
        XCTAssertTrue(recorder.activeSources.isEmpty)
        for session in harness.provider.latest.values {
            let count = await session.cancelCount
            XCTAssertEqual(count, 1)
        }
    }

    func test_firstSourceResult_isPersistedWhileSecondSourceStillStarts() async throws {
        let harness = RecordingHarness(root: root)
        let secondSourceRequested = expectation(description: "두 번째 캡처 준비")
        let allowSecondSource = AsyncTestGate()
        harness.beforeCapture = { speaker in
            guard speaker == .remote else { return }
            secondSourceRequested.fulfill()
            await allowSecondSource.wait()
        }
        let recorder = harness.makeRecorder()
        let starting = Task { await recorder.start() }
        await fulfillment(of: [secondSourceRequested], timeout: 1)
        let microphone = try XCTUnwrap(harness.provider.latest[.me])

        await emitAndObserve(
            segment("early microphone result", speaker: .me),
            through: microphone, recorder: recorder
        )

        let directory = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.hasPrefix("2023-") }
        )
        XCTAssertTrue(
            try jsonl(directory).contains("early microphone result"),
            "다른 소스를 기다리는 동안 화면에 표시된 확정 발화도 즉시 저장돼야 한다"
        )
        await allowSecondSource.open()
        await starting.value
        await recorder.stop()
    }

    func test_languageSwitch_drainsPendingWithoutRestartingCapture() async throws {
        let harness = RecordingHarness(root: root)
        let recorder = harness.makeRecorder()
        await recorder.chooseLanguage(.auto)
        await recorder.start()
        let directory = try XCTUnwrap(recorder.currentSessionDirectory)
        let remote = try XCTUnwrap(harness.provider.latest[.remote])
        await emitAndObserve(
            segment("전환 직전 문장", speaker: .remote, final: false, locale: "ko-KR"),
            through: remote, recorder: recorder
        )

        await recorder.chooseLanguage(.korean)

        XCTAssertEqual(recorder.language, .korean)
        XCTAssertEqual(recorder.currentSessionDirectory, directory)
        XCTAssertTrue(try jsonl(directory).contains("전환 직전 문장"))
        XCTAssertEqual(harness.provider.prepareCount, 1)
        for speaker in Speaker.allCases {
            XCTAssertEqual(harness.captures[speaker]?.count, 1)
            XCTAssertEqual(harness.captures[speaker]?.first?.stopCount, 0)
            let changes = await harness.provider.latest[speaker]?.localeChanges
            XCTAssertEqual(changes, [["ko-KR"]])
        }
        await recorder.stop()
        XCTAssertTrue(try markdown(directory).contains("전환 직전 문장"))
    }

    func test_missingSwitchModel_doesNotTouchLiveSessions() async throws {
        let harness = RecordingHarness(root: root)
        let recorder = harness.makeRecorder()
        await recorder.start()
        let directory = recorder.currentSessionDirectory
        harness.provider.rejectSwitch = true

        await recorder.chooseLanguage(.auto)

        XCTAssertEqual(recorder.language, .english)
        XCTAssertEqual(recorder.state, .recording)
        XCTAssertEqual(recorder.currentSessionDirectory, directory)
        XCTAssertNotNil(recorder.languageSwitchWarning)
        for session in harness.provider.latest.values {
            let changes = await session.localeChanges
            XCTAssertTrue(changes.isEmpty)
        }
        await recorder.stop()
    }

    func test_rotation_preservesCaptureAndRebasesSavedSegments() async throws {
        let harness = RecordingHarness(root: root)
        let recorder = harness.makeRecorder()
        await recorder.start()
        let firstDirectory = try XCTUnwrap(recorder.currentSessionDirectory)
        let remote = try XCTUnwrap(harness.provider.latest[.remote])
        await emitAndObserve(
            segment("first meeting", speaker: .remote, final: false),
            through: remote, recorder: recorder
        )
        harness.now = harness.now.addingTimeInterval(10)

        await recorder.startNewSession()

        let secondDirectory = try XCTUnwrap(recorder.currentSessionDirectory)
        XCTAssertNotEqual(firstDirectory, secondDirectory)
        XCTAssertTrue(try markdown(firstDirectory).contains("first meeting"))
        XCTAssertEqual(harness.rootResolutions, 1)
        XCTAssertEqual(harness.provider.prepareCount, 1)
        for speaker in Speaker.allCases {
            XCTAssertEqual(harness.captures[speaker]?.count, 1)
            XCTAssertEqual(harness.captures[speaker]?.first?.stopCount, 0)
        }
        await remote.emit(segment("late duplicate", speaker: .remote))
        await emitAndObserve(
            segment("second meeting", speaker: .remote, start: 11),
            through: remote, recorder: recorder
        )
        XCTAssertEqual(recorder.segments.first?.start, 1)
        await recorder.stop()
        let text = try markdown(secondDirectory)
        XCTAssertTrue(text.contains("second meeting"))
        XCTAssertTrue(text.contains("00:00:01"))
        XCTAssertFalse(text.contains("late duplicate"))
        XCTAssertFalse(text.contains("first meeting"))
    }

    func test_timeoutSavesPendingAndNextRunIgnoresOldResults() async throws {
        let harness = RecordingHarness(root: root)
        harness.provider.blocksCleanup = true
        let timeout = AsyncTestGate()
        let recorder = harness.makeRecorder(timeout: { await timeout.wait() })
        await recorder.start()
        let firstDirectory = try XCTUnwrap(recorder.currentSessionDirectory)
        let oldSessions = harness.provider.latest
        let remote = try XCTUnwrap(oldSessions[.remote])
        await emitAndObserve(
            segment("pending at timeout", speaker: .remote, final: false),
            through: remote, recorder: recorder
        )
        let returned = expectation(description: "마무리와 취소가 모두 막혀도 저장 완료")
        let stopping = Task {
            await recorder.stop()
            returned.fulfill()
        }
        await harness.provider.finishStarted.wait()
        await timeout.open()
        await fulfillment(of: [returned], timeout: 1)

        guard case .failed = recorder.state else {
            await harness.provider.releaseCleanup()
            await stopping.value
            return XCTFail("An incomplete shutdown must be reported, not silently treated as idle")
        }
        XCTAssertTrue(try markdown(firstDirectory).contains("pending at timeout"))
        XCTAssertTrue(try jsonl(firstDirectory).contains("pending at timeout"))
        XCTAssertNil(recorder.currentSessionDirectory)

        harness.provider.blocksCleanup = false
        harness.now = harness.now.addingTimeInterval(30)
        await recorder.start()
        XCTAssertEqual(recorder.state, .recording)
        for old in oldSessions.values {
            await old.emit(segment("stale result", speaker: .remote))
        }
        await harness.provider.releaseCleanup()
        let newRemote = try XCTUnwrap(harness.provider.latest[.remote])
        await emitAndObserve(
            segment("new recording", speaker: .remote), through: newRemote, recorder: recorder
        )
        await recorder.stop()
        let secondDirectory = try XCTUnwrap(recorder.lastSessionDirectory)
        XCTAssertNotEqual(firstDirectory, secondDirectory)
        XCTAssertTrue(try markdown(secondDirectory).contains("new recording"))
        XCTAssertFalse(try markdown(secondDirectory).contains("stale result"))
        XCTAssertFalse(try markdown(firstDirectory).contains("stale result"))
        await stopping.value
    }

    private func emitAndObserve(
        _ segment: TranscriptSegment,
        through session: StubTranscription,
        recorder: MeetingRecorder
    ) async {
        let changed = expectation(description: "전사 화면 반영")
        withObservationTracking { _ = recorder.segments } onChange: { changed.fulfill() }
        await session.emit(segment)
        await fulfillment(of: [changed], timeout: 1)
    }

    private func segment(
        _ text: String, speaker: Speaker, start: Double = 0,
        final: Bool = true, locale: String = "en-US"
    ) -> TranscriptSegment {
        TranscriptSegment(
            speaker: speaker, range: Fixture.range(start, start + 1),
            text: text, isFinal: final, confidence: 0.9, localeIdentifier: locale
        )
    }

    private func markdown(_ directory: URL) throws -> String {
        try String(contentsOf: directory.appending(path: "transcript.md"), encoding: .utf8)
    }

    private func jsonl(_ directory: URL) throws -> String {
        try String(contentsOf: directory.appending(path: "transcript.jsonl"), encoding: .utf8)
    }
}

@MainActor
private final class RecordingHarness {
    let root: URL
    let provider = StubSpeechProvider()
    let qwenProvider = StubSpeechProvider()
    var captures: [Speaker: [StubCapture]] = [:]
    var failingSources: Set<Speaker> = []
    var now = Date(timeIntervalSince1970: 1_700_000_000)
    var rootResolutions = 0
    var beforeCapture: (@MainActor (Speaker) async -> Void)?

    init(root: URL) { self.root = root }

    func makeRecorder(
        timeout: (@Sendable () async throws -> Void)? = nil,
        models: any SpeechModelInstalling = InstalledModels()
    ) -> MeetingRecorder {
        var environment = RecordingEnvironment()
        environment.speech = provider
        environment.qwen = qwenProvider
        environment.makeCapture = { [self] speaker, _, _, _ in
            await beforeCapture?(speaker)
            let capture = StubCapture(failsToStart: failingSources.contains(speaker))
            captures[speaker, default: []].append(capture)
            return capture
        }
        environment.resolveDevice = { _ in .systemDefault }
        environment.makeDeviceMonitor = { _ in nil }
        environment.resolveRoot = { [self] in
            rootResolutions += 1
            return .standard(root)
        }
        environment.now = { [self] in now }
        if let timeout { environment.finalizationTimeout = timeout }
        return MeetingRecorder(
            modelManager: SpeechModelManager(installer: models),
            environment: environment
        )
    }
}

private struct InstalledModels: SpeechModelInstalling {
    func installedLocaleIdentifiers() async -> [String] { ["en-US", "ko-KR"] }
    func install(_ language: SpeechModelLanguage) async throws {}
}

private struct MissingModels: SpeechModelInstalling {
    func installedLocaleIdentifiers() async -> [String] { [] }
    func install(_ language: SpeechModelLanguage) async throws {}
}

private struct EnglishOnlyModels: SpeechModelInstalling {
    func installedLocaleIdentifiers() async -> [String] { ["en-US"] }
    func install(_ language: SpeechModelLanguage) async throws {}
}

@MainActor
private final class StubSpeechProvider: SpeechSessionProviding {
    var latest: [Speaker: StubTranscription] = [:]
    var prepareCount = 0
    var rejectSwitch = false
    var blocksCleanup = false
    let finishStarted = AsyncTestGate()
    let finishRelease = AsyncTestGate()
    let cancelRelease = AsyncTestGate()
    let switchStarted = AsyncTestGate()
    var switchRelease: AsyncTestGate?

    func prepare(language: TranscriptionLanguage) async throws -> PreparedSpeechSessions {
        prepareCount += 1
        latest = Dictionary(uniqueKeysWithValues: Speaker.allCases.map {
            ($0, StubTranscription(
                finishStarted: finishStarted,
                finishRelease: blocksCleanup ? finishRelease : nil,
                cancelRelease: blocksCleanup ? cancelRelease : nil
            ))
        })
        return PreparedSpeechSessions(
            sessions: latest,
            audioFormat: AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
            )!,
            retentionWarning: nil
        )
    }

    func installedLocales(for language: TranscriptionLanguage) async throws -> [Locale] {
        await switchStarted.open()
        await switchRelease?.wait()
        if rejectSwitch { throw MeetingRecorder.RecorderError.languageModelNotInstalled(language) }
        return language.locales
    }

    func releaseCleanup() async {
        await finishRelease.open()
        await cancelRelease.open()
    }
}

private actor StubTranscription: Transcribing {
    private let stream: AsyncStream<TranscriptSegment>
    private let continuation: AsyncStream<TranscriptSegment>.Continuation
    private let finishStarted: AsyncTestGate
    private var finishRelease: AsyncTestGate?
    private let cancelRelease: AsyncTestGate?
    private(set) var localeChanges: [[String]] = []
    private(set) var cancelCount = 0
    private var rejectsLanguageChange = false
    private var rejectsCancelledChanges = false
    private var languageChangeGate: (AsyncTestGate, AsyncTestGate)?

    init(finishStarted: AsyncTestGate, finishRelease: AsyncTestGate?, cancelRelease: AsyncTestGate?) {
        (stream, continuation) = AsyncStream.makeStream()
        self.finishStarted = finishStarted
        self.finishRelease = finishRelease
        self.cancelRelease = cancelRelease
    }

    func setLocales(_ locales: [Locale]) async throws {
        if let gate = languageChangeGate { await gate.0.open(); await gate.1.wait() }
        if rejectsCancelledChanges && cancelCount > 0 { throw CancellationError() }
        if rejectsLanguageChange { throw QwenFileTranscriber.RuntimeError.message("stub language failure") }
        localeChanges.append(locales.map(\.identifier))
    }
    func failLanguageChanges() { rejectsLanguageChange = true }
    func blockFinish(on gate: AsyncTestGate) { finishRelease = gate }
    func rejectChangesAfterCancellation() { rejectsCancelledChanges = true }
    func gateLanguageChange(entered: AsyncTestGate, release: AsyncTestGate) { languageChangeGate = (entered, release) }

    func segments() async -> AsyncStream<TranscriptSegment> { stream }
    func emit(_ segment: TranscriptSegment) { continuation.yield(segment) }

    func run(inputSequence: AsyncStream<AnalyzerInput>) async throws {
        for await _ in inputSequence {}
    }

    func finish() async {
        await finishStarted.open()
        await finishRelease?.wait()
        continuation.finish()
    }

    func cancel() async {
        cancelCount += 1
        await cancelRelease?.wait()
        continuation.finish()
    }
}

private final class StubCapture: CaptureSource {
    let level = AudioLevelTracker()
    var peakLevel: Float { 0 }
    private(set) var stopCount = 0
    private let failsToStart: Bool
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?

    init(failsToStart: Bool) { self.failsToStart = failsToStart }
    func start() throws {
        if failsToStart { throw MicrophoneCapture.CaptureError.permissionDenied }
    }
    func stop() {
        stopCount += 1
        continuation?.finish()
    }
    func makeInputStream() -> AsyncStream<AnalyzerInput> {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        return stream
    }
    func reconnect() throws {}
    func reconnect(toDeviceUID uid: String?) throws {}
}


extension MeetingRecorderLifecycleTests {
    func test_mcpLanguageSwitch_preservesPendingTextAndCapture() async throws {
        let harness = RecordingHarness(root: root)
        let recorder = harness.makeRecorder()
        let control = AppControl(recorder: recorder)
        let start = await control.handle(ControlRequest(command: "start_recording", arguments: ["language": .string("auto")]))
        XCTAssertNil(start.error)
        let directory = try XCTUnwrap(recorder.currentSessionDirectory)
        let remote = try XCTUnwrap(harness.provider.latest[.remote])
        await emitAndObserve(segment("전환 직전 문장", speaker: .remote, final: false, locale: "ko-KR"),
                             through: remote, recorder: recorder)
        let switched = await control.handle(ControlRequest(command: "set_recording_language", arguments: ["language": .string("korean")]))
        XCTAssertNil(switched.error)
        XCTAssertEqual(switched.result?.object?["language"], .string("korean"))
        XCTAssertEqual(switched.result?.object?["pendingCommand"], .null)
        XCTAssertEqual(recorder.currentSessionDirectory, directory)
        XCTAssertTrue(try jsonl(directory).contains("전환 직전 문장"))
        XCTAssertEqual(harness.provider.prepareCount, 1)
        XCTAssertTrue(harness.captures.values.allSatisfy { $0.count == 1 && $0[0].stopCount == 0 })
        let english = await control.handle(ControlRequest(command: "set_recording_language", arguments: ["language": .string("english")]))
        XCTAssertNil(english.error)
        XCTAssertEqual(recorder.language, .english)
        _ = await control.handle(ControlRequest(command: "stop_recording"))
        XCTAssertTrue(try markdown(directory).contains("전환 직전 문장"))
    }

    func test_mcpRejectedChanges_preserveLanguageAndOutputSettings() async throws {
        let harness = RecordingHarness(root: root)
        let recorder = harness.makeRecorder()
        let control = AppControl(recorder: recorder)
        _ = await control.handle(ControlRequest(command: "start_recording", arguments: ["language": .string("english")]))
        let directory = recorder.currentSessionDirectory
        harness.provider.rejectSwitch = true
        let switchResult = await control.handle(ControlRequest(command: "set_recording_language", arguments: ["language": .string("auto")]))
        XCTAssertNotNil(switchResult.error)
        XCTAssertEqual(recorder.language, .english)
        let preferences = await control.handle(ControlRequest(command: "set_recording_preferences", arguments: [
            "saves_audio": .bool(true), "opens_folder_on_stop": .bool(true),
        ]))
        XCTAssertNotNil(preferences.error)
        XCTAssertFalse(recorder.savesAudio)
        XCTAssertFalse(recorder.opensFolderOnStop)
        let location = await control.handle(ControlRequest(command: "set_transcript_root", arguments: ["path": .string(root.path)]))
        XCTAssertNotNil(location.error)
        let invalid = await control.handle(ControlRequest(command: "set_recording_language", arguments: ["language": .string("japanese")]))
        XCTAssertNotNil(invalid.error)
        XCTAssertEqual(recorder.currentSessionDirectory, directory)
        XCTAssertEqual(recorder.state, .recording)
        await recorder.stop()
    }

    func test_mcpOverlappingMutation_isRejectedWhileStatusRemainsReadable() async throws {
        let harness = RecordingHarness(root: root)
        let gate = AsyncTestGate()
        let started = expectation(description: "capture started")
        harness.beforeCapture = { speaker in
            if speaker == .me { started.fulfill(); await gate.wait() }
        }
        let recorder = harness.makeRecorder()
        let control = AppControl(recorder: recorder)
        let starting = Task { await control.handle(ControlRequest(command: "start_recording")) }
        await fulfillment(of: [started], timeout: 2)
        let rejected = await control.handle(ControlRequest(command: "set_recording_language", arguments: ["language": .string("auto")]))
        XCTAssertNotNil(rejected.error)
        let status = await control.handle(ControlRequest(command: "get_app_status"))
        XCTAssertNil(status.error)
        XCTAssertEqual(status.result?.object?["pendingCommand"], .string("start_recording"))
        XCTAssertEqual(status.result?.object?["state"], .string("preparing"))
        await gate.open()
        let result = await starting.value
        XCTAssertNil(result.error)
        await recorder.stop()
    }

    func test_mcpPaginationAndInvalidNumbers_doNotLoseFinalityOrTrap() async throws {
        let harness = RecordingHarness(root: root)
        let recorder = harness.makeRecorder()
        let control = AppControl(recorder: recorder)
        await recorder.start()
        let remote = try XCTUnwrap(harness.provider.latest[.remote])
        await emitAndObserve(segment("pending", speaker: .remote, final: false), through: remote, recorder: recorder)
        let live = await control.handle(ControlRequest(command: "get_live_transcript"))
        guard case .array(let segments) = live.result?.object?["segments"] else { return XCTFail("missing segments") }
        XCTAssertEqual(segments.first?.object?["isFinal"], .bool(false))
        let final = await control.handle(ControlRequest(command: "get_live_transcript", arguments: ["include_partial": .bool(false)]))
        XCTAssertEqual(final.result?.object?["total"], .number(0))
        for value in [ControlValue.number(Double(Int.max)), .number(-1), .number(1.5), .bool(true)] {
            let invalid = await control.handle(ControlRequest(command: "get_live_transcript", arguments: ["offset": value]))
            XCTAssertNotNil(invalid.error)
        }
        await recorder.stop()
    }

    func test_mcpStdioClient_controlsRealRecorderOverUnixSocket() async throws {
        guard ProcessInfo.processInfo.environment["SCRIBIRD_MCP_INTEGRATION"] == "1" else {
            throw XCTSkip("Set SCRIBIRD_MCP_INTEGRATION=1 after uv sync --project mcp --frozen")
        }
        let harness = RecordingHarness(root: root)
        let recorder = harness.makeRecorder()
        let control = AppControl(recorder: recorder)
        let server = LocalControlServer(handle: { await control.handle($0) })
        let directory = URL(filePath: "/tmp/sc-test-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        defer { server.stop(); try? FileManager.default.removeItem(at: directory) }
        try server.start(in: directory)
        let socket = try XCTUnwrap(server.socketPath)
        let project = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = project.appending(path: "mcp/tests/control_contract_client.py").path
        let python = project.appending(path: "mcp/.venv/bin/python").path
        let output = root.path
        let result = try await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: python)
            process.arguments = [script, socket, output]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
        XCTAssertEqual(result.0, 0, result.1)
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertEqual(harness.provider.prepareCount, 1)
        XCTAssertTrue(harness.captures.values.allSatisfy { $0.count == 1 && $0[0].stopCount == 1 })
    }
}


extension MeetingRecorderLifecycleTests {
    func test_mcpAllCommands_rejectUnknownArgumentsBeforeSideEffects() async throws {
        let harness = RecordingHarness(root: root)
        let recorder = harness.makeRecorder()
        let control = AppControl(recorder: recorder)
        for command in AppControl.commands {
            let response = await control.handle(ControlRequest(command: command, arguments: ["unexpected": .bool(true)]))
            XCTAssertNotNil(response.error, command)
            XCTAssertNil(response.result, command)
            XCTAssertNil(control.pendingCommand, command)
        }
        XCTAssertEqual(harness.provider.prepareCount, 0)
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertFalse(recorder.savesAudio)
        XCTAssertFalse(recorder.opensFolderOnStop)
    }

    func test_mcpNullResetsRoot_butMissingAndWrongTypeDoNot() async throws {
        let harness = RecordingHarness(root: root)
        let recorder = harness.makeRecorder()
        let control = AppControl(recorder: recorder)
        let chosen = await control.handle(ControlRequest(command: "set_transcript_root", arguments: ["path": .string(root.path)]))
        XCTAssertNil(chosen.error)
        for arguments: [String: ControlValue] in [[:], ["path": .bool(false)], ["path": .string("")]] {
            let response = await control.handle(ControlRequest(command: "set_transcript_root", arguments: arguments))
            XCTAssertNotNil(response.error)
            XCTAssertEqual(recorder.chosenTranscriptRoot?.path, root.path)
        }
        let reset = await control.handle(ControlRequest(command: "set_transcript_root", arguments: ["path": .null]))
        XCTAssertNil(reset.error)
        XCTAssertNil(recorder.chosenTranscriptRoot)
    }
}
