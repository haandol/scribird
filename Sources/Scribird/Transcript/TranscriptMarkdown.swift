import Foundation

enum TranscriptMarkdown {
    /// 읽기용 회의록을 만든다.
    ///
    /// **문구가 화면 언어를 따르지 않는다.** 이 파일은 나중에 다른 도구와 사람이 함께 읽으므로,
    /// 형식이 설정에 의존하면 한 폴더 안에서 어휘가 섞이고 읽는 쪽은 어느 설정으로 만들어졌는지
    /// 알 수 없다. 날짜만 시스템 로케일을 따른다 — 그것은 어휘가 아니라 사람이 시각을 읽는
    /// 방식이고, 도구는 기계가 읽는 형식에서 시각을 가져간다.
    static func render(
        startedAt: Date,
        segments: [TranscriptSegment.Record],
        audioFiles: [URL]
    ) -> String {
        let header = startedAt.formatted(date: .long, time: .shortened)
        var lines = ["# Meeting Transcript — \(header)", ""]
        if let qwen = segments.first(where: { $0.engine == "qwen3" }) {
            lines.append("Transcription engine: Qwen3 ASR — \(qwen.model ?? "unknown model")")
            lines.append("Timestamps describe input audio chunks, not exact utterance or word boundaries.")
            lines.append("")
        }

        if !audioFiles.isEmpty {
            lines.append("Meeting audio: " + audioFiles.map { url in
                let name = url.lastPathComponent
                let label = Speaker(rawValue: url.deletingPathExtension().lastPathComponent)?
                    .archiveName ?? name
                return "[\(label)](\(name))"
            }.joined(separator: " · "))
            lines.append("")
        }

        let sorted = segments.sorted { $0.start < $1.start }

        // 두 언어가 섞인 회의였다면 머리말에 적어 둔다.
        let languages = Set(sorted.compactMap(\.locale)).sorted()
        if languages.count > 1 {
            lines.append("Languages: " + languages.joined(separator: ", "))
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
            var heading = "**\(speaker.archiveName)** `\(formatTimecode(blockStart))`"
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
