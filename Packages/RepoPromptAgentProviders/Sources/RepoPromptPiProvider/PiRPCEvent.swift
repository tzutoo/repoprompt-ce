import Foundation

/// A pi RPC response (stdout, `type: "response"`). Correlated with the request `id`
/// when one was provided. `success: true` means the command was accepted; failures
/// after acceptance surface through the normal event/message stream.
public struct PiRPCResponse: Equatable, Sendable {
    public let id: String?
    public let command: String
    public let success: Bool
    public let errorMessage: String?
    public let data: PiJSONValue?

    public init?(json: PiJSONValue) {
        guard let object = json.objectValue else { return nil }
        guard object["type"]?.stringValue == "response" else { return nil }
        guard let command = object["command"]?.stringValue else { return nil }
        id = object["id"]?.stringValue
        self.command = command
        success = object["success"]?.boolValue ?? false
        if case let .string(error)? = object["error"] {
            errorMessage = error
        } else {
            errorMessage = nil
        }
        if let data = object["data"], !data.isNull {
            self.data = data
        } else {
            data = nil
        }
    }
}

/// Streaming delta carried by `message_update` events. Delta-only: clients assemble
/// live partial messages from `message_start` + `contentIndex`; `message_end.message`
/// is authoritative.
public enum PiAssistantMessageDelta: Equatable, Sendable {
    case textStart(contentIndex: Int)
    case textDelta(contentIndex: Int, delta: String)
    case textEnd(contentIndex: Int, content: String)
    case thinkingStart(contentIndex: Int)
    case thinkingDelta(contentIndex: Int, delta: String)
    case thinkingEnd(contentIndex: Int)
    case toolCallStart(contentIndex: Int, id: String, toolName: String)
    case toolCallDelta(contentIndex: Int, delta: String)
    case toolCallEnd(contentIndex: Int, toolCall: PiContentBlock?)

    public init?(json: PiJSONValue) {
        guard let object = json.objectValue, let type = object["type"]?.stringValue else { return nil }
        let contentIndex = object["contentIndex"]?.intValue ?? 0
        switch type {
        case "text_start":
            self = .textStart(contentIndex: contentIndex)
        case "text_delta":
            self = .textDelta(contentIndex: contentIndex, delta: object["delta"]?.stringValue ?? "")
        case "text_end":
            self = .textEnd(contentIndex: contentIndex, content: object["content"]?.stringValue ?? "")
        case "thinking_start":
            self = .thinkingStart(contentIndex: contentIndex)
        case "thinking_delta":
            self = .thinkingDelta(contentIndex: contentIndex, delta: object["delta"]?.stringValue ?? "")
        case "thinking_end":
            self = .thinkingEnd(contentIndex: contentIndex)
        case "toolcall_start":
            self = .toolCallStart(
                contentIndex: contentIndex,
                id: object["id"]?.stringValue ?? "",
                toolName: object["toolName"]?.stringValue ?? ""
            )
        case "toolcall_delta":
            self = .toolCallDelta(contentIndex: contentIndex, delta: object["delta"]?.stringValue ?? "")
        case "toolcall_end":
            self = .toolCallEnd(contentIndex: contentIndex, toolCall: object["toolCall"].flatMap(PiContentBlock.init(json:)))
        default:
            return nil
        }
    }
}

/// Dialog/fire-and-forget request raised by an extension. Dialog methods
/// (`select`/`confirm`/`input`/`editor`) block the extension until the client replies
/// with `extension_ui_response`; RPCE's gate extension relies on this path.
public struct PiExtensionUIRequest: Equatable, Sendable {
    public enum Method: String, Sendable {
        case select
        case confirm
        case input
        case editor
        case notify
        case setStatus
        case setWidget
        case setTitle
        case setEditorText = "set_editor_text"
    }

    public let id: String
    public let method: Method
    public let title: String?
    public let message: String?
    public let options: [String]
    public let timeoutMilliseconds: Int?
    public let prefill: String?
    public let placeholder: String?
    public let notifyType: String?
    public let raw: PiJSONValue

    public var isDialog: Bool {
        switch method {
        case .select, .confirm, .input, .editor: true
        case .notify, .setStatus, .setWidget, .setTitle, .setEditorText: false
        }
    }

    public init?(json: PiJSONValue) {
        guard let object = json.objectValue else { return nil }
        guard object["type"]?.stringValue == "extension_ui_request" else { return nil }
        guard let id = object["id"]?.stringValue,
              let methodRaw = object["method"]?.stringValue,
              let method = Method(rawValue: methodRaw)
        else { return nil }
        self.id = id
        self.method = method
        title = object["title"]?.stringValue
        message = object["message"]?.stringValue
        options = object["options"]?.arrayValue?.compactMap(\.stringValue) ?? []
        timeoutMilliseconds = object["timeout"]?.intValue
        prefill = object["prefill"]?.stringValue
        placeholder = object["placeholder"]?.stringValue
        notifyType = object["notifyType"]?.stringValue
        raw = json
    }
}

