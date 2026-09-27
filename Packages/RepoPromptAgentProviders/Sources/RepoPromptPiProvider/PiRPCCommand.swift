import Foundation

/// A pi RPC command (stdin direction). Shapes follow pi's `docs/rpc.md`; every command
/// accepts an optional correlation `id` echoed by its response.
public enum PiRPCCommand: Equatable, Sendable {
    /// Send a user prompt. `streamingBehavior` is required when the agent is already
    /// streaming: `.steer` delivers after the current assistant turn finishes its tool
    /// calls; `.followUp` waits until the agent finishes all work.
    case prompt(message: String, images: [PiImageAttachment] = [], streamingBehavior: PiStreamingBehavior? = nil)
    /// Queue a steering message while the agent is running.
    case steer(message: String, images: [PiImageAttachment] = [])
    /// Queue a follow-up message to be delivered when the agent finishes.
    case followUp(message: String, images: [PiImageAttachment] = [])
    /// Abort the current operation and wait for the session to become idle.
    case abort
    /// Remove queued steering/follow-up messages; their text is returned in the response.
    case clearQueue
    /// Start a fresh session, optionally tracking a parent session file.
    case newSession(parentSession: String? = nil)
    /// Current session state (model, thinking level, streaming flags, session identity).
    case getState
    /// All messages in the conversation.
    case getMessages
    /// Append-ordered session entries; `since` is a durable entry-id cursor.
    case getEntries(since: String? = nil)
    /// The session as a tree of entries.
    case getTree
    /// Text of the last assistant message (`nil` text when none exists).
    case getLastAssistantText
    /// Switch to a specific model. Response carries the full model object.
    case setModel(provider: String, modelId: String)
    /// Set the reasoning/thinking level (`off`…`max`).
    case setThinkingLevel(level: String)
    /// List configured (authenticated) models.
    case getAvailableModels
    /// Thinking levels supported by the current model.
    case getAvailableThinkingLevels
    /// Manually compact context, with optional focus instructions.
    case compact(customInstructions: String? = nil)
    /// Enable or disable automatic compaction.
    case setAutoCompaction(enabled: Bool)
    /// How queued steering messages are delivered.
    case setSteeringMode(mode: PiQueueDeliveryMode)
    /// How queued follow-up messages are delivered.
    case setFollowUpMode(mode: PiQueueDeliveryMode)
    /// Token/cost statistics and current context-window usage.
    case getSessionStats
    /// Set a display name for the current session.
    case setSessionName(name: String)
    /// Load a different session file by path.
    case switchSession(sessionPath: String)
    /// Fork from a previous user message entry on the active branch.
    case fork(entryId: String)
    /// Duplicate the current active branch into a new session.
    case clone
    /// Direct shell command whose output joins the conversation context.
    case bash(command: String)
    /// Available extension commands, prompt templates, and skills (`/name`).
    case getCommands
    /// Abort a running direct `bash` command.
    case abortBash
    /// Answer an `extension_ui_request` dialog with a string value (select/input/editor).
    case extensionUIResponseValue(id: String, value: String)
    /// Answer an `extension_ui_request` confirm dialog.
    case extensionUIResponseConfirmed(id: String, confirmed: Bool)
    /// Cancel an `extension_ui_request` dialog.
    case extensionUIResponseCancelled(id: String)

