import Darwin
import Foundation

struct TranscriptStoreIO: Sendable {
    var write: @Sendable (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }
    var synchronize: @Sendable (FileHandle) throws -> Void = { try $0.synchronize() }
    var writeMarkdown: @Sendable (String, URL) throws -> Void = { try $0.write(to: $1, atomically: true, encoding: .utf8) }
}

/// 확정된 세그먼트를 디스크에 즉시 append 한다.
///
/// 회의는 길고 앱은 죽을 수 있다. 메모리에 모아 두고 종료 시 한 번에 쓰는 방식은
/// 크래시 한 번에 회의록 전체를 잃는다. 그래서 final 세그먼트가 나올 때마다
/// JSONL 한 줄을 파일 핸들로 바로 흘려보낸다.
actor TranscriptStore {
    /// 저장 루트 아래의 세션별 디렉터리.
    let sessionDirectory: URL
    private let jsonlURL: URL
    private var handle: FileHandle?
    private let encoder = JSONEncoder()
    private var segments: [TranscriptSegment.Record] = []
    private let io: TranscriptStoreIO
    private(set) var storageError: (any Error)?

    /// - Parameters:
    ///   - startedAt: 세션 시작 시각. 디렉터리 이름과 회의록 헤더에 쓴다.
    ///   - root: 세션 디렉터리를 만들 저장 루트. 사용자가 고른 폴더일 수 있으므로 호출자가
    ///     정해서 넘긴다 — 이 타입이 직접 계산하면 되돌림 판정이 두 곳에 생긴다.
    init(startedAt: Date, root: URL, engine: FileTranscriptionEngine? = nil,
         io: TranscriptStoreIO = TranscriptStoreIO()) throws {
        self.io = io
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let name = formatter.string(from: startedAt)

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        // MCP에서 같은 초에 세션을 분리하면 기존 이름과 충돌한다. mkdir의 원자적 생성으로
        // 폴더를 확보하고, 충돌 때만 접미사를 붙여 기존 회의록·오디오를 덮어쓰지 않는다.
        var candidate = root.appending(path: name, directoryHint: .isDirectory)
        while mkdir(candidate.path, 0o700) != 0 {
            guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            candidate = root.appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        }
        sessionDirectory = candidate

        jsonlURL = sessionDirectory.appending(path: "transcript.jsonl")
        guard FileManager.default.createFile(atPath: jsonlURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: jsonlURL)
        self.startedAt = startedAt
        if let engine {
            let metadata = ["engine": engine.rawValue, "model": engine.modelIdentifier,
                            "timestampGranularity": engine.timestampGranularity]
            try JSONEncoder().encode(metadata).write(to: sessionDirectory.appending(path: "transcription.json"),
                                                    options: .atomic)
        }
    }

    private let startedAt: Date

    /// 세션이 닫힌 뒤 도착해 기록되지 못한 발화 수.
    ///
    /// 늦게 도착하는 것 자체는 정상이지만, 버릴 때 아무 흔적이 없으면 유실이 일어난 사실조차
    /// 알 수 없다. 호출 순서가 어긋나면 이 값이 0을 넘으므로 테스트가 그것을 잡는다.
    private(set) var droppedAfterFinalize = 0

    /// Returns success only after append and synchronization, so callers cannot acknowledge unsaved text.
    func append(_ segment: TranscriptSegment) throws {
        guard segment.isFinal else { return }
        let record = segment.record

        // 이미 닫힌 세션에는 기록할 수 없다. 읽기용 회의록도 생성이 끝났으므로 여기에
        // 도착한 발화는 두 형식에서 함께 빠진다 — 조용히 넘기지 않고 센다.
        guard handle != nil else {
            droppedAfterFinalize += 1
            throw CocoaError(.fileWriteUnknown)
        }
        if let storageError { throw storageError }
        do {
            var data = try encoder.encode(record)
            data.append(0x0A)
            try io.write(handle!, data)
            try io.synchronize(handle!)
            segments.append(record)
        } catch {
            storageError = error
            throw error
        }
    }

    /// Preserves successful JSONL records and reports any append, close, or Markdown failure to the recorder.
    func finalize(audioFiles: [URL]) throws -> URL {
        do { try handle?.close() }
        catch { storageError = storageError ?? error }
        handle = nil
        let markdownURL = sessionDirectory.appending(path: "transcript.md")
        do {
            try io.writeMarkdown(TranscriptMarkdown.render(
                startedAt: startedAt, segments: segments, audioFiles: audioFiles
            ), markdownURL)
        } catch { storageError = storageError ?? error }
        if let storageError { throw storageError }
        return sessionDirectory
    }

}