/// A pi RPC event (stdout). Typed coverage follows the surfaces RPCE consumes; every
/// other event decodes as `.unknown` carrying its raw payload so a controller can
/// forward or ignore without failing the stream.
public enum PiRPCEvent: Equatable, Sendable {
    case agentStart
    case agentEnd(messages: [PiAgentMessage], willRetry: Bool)
    case agentSettled
    case turnStart
    case turnEnd(message: PiAgentMessage?, toolResults: [PiAgentMessage])
    case messageStart(message: PiAgentMessage?)
    case messageUpdate(usage: PiTokenUsage?, delta: PiAssistantMessageDelta?)
    case messageEnd(message: PiAgentMessage?)
    case toolExecutionStart(toolCallId: String, toolName: String, arguments: PiJSONValue)
    case toolExecutionUpdate(toolCallId: String, toolName: String, partialResult: PiJSONValue?)
    case toolExecutionEnd(toolCallId: String, toolName: String, result: PiJSONValue?, isError: Bool)
    case queueUpdate(steering: [String], followUp: [String])
    case compactionStart(reason: String?)
    case compactionEnd(
        reason: String?,
        summary: String?,
        aborted: Bool,
        willRetry: Bool,
        errorMessage: String?
    )
    case autoRetryStart(attempt: Int, maxAttempts: Int, delayMilliseconds: Int, errorMessage: String?)
    case autoRetryEnd(success: Bool, attempt: Int, finalError: String?)
    case bashExecutionUpdate(id: String?, delta: String)
    case extensionError(extensionPath: String?, event: String?, message: String?)
    case extensionUIRequest(PiExtensionUIRequest)
    case unknown(type: String, raw: PiJSONValue)

    public init(json: PiJSONValue) {
        guard let object = json.objectValue, let type = object["type"]?.stringValue else {
            self = .unknown(type: "", raw: json)
            return
        }
        switch type {
        case "agent_start":
            self = .agentStart
        case "agent_end":
            let messages = (object["messages"]?.arrayValue ?? []).compactMap(PiAgentMessage.init(json:))
            self = .agentEnd(messages: messages, willRetry: object["willRetry"]?.boolValue ?? false)
        case "agent_settled":
            self = .agentSettled
        case "turn_start":
            self = .turnStart
        case "turn_end":
            let toolResults = (object["toolResults"]?.arrayValue ?? []).compactMap(PiAgentMessage.init(json:))
            self = .turnEnd(message: object["message"].flatMap(PiAgentMessage.init(json:)), toolResults: toolResults)
        case "message_start":
            self = .messageStart(message: object["message"].flatMap(PiAgentMessage.init(json:)))
        case "message_update":
            self = .messageUpdate(
                usage: object["usage"].flatMap(PiTokenUsage.init(json:)),
                delta: object["assistantMessageEvent"].flatMap(PiAssistantMessageDelta.init(json:))
            )
        case "message_end":
            self = .messageEnd(message: object["message"].flatMap(PiAgentMessage.init(json:)))
        case "tool_execution_start":
            self = .toolExecutionStart(
                toolCallId: object["toolCallId"]?.stringValue ?? "",
                toolName: object["toolName"]?.stringValue ?? "",
                arguments: object["args"] ?? .object([:])
            )
        case "tool_execution_update":
            self = .toolExecutionUpdate(
                toolCallId: object["toolCallId"]?.stringValue ?? "",
                toolName: object["toolName"]?.stringValue ?? "",
                partialResult: object["partialResult"]
            )
        case "tool_execution_end":
            self = .toolExecutionEnd(
                toolCallId: object["toolCallId"]?.stringValue ?? "",
                toolName: object["toolName"]?.stringValue ?? "",
                result: object["result"],
                isError: object["isError"]?.boolValue ?? false
            )
        case "queue_update":
            self = .queueUpdate(
                steering: object["steering"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                followUp: object["followUp"]?.arrayValue?.compactMap(\.stringValue) ?? []
            )
        case "compaction_start":
            self = .compactionStart(reason: object["reason"]?.stringValue)
        case "compaction_end":
            self = .compactionEnd(
                reason: object["reason"]?.stringValue,
                summary: object["result"]?["summary"]?.stringValue,
                aborted: object["aborted"]?.boolValue ?? false,
                willRetry: object["willRetry"]?.boolValue ?? false,
                errorMessage: object["errorMessage"]?.stringValue
            )
        case "auto_retry_start":
            self = .autoRetryStart(
                attempt: object["attempt"]?.intValue ?? 0,
                maxAttempts: object["maxAttempts"]?.intValue ?? 0,
                delayMilliseconds: object["delayMs"]?.intValue ?? 0,
                errorMessage: object["errorMessage"]?.stringValue
            )
        case "auto_retry_end":
            self = .autoRetryEnd(
                success: object["success"]?.boolValue ?? false,
                attempt: object["attempt"]?.intValue ?? 0,
                finalError: object["finalError"]?.stringValue
            )
        case "bash_execution_update":
            self = .bashExecutionUpdate(id: object["id"]?.stringValue, delta: object["delta"]?.stringValue ?? "")
        case "extension_error":
            self = .extensionError(
                extensionPath: object["extensionPath"]?.stringValue,
                event: object["event"]?.stringValue,
                message: object["error"]?.stringValue
            )
        case "extension_ui_request":
            if let request = PiExtensionUIRequest(json: json) {
                self = .extensionUIRequest(request)
            } else {
                self = .unknown(type: type, raw: json)
            }
        default:
            self = .unknown(type: type, raw: json)
        }
    }

    /// Decodes one complete stdout line into an event.
    public init(line: Data) throws {
        try self.init(json: PiRPCWire.decodeLine(line))
    }
}
