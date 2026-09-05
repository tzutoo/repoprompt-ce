import Foundation

/// pi thinking levels (`off`…`max`), as used by `set_thinking_level` and model metadata.
public enum PiThinkingLevel: String, CaseIterable, Sendable, Comparable {
    case off
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max

    /// Canonical ordering used to apply the "absent key" default: standard levels
    /// through `high` use the provider's default mapping; extended `xhigh`/`max` are
    /// unsupported when the map omits them.
    public var canonicalRank: Int {
        switch self {
        case .off: 0
        case .minimal: 1
        case .low: 2
        case .medium: 3
        case .high: 4
        case .xhigh: 5
        case .max: 6
        }
    }

    public static func < (lhs: PiThinkingLevel, rhs: PiThinkingLevel) -> Bool {
        lhs.canonicalRank < rhs.canonicalRank
    }
}

/// Tristate entry of a model's `thinkingLevelMap`.
public enum PiThinkingLevelMapping: Equatable, Sendable {
    /// Level is supported and this value is sent to the provider.
    case supported(providerValue: String)
    /// Level is unsupported (`null` on the wire); hidden/skipped/clamped away.
    case unsupported
}

/// A pi `Model` object as returned by `get_state`, `get_available_models`, `set_model`.
public struct PiModelDescriptor: Equatable, Sendable {
    public let id: String
    public let name: String
    public let provider: String
    public let api: String
    public let reasoning: Bool
    public let contextWindow: Int
    public let maxTokens: Int
    public let inputTypes: [String]
    public let thinkingLevelMap: [PiThinkingLevel: PiThinkingLevelMapping]
    public let raw: PiJSONValue

    public init?(json: PiJSONValue) {
        guard let object = json.objectValue, let id = object["id"]?.stringValue else { return nil }
        self.id = id
        name = object["name"]?.stringValue ?? id
        provider = object["provider"]?.stringValue ?? ""
        api = object["api"]?.stringValue ?? ""
        reasoning = object["reasoning"]?.boolValue ?? false
        contextWindow = object["contextWindow"]?.intValue ?? 128_000
        maxTokens = object["maxTokens"]?.intValue ?? 16384
        inputTypes = object["input"]?.arrayValue?.compactMap(\.stringValue) ?? ["text"]
        raw = json

        var map: [PiThinkingLevel: PiThinkingLevelMapping] = [:]
        if let mapObject = object["thinkingLevelMap"]?.objectValue {
            for (key, value) in mapObject {
                guard let level = PiThinkingLevel(rawValue: key) else { continue }
                if let providerValue = value.stringValue {
                    map[level] = .supported(providerValue: providerValue)
                } else {
                    map[level] = .unsupported
                }
            }
        }
        thinkingLevelMap = map
    }

    /// Effective thinking levels for this model in canonical order, applying the
    /// documented default for absent keys: absent standard levels (through `high`)
    /// stay supported; absent extended levels (`xhigh`, `max`) are unsupported.
    public func effectiveThinkingLevels() -> [PiThinkingLevel] {
        guard reasoning else { return [.off] }
        return PiThinkingLevel.allCases.filter { level in
            switch thinkingLevelMap[level] {
            case .supported:
                true
            case .unsupported:
                false
            case nil:
                level <= .high
            }
        }
    }
}

/// `get_state` response payload.
public struct PiSessionState: Equatable, Sendable {
    public let model: PiModelDescriptor?
    public let thinkingLevel: String?
    public let isStreaming: Bool
    public let isCompacting: Bool
    public let steeringMode: String?
    public let followUpMode: String?
    public let sessionFile: String?
    public let sessionId: String?
    public let sessionName: String?
    public let autoCompactionEnabled: Bool
    public let messageCount: Int
    public let pendingMessageCount: Int

    public init?(json: PiJSONValue) {
        guard let object = json.objectValue else { return nil }
        model = object["model"].flatMap(PiModelDescriptor.init(json:))
        thinkingLevel = object["thinkingLevel"]?.stringValue
        isStreaming = object["isStreaming"]?.boolValue ?? false
        isCompacting = object["isCompacting"]?.boolValue ?? false
        steeringMode = object["steeringMode"]?.stringValue
        followUpMode = object["followUpMode"]?.stringValue
        sessionFile = object["sessionFile"]?.stringValue
        sessionId = object["sessionId"]?.stringValue
        sessionName = object["sessionName"]?.stringValue
        autoCompactionEnabled = object["autoCompactionEnabled"]?.boolValue ?? true
        messageCount = object["messageCount"]?.intValue ?? 0
        pendingMessageCount = object["pendingMessageCount"]?.intValue ?? 0
    }
}

/// `get_session_stats` response payload. `contextUsage` is omitted when no model or
/// context window is available, and its token/percent fields are `null` immediately
/// after compaction until a fresh assistant response provides usage.
public struct PiSessionStats: Equatable, Sendable {
    public struct ContextUsage: Equatable, Sendable {
        public let tokens: Int?
        public let contextWindow: Int
        public let percent: Double?
    }

    public let sessionId: String?
    public let sessionFile: String?
    public let userMessages: Int
    public let assistantMessages: Int
    public let toolCalls: Int
    public let toolResults: Int
    public let totalMessages: Int
    public let usage: PiTokenUsage?
    public let cost: Double
    public let contextUsage: ContextUsage?

    public init?(json: PiJSONValue) {
        guard let object = json.objectValue else { return nil }
        sessionId = object["sessionId"]?.stringValue
        sessionFile = object["sessionFile"]?.stringValue
        userMessages = object["userMessages"]?.intValue ?? 0
        assistantMessages = object["assistantMessages"]?.intValue ?? 0
        toolCalls = object["toolCalls"]?.intValue ?? 0
        toolResults = object["toolResults"]?.intValue ?? 0
        totalMessages = object["totalMessages"]?.intValue ?? 0
        usage = object["tokens"].flatMap(PiTokenUsage.init(json:))
        cost = object["cost"]?.doubleValue ?? 0
        if let contextObject = object["contextUsage"]?.objectValue {
            contextUsage = ContextUsage(
                tokens: contextObject["tokens"]?.intValue,
                contextWindow: contextObject["contextWindow"]?.intValue ?? 0,
                percent: contextObject["percent"]?.doubleValue
            )
        } else {
            contextUsage = nil
        }
    }
}

/// `get_entries` response payload. Entry ids are durable cursors: pass the last seen
/// id as `since` to fetch only strictly newer entries, even across client restarts.
public struct PiSessionEntryList: Equatable, Sendable {
    public let entries: [PiJSONValue]
    public let leafId: String?

    public init?(json: PiJSONValue) {
        guard let object = json.objectValue else { return nil }
        entries = object["entries"]?.arrayValue ?? []
        if let leafId = object["leafId"]?.stringValue {
            self.leafId = leafId
        } else {
            leafId = nil
        }
    }
}
