import Foundation

/// Token usage reported by pi (cumulative, provider-reported).
public struct PiTokenUsage: Equatable, Sendable {
    public struct Cost: Equatable, Sendable {
        public var input: Double
        public var output: Double
        public var cacheRead: Double
        public var cacheWrite: Double
        public var total: Double

        public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double, total: Double) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
            self.total = total
        }
    }

    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var totalTokens: Int
    public var cost: Cost?

    public init(input: Int, output: Int, cacheRead: Int, cacheWrite: Int, totalTokens: Int, cost: Cost? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.totalTokens = totalTokens
        self.cost = cost
    }

    public init?(json: PiJSONValue) {
        guard let object = json.objectValue else { return nil }
        // Streaming usage reports `totalTokens`; `get_session_stats` reports `total`.
        let total = object["totalTokens"]?.intValue ?? object["total"]?.intValue ?? 0
        self.init(
            input: object["input"]?.intValue ?? 0,
            output: object["output"]?.intValue ?? 0,
            cacheRead: object["cacheRead"]?.intValue ?? 0,
            cacheWrite: object["cacheWrite"]?.intValue ?? 0,
            totalTokens: total,
            cost: object["cost"].flatMap(PiTokenUsage.Cost.init(json:))
        )
    }
}

extension PiTokenUsage.Cost {
    init?(json: PiJSONValue) {
        guard let object = json.objectValue else { return nil }
        self.init(
            input: object["input"]?.doubleValue ?? 0,
            output: object["output"]?.doubleValue ?? 0,
            cacheRead: object["cacheRead"]?.doubleValue ?? 0,
            cacheWrite: object["cacheWrite"]?.doubleValue ?? 0,
            total: object["total"]?.doubleValue ?? 0
        )
    }
}

/// Typed content block inside an assistant or tool-result message.
public enum PiContentBlock: Equatable, Sendable {
    case text(String)
    case thinking(String)
    case toolCall(id: String, name: String, arguments: PiJSONValue)
    case image(data: String, mimeType: String)

    public init?(json: PiJSONValue) {
        guard let object = json.objectValue, let type = object["type"]?.stringValue else { return nil }
        switch type {
        case "text":
            self = .text(object["text"]?.stringValue ?? "")
        case "thinking":
            self = .thinking(object["thinking"]?.stringValue ?? "")
        case "toolCall":
            self = .toolCall(
                id: object["id"]?.stringValue ?? "",
                name: object["name"]?.stringValue ?? "",
                arguments: object["arguments"] ?? .object([:])
            )
        case "image":
            self = .image(
                data: object["data"]?.stringValue ?? "",
                mimeType: object["mimeType"]?.stringValue ?? ""
            )
        default:
            return nil
        }
    }
}

/// A conversation message as it appears in events, `get_messages`, and `get_entries`.
public enum PiAgentMessage: Equatable, Sendable {
    case user(content: PiMessageContent)
    case assistant(
        content: [PiContentBlock],
        provider: String,
        model: String,
        usage: PiTokenUsage?,
        stopReason: String?,
        errorMessage: String?
    )
    case toolResult(
        toolCallId: String,
        toolName: String,
        content: [PiContentBlock],
        isError: Bool
    )
    /// Created by the direct RPC `bash` command, not by LLM tool calls.
    case bashExecution(command: String, output: String, exitCode: Int?, cancelled: Bool, truncated: Bool)

    public init?(json: PiJSONValue) {
        guard let object = json.objectValue else { return nil }
        guard let role = object["role"]?.stringValue else { return nil }
        switch role {
        case "user":
            guard let content = PiMessageContent(json: object["content"] ?? .null) else { return nil }
            self = .user(content: content)
        case "assistant":
            let blocks = (object["content"]?.arrayValue ?? []).compactMap(PiContentBlock.init(json:))
            self = .assistant(
                content: blocks,
                provider: object["provider"]?.stringValue ?? "",
                model: object["model"]?.stringValue ?? "",
                usage: object["usage"].flatMap(PiTokenUsage.init(json:)),
                stopReason: object["stopReason"]?.stringValue,
                errorMessage: object["errorMessage"]?.stringValue
            )
        case "toolResult":
            let blocks = (object["content"]?.arrayValue ?? []).compactMap(PiContentBlock.init(json:))
            self = .toolResult(
                toolCallId: object["toolCallId"]?.stringValue ?? "",
                toolName: object["toolName"]?.stringValue ?? "",
                content: blocks,
                isError: object["isError"]?.boolValue ?? false
            )
        case "bashExecution":
            self = .bashExecution(
                command: object["command"]?.stringValue ?? "",
                output: object["output"]?.stringValue ?? "",
                exitCode: object["exitCode"]?.intValue,
                cancelled: object["cancelled"]?.boolValue ?? false,
                truncated: object["truncated"]?.boolValue ?? false
            )
        default:
            return nil
        }
    }
}

/// User-message content is either a plain string or a block array on the wire.
public enum PiMessageContent: Equatable, Sendable {
    case text(String)
    case blocks([PiContentBlock])

    public init?(json: PiJSONValue) {
        switch json {
        case let .string(text):
            self = .text(text)
        case let .array(values):
            self = .blocks(values.compactMap(PiContentBlock.init(json:)))
        default:
            return nil
        }
    }
}