    public func requestObject(id: String?) -> PiJSONValue {
        var object: [String: PiJSONValue] = [:]
        if let id {
            object["id"] = .string(id)
        }
        switch self {
        case let .prompt(message, images, streamingBehavior):
            object["type"] = .string("prompt")
            object["message"] = .string(message)
            if !images.isEmpty {
                object["images"] = .array(images.map(\.jsonValue))
            }
            if let streamingBehavior {
                object["streamingBehavior"] = .string(streamingBehavior.wireValue)
            }
        case let .steer(message, images):
            object["type"] = .string("steer")
            object["message"] = .string(message)
            if !images.isEmpty {
                object["images"] = .array(images.map(\.jsonValue))
            }
        case let .followUp(message, images):
            object["type"] = .string("follow_up")
            object["message"] = .string(message)
            if !images.isEmpty {
                object["images"] = .array(images.map(\.jsonValue))
            }
        case .abort:
            object["type"] = .string("abort")
        case .clearQueue:
            object["type"] = .string("clear_queue")
        case let .newSession(parentSession):
            object["type"] = .string("new_session")
            if let parentSession {
                object["parentSession"] = .string(parentSession)
            }
        case .getState:
            object["type"] = .string("get_state")
        case .getMessages:
            object["type"] = .string("get_messages")
        case let .getEntries(since):
            object["type"] = .string("get_entries")
            if let since {
                object["since"] = .string(since)
            }
        case .getTree:
            object["type"] = .string("get_tree")
        case .getLastAssistantText:
            object["type"] = .string("get_last_assistant_text")
        case let .setModel(provider, modelId):
            object["type"] = .string("set_model")
            if !provider.isEmpty {
                object["provider"] = .string(provider)
            }
            object["modelId"] = .string(modelId)
        case let .setThinkingLevel(level):
            object["type"] = .string("set_thinking_level")
            object["level"] = .string(level)
        case .getAvailableModels:
            object["type"] = .string("get_available_models")
        case .getAvailableThinkingLevels:
            object["type"] = .string("get_available_thinking_levels")
        case let .compact(customInstructions):
            object["type"] = .string("compact")
            if let customInstructions {
                object["customInstructions"] = .string(customInstructions)
            }
        case let .setAutoCompaction(enabled):
            object["type"] = .string("set_auto_compaction")
            object["enabled"] = .bool(enabled)
        case let .setSteeringMode(mode):
            object["type"] = .string("set_steering_mode")
            object["mode"] = .string(mode.wireValue)
        case let .setFollowUpMode(mode):
            object["type"] = .string("set_follow_up_mode")
            object["mode"] = .string(mode.wireValue)
        case .getSessionStats:
            object["type"] = .string("get_session_stats")
        case let .setSessionName(name):
            object["type"] = .string("set_session_name")
            object["name"] = .string(name)
        case let .switchSession(sessionPath):
            object["type"] = .string("switch_session")
            object["sessionPath"] = .string(sessionPath)
        case let .fork(entryId):
            object["type"] = .string("fork")
            object["entryId"] = .string(entryId)
        case .clone:
            object["type"] = .string("clone")
        case let .bash(command):
            object["type"] = .string("bash")
            object["command"] = .string(command)
        case .getCommands:
            object["type"] = .string("get_commands")
        case .abortBash:
            object["type"] = .string("abort_bash")
        case let .extensionUIResponseValue(id, value):
            object["type"] = .string("extension_ui_response")
            object["id"] = .string(id)
            object["value"] = .string(value)
        case let .extensionUIResponseConfirmed(id, confirmed):
            object["type"] = .string("extension_ui_response")
            object["id"] = .string(id)
            object["confirmed"] = .bool(confirmed)
        case let .extensionUIResponseCancelled(id):
            object["type"] = .string("extension_ui_response")
            object["id"] = .string(id)
            object["cancelled"] = .bool(true)
        }
        return .object(object)
    }
}

/// Delivery semantics for a prompt submitted while the agent is streaming.
public enum PiStreamingBehavior: Equatable, Sendable {
    case steer
    case followUp

    var wireValue: String {
        switch self {
        case .steer: "steer"
        case .followUp: "followUp"
        }
    }
}

/// Queue delivery modes for steering/follow-up messages.
public enum PiQueueDeliveryMode: Equatable, Sendable {
    case all
    case oneAtATime

    var wireValue: String {
        switch self {
        case .all: "all"
        case .oneAtATime: "one-at-a-time"
        }
    }
}

/// Image attachment on prompt/steer/follow-up commands (`ImageContent` wire shape).
public struct PiImageAttachment: Equatable, Sendable {
    public let data: String
    public let mimeType: String

    public init(data: String, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }

    var jsonValue: PiJSONValue {
        .object([
            "type": .string("image"),
            "data": .string(data),
            "mimeType": .string(mimeType)
        ])
    }
}
