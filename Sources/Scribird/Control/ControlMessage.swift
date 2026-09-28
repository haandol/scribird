import Foundation

/// 로컬 제어 메시지는 JSON 값만 액터 사이로 전달한다.
enum ControlValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), array([ControlValue])
    case object([String: ControlValue]), null

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode([ControlValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String: ControlValue].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    static func optional(_ value: String?) -> Self { value.map(Self.string) ?? .null }
    static func finite(_ value: Double) -> Self { value.isFinite ? .number(value) : .null }
    static func strings(_ values: [String]) -> Self { .array(values.map(Self.string)) }
    static func encoded<T: Encodable>(_ value: T) throws -> Self {
        try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
    }
    var string: String? { if case .string(let v) = self { v } else { nil } }
    var object: [String: Self]? { if case .object(let v) = self { v } else { nil } }
}

struct ControlRequest: Codable, Sendable {
    let command: String
    var arguments: [String: ControlValue] = [:]
}

struct ControlResponse: Codable, Sendable {
    let result: ControlValue?
    let error: String?

    static func success(_ result: ControlValue) -> Self { Self(result: result, error: nil) }
    static func failure(_ error: String) -> Self { Self(result: nil, error: error) }
}

struct ControlError: LocalizedError {
    let errorDescription: String?
    init(_ korean: String, _ english: String) { errorDescription = tr(korean, english) }
}

struct ControlArguments {
    let values: [String: ControlValue]

    func validate(keys: Set<String>) throws {
        guard Set(values.keys).isSubset(of: keys) else {
            throw ControlError("알 수 없는 인자가 있습니다.", "Unknown command arguments.")
        }
    }

    func string(_ key: String, required: Bool = true) throws -> String? {
        guard let value = values[key] else {
            if !required { return nil }
            throw invalid(key)
        }
        guard case .string(let result) = value, !result.isEmpty else { throw invalid(key) }
        return result
    }

    func bool(_ key: String) throws -> Bool? {
        guard let value = values[key] else { return nil }
        guard case .bool(let result) = value else { throw invalid(key) }
        return result
    }

    /// null은 기본값 복원이고, 키 누락이나 빈 문자열은 잘못된 입력이다.
    func nullableString(_ key: String) throws -> String? {
        values[key] == .null ? nil : try string(key)
    }

    func requiredEnum<T: RawRepresentable>(_ key: String) throws -> T where T.RawValue == String {
        guard let raw = try string(key), let value = T(rawValue: raw) else { throw invalid(key) }
        return value
    }

    func integer(_ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let value = values[key] else { return fallback }
        guard case .number(let number) = value, number.isFinite,
              number >= Double(range.lowerBound), number <= Double(range.upperBound),
              number.rounded() == number, let result = Int(exactly: number) else { throw invalid(key) }
        return result
    }

    func invalid(_ key: String) -> ControlError {
        ControlError("잘못된 인자: \(key)", "Invalid argument: \(key)")
    }
}
