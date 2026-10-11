import Foundation

/// Errors surfaced by the pi provider package. The package is Foundation-only and
/// deliberately has no dependency on app code, persistence, or secure storage.
public enum PiProviderError: Error, Equatable, Sendable {
    case invalidConfiguration(detail: String)
    case framing(detail: String)
}

extension PiProviderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(detail):
            "Invalid pi provider configuration: \(detail)"
        case let .framing(detail):
            "Invalid pi RPC framing: \(detail)"
        }
    }
}

/// Sendable JSON value used by all pi provider DTOs instead of exposing
/// `[String: Any]`. Mirrors the wire format documented in pi's `docs/rpc.md`.
public enum PiJSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case integer(Int)
    case double(Double)
    case string(String)
    case array([PiJSONValue])
    case object([String: PiJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([PiJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: PiJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .double(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case let .integer(value): value
        case let .double(value): Int(exactly: value)
        default: nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case let .integer(value): Double(value)
        case let .double(value): value
        default: nil
        }
    }

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var arrayValue: [PiJSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    public var objectValue: [String: PiJSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    public subscript(key: String) -> PiJSONValue? {
        objectValue?[key]
    }

    public subscript(index: Int) -> PiJSONValue? {
        guard let arrayValue, arrayValue.indices.contains(index) else { return nil }
        return arrayValue[index]
    }

    /// Compact JSON object/array suitable for embedding in generated TypeScript.
    public func encodedJSONString() throws -> String {
        let object: Any = jsonObject()
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw PiProviderError.framing(detail: "failed encoding JSON value")
        }
        return text
    }

    private func jsonObject() -> Any {
        switch self {
        case .null:
            NSNull()
        case let .bool(value):
            value
        case let .integer(value):
            value
        case let .double(value):
            value
        case let .string(value):
            value
        case let .array(value):
            value.map { $0.jsonObject() }
        case let .object(value):
            value.mapValues { $0.jsonObject() }
        }
    }
}
