import Foundation

extension AppControl {
    var stateName: String {
        switch recorder.state {
        case .idle: "idle"
        case .preparingModel: "preparing"
        case .recording: "recording"
        case .stopping: "stopping"
        case .failed: "failed"
        }
    }

    /// Reports archive warnings separately so successful transcription remains distinguishable from audio loss.
    func status() -> ControlValue {
        let failure: String? = if case .failed(let failure) = recorder.state { failure.message } else { nil }
        return .object([
            "protocolVersion": .number(1), "pid": .number(Double(getpid())),
            "executable": .optional(Bundle.main.executablePath),
            "commands": .strings(Self.commands), "state": .string(stateName),
            "pendingCommand": .optional(pendingCommand), "language": .string(recorder.language.rawValue),
            "engine": .string(recorder.engine.rawValue),
            "availableLanguages": .strings(recorder.availableLanguages.map(\.rawValue)),
            "microphoneMuted": .bool(recorder.microphoneMuted),
            "activeSources": .strings(recorder.activeSources.map(\.rawValue).sorted()),
            "currentSessionDirectory": .optional(recorder.currentSessionDirectory?.path),
            "lastSessionDirectory": .optional(recorder.lastSessionDirectory?.path),
            "startedAt": .optional(recorder.startedAt.map { ISO8601DateFormatter().string(from: $0) }),
            "segmentCount": .number(Double(recorder.segments.count)), "error": .optional(failure),
            "warnings": .strings([
                recorder.sourceWarning, recorder.modelRetentionWarning, recorder.languageSwitchWarning,
                recorder.rootFallbackWarning, connectionError,
                recorder.transcriptionWarning,
                recorder.audioStorageWarning,
                recorder.inputDeliveryWarning,
            ].compactMap { $0 }),
            "sources": .array(Speaker.allCases.map { speaker in
                let level = recorder.inputLevel(for: speaker)
                return .object([
                    "speaker": .string(speaker.rawValue), "active": .bool(recorder.activeSources.contains(speaker)),
                    "silent": .bool(recorder.isSilent(speaker)),
                    "decibels": level.map { .finite(Double($0.decibels)) } ?? .null,
                    "meter": level.map { .finite(Double($0.meter)) } ?? .null,
                ])
            }),
            "microphoneTooQuiet": .bool(recorder.microphoneIsTooQuiet),
            "updates": updateStatus(),
        ])
    }

    func liveTranscript(_ args: ControlArguments) throws -> ControlValue {
        let partial = try args.bool("include_partial") ?? true
        let offset = try args.integer("offset", default: 0, range: 0...Int.max)
        let limit = try args.integer("limit", default: 200, range: 1...1000)
        let segments = recorder.segments.filter { partial || $0.isFinal }
        let page = Array(segments.dropFirst(offset).prefix(limit))
        return .object([
            "sessionDirectory": .optional((recorder.currentSessionDirectory ?? recorder.lastSessionDirectory)?.path),
            "state": .string(stateName), "total": .number(Double(segments.count)),
            "offset": .number(Double(offset)), "hasMore": .bool(offset < segments.count - page.count),
            "segments": .array(try page.map { segment in
                var value = try ControlValue.encoded(segment.record).object ?? [:]
                value["isFinal"] = .bool(segment.isFinal)
                return .object(value)
            }),
        ])
    }
}
