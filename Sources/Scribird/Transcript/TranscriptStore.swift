import Foundation

/// 확정된 세그먼트를 디스크에 즉시 append 한다.
///
/// 회의는 길고 앱은 죽을 수 있다. 메모리에 모아 두고 종료 시 한 번에 쓰는 방식은
/// 크래시 한 번에 회의록 전체를 잃는다. 그래서 final 세그먼트가 나올 때마다
/// JSONL 한 줄을 파일 핸들로 바로 흘려보낸다.
actor TranscriptStore {
    /// `~/Documents/Scribird/` 아래 세션별 디렉터리.
    let sessionDirectory: URL
    private let jsonlURL: URL
    private var handle: FileHandle?
    private let encoder = JSONEncoder()
    private var segments: [TranscriptSegment.Record] = []

    /// 세션 디렉터리들이 모이는 곳. 화면에 표시하고 열기 위해 세션 없이도 필요하다.
    ///
    /// 산출물 위치의 주인이 이 타입이므로 여기서 계산한다 — 같은 경로 조립이 화면 코드에도
    /// 있으면 한쪽만 고쳐졌을 때 표시된 위치와 실제 저장 위치가 갈라진다.
    static func rootDirectory() throws -> URL {
        try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "Scribird", directoryHint: .isDirectory)
    }

    /// - Parameter startedAt: 세션 시작 시각. 디렉터리 이름과 회의록 헤더에 쓴다.
    init(startedAt: Date) throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let name = formatter.string(from: startedAt)

        let root = try Self.rootDirectory()

        sessionDirectory = root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: sessionDirectory,
            withIntermediateDirectories: true
        )

        jsonlURL = sessionDirectory.appending(path: "transcript.jsonl")
        FileManager.default.createFile(atPath: jsonlURL.path, contents: nil)
        handle = try FileHandle(forWritingTo: jsonlURL)
        self.startedAt = startedAt
    }

    private let startedAt: Date

    /// 세션이 닫힌 뒤 도착해 기록되지 못한 발화 수.
    ///
    /// 늦게 도착하는 것 자체는 정상이지만, 버릴 때 아무 흔적이 없으면 유실이 일어난 사실조차
    /// 알 수 없다. 호출 순서가 어긋나면 이 값이 0을 넘으므로 테스트가 그것을 잡는다.
    private(set) var droppedAfterFinalize = 0

    func append(_ segment: TranscriptSegment) {
        guard segment.isFinal else { return }
        let record = segment.record

        // 이미 닫힌 세션에는 기록할 수 없다. 읽기용 회의록도 생성이 끝났으므로 여기에
        // 도착한 발화는 두 형식에서 함께 빠진다 — 조용히 넘기지 않고 센다.
        guard handle != nil else {
            droppedAfterFinalize += 1
            return
        }

        segments.append(record)

        guard let handle, var data = try? encoder.encode(record) else { return }
        data.append(0x0A)  // newline
        try? handle.write(contentsOf: data)
        // 앱 크래시에는 write(2) 자체로 이미 안전하다 — FileHandle.write는 버퍼링
        // 없이 커널로 넘기므로 프로세스가 죽어도 페이지 캐시에 남는다. 이 fsync는
        // 그보다 위인 OS 패닉·전원 손실을 대비한다. 회의록은 다시 만들 수 없으므로
        // 발화당 한 번의 동기화 비용을 받아들인다.
        try? handle.synchronize()
    }

    /// 세션을 닫고 사람이 읽을 Markdown 회의록을 함께 남긴다.
    ///
    /// - Parameter audioFiles: 함께 저장된 원본 오디오 경로. 회의록 머리말에
    ///   링크로 적어 두면 나중에 원본을 되짚기 쉽다.
    func finalize(audioFiles: [URL]) -> URL {
        try? handle?.close()
        handle = nil
        let markdownURL = sessionDirectory.appending(path: "transcript.md")
        try? renderMarkdown(audioFiles: audioFiles)
            .write(to: markdownURL, atomically: true, encoding: .utf8)
        return sessionDirectory
    }

    private func renderMarkdown(audioFiles: [URL]) -> String {
        let header = startedAt.formatted(date: .long, time: .shortened)
        var lines = ["# 회의록 — \(header)", ""]

        if !audioFiles.isEmpty {
            lines.append("원본 오디오: " + audioFiles.map { url in
                let name = url.lastPathComponent
                let label = Speaker(rawValue: url.deletingPathExtension().lastPathComponent)?
                    .displayName ?? name
                return "[\(label)](\(name))"
            }.joined(separator: " · "))
            lines.append("")
        }

        let sorted = segments.sorted { $0.start < $1.start }

        // 두 언어가 섞인 회의였다면 머리말에 적어 둔다.
        let languages = Set(sorted.compactMap(\.locale)).sorted()
        if languages.count > 1 {
            lines.append("인식 언어: " + languages.joined(separator: ", "))
            lines.append("")
        }

        // 같은 화자의 연속 발화는 한 단락으로 묶어서 읽기 쉽게 만든다.
        // 언어가 바뀌는 지점에서도 끊어 줘야 코드 스위칭이 보인다.
        var currentSpeaker: Speaker?
        var currentLocale: String?
        var buffer: [String] = []
        var blockStart: TimeInterval = 0

        func flush() {
            guard let speaker = currentSpeaker, !buffer.isEmpty else { return }
            var heading = "**\(speaker.displayName)** `\(formatTimecode(blockStart))`"
            if languages.count > 1, let currentLocale {
                heading += " _\(currentLocale)_"
            }
            lines.append(heading)
            lines.append("")
            lines.append(buffer.joined(separator: " "))
            lines.append("")
            buffer.removeAll()
        }

        for record in sorted {
            if record.speaker != currentSpeaker || record.locale != currentLocale {
                flush()
                currentSpeaker = record.speaker
                currentLocale = record.locale
                blockStart = record.start
            }
            buffer.append(record.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        flush()

        return lines.joined(separator: "\n")
    }
}
