import Foundation

/// Discovered-model registry for the pi coding agent.
///
/// Mirrors the ACP discovered-models pattern with a pi-specific store: the
/// Settings connect probe captures `get_available_models` output and registers
/// it here; the Agent Mode catalog consults the resolved options before
/// falling back to the Default-only static list. Snapshots persist to
/// UserDefaults so selections survive app restarts without a fresh probe.
///
/// Exposed as an enum namespace (not a `static let shared` type) so the
/// modularization singleton ratchet stays flat while process-wide discovery
/// state remains available to Settings, catalog, and Agent Mode callers.
enum PiModelRegistry {
    struct ModelRecord: Codable, Equatable {
        let id: String
        let name: String
        let provider: String
        let reasoning: Bool
        let contextWindow: Int
        let inputTypes: [String]
        /// pi `thinkingLevelMap` effective levels (`off`…`max`) in canonical order.
        let thinkingLevels: [String]

        init(
            id: String,
            name: String,
            provider: String,
            reasoning: Bool,
            contextWindow: Int,
            inputTypes: [String] = ["text"],
            thinkingLevels: [String] = []
        ) {
            self.id = id
            self.name = name
            self.provider = provider
            self.reasoning = reasoning
            self.contextWindow = contextWindow
            self.inputTypes = inputTypes
            self.thinkingLevels = thinkingLevels
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            provider = try container.decode(String.self, forKey: .provider)
            reasoning = try container.decode(Bool.self, forKey: .reasoning)
            contextWindow = try container.decode(Int.self, forKey: .contextWindow)
            inputTypes = try container.decodeIfPresent([String].self, forKey: .inputTypes) ?? ["text"]
            thinkingLevels = try container.decodeIfPresent([String].self, forKey: .thinkingLevels) ?? []
        }

        /// Stable picker value. Prefix with `provider/` so later `set_model` keeps
        /// the originating auth family (ids like `grok` collide across providers).
        var catalogRawValue: String {
            let trimmedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedProvider.isEmpty { return id }
            return "\(trimmedProvider)/\(id)"
        }

        var catalogDisplayName: String {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedName.isEmpty ? id : trimmedName
        }
    }

    private static let storeKey = "PiDiscoveredModels"
    private static let store = Store()

    /// Registers a discovery snapshot. Returns whether the resolved records changed.
    @discardableResult
    static func update(records: [ModelRecord]) -> Bool {
        store.update(records: records)
    }

    static func records(from descriptors: [PiProviderRuntimeBridge.ModelDescriptor]) -> [ModelRecord] {
        descriptors.map { model in
            ModelRecord(
                id: model.id,
                name: model.name,
                provider: model.provider,
                reasoning: model.reasoning,
                contextWindow: model.contextWindow,
                inputTypes: model.inputTypes,
                thinkingLevels: model.effectiveThinkingLevels().map(\.rawValue)
            )
        }
    }

    /// Discovered records, Default placeholder excluded.
    static func resolvedRecords() -> [ModelRecord] {
        store.resolvedRecords()
    }

    static func contains(rawModel: String) -> Bool {
        record(matchingRaw: rawModel) != nil
    }

    static func contextWindow(forRaw rawModel: String) -> Int? {
        record(matchingRaw: rawModel)?.contextWindow
    }

    static func record(matchingRaw rawModel: String) -> ModelRecord? {
        let normalized = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let records = resolvedRecords()
        if let exact = records.first(where: {
            $0.catalogRawValue.caseInsensitiveCompare(normalized) == .orderedSame
        }) {
            return exact
        }
        return records.first {
            $0.id.caseInsensitiveCompare(normalized) == .orderedSame
        }
    }

    /// Thinking levels advertised for the selected model, in canonical pi order.
    /// Default / unknown models expose the standard `off`…`high` set so the picker
    /// is usable before a connect snapshot arrives.
    static func thinkingLevels(forRaw rawModel: String) -> [PiProviderRuntimeBridge.ThinkingLevel] {
        let normalized = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty || normalized == AgentModel.defaultModel.rawValue {
            return Self.defaultThinkingLevels
        }
        guard let record = record(matchingRaw: normalized) else {
            return Self.defaultThinkingLevels
        }
        if !record.reasoning {
            return [.off]
        }
        let decoded = record.thinkingLevels.compactMap(PiProviderRuntimeBridge.ThinkingLevel.init(rawValue:))
        return decoded.isEmpty ? Self.defaultThinkingLevels : decoded
    }

    /// Codex-shaped effort options for the Agent Mode chip. pi `off` maps to
    /// `CodexReasoningEffort.none`; `ultra` is never advertised.
    static func reasoningEffortOptions(forRaw rawModel: String) -> [CodexReasoningEffort] {
        thinkingLevels(forRaw: rawModel).map(codexEffort(for:))
    }

    static func displayName(forThinkingLevelRaw raw: String?) -> String {
        let normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if normalized.isEmpty {
            return CodexReasoningEffort.none.displayName
        }
        if let effort = CodexReasoningEffort.parse(normalized == "off" ? "none" : normalized) {
            return effort.displayName
        }
        return raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? CodexReasoningEffort.none.displayName
    }

    static func piThinkingLevelRaw(fromCodexEffort effort: CodexReasoningEffort?) -> String {
        guard let effort else { return "off" }
        switch effort {
        case .none:
            return "off"
        case .minimal:
            return "minimal"
        case .low:
            return "low"
        case .medium:
            return "medium"
        case .high:
            return "high"
        case .xhigh:
            return "xhigh"
        case .max, .ultra:
            return "max"
        }
    }

    static func nativeEffortLevel(fromThinkingLevelRaw raw: String?) -> NativeAgentRuntimeEffortLevel? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "low": .low
        case "medium": .medium
        case "high": .high
        case "xhigh", "x-high": .xhigh
        case "max": .max
        default: nil
        }
    }

    private static let defaultThinkingLevels: [PiProviderRuntimeBridge.ThinkingLevel] = [
        .off, .minimal, .low, .medium, .high
    ]

    private static func codexEffort(for level: PiProviderRuntimeBridge.ThinkingLevel) -> CodexReasoningEffort {
        switch level {
        case .off: CodexReasoningEffort.none
        case .minimal: .minimal
        case .low: .low
        case .medium: .medium
        case .high: .high
        case .xhigh: .xhigh
        case .max: .max
        }
    }

    /// Whether the selected model advertises image input. Unknown / Default
    /// selections are treated as image-capable so a first-run connect snapshot
    /// that omitted `input` does not block composer attachments.
    static func modelAcceptsImages(rawModel: String) -> Bool {
        let normalized = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty || normalized == AgentModel.defaultModel.rawValue {
            return true
        }
        guard let record = record(matchingRaw: normalized) else {
            return true
        }
        let types = record.inputTypes.map { $0.lowercased() }
        guard !types.isEmpty else { return true }
        return types.contains(where: { $0 == "image" || $0.hasPrefix("image/") })
    }

    /// Catalog options: the Default placeholder first, then discovered models.
    /// Returns `nil` when nothing has been discovered yet so the caller falls
    /// back to the static list.
    static func resolvedOptions() -> [AgentModelOption]? {
        let records = resolvedRecords()
        guard !records.isEmpty else { return nil }
        let fallback = AgentModelOption(
            rawValue: AgentModel.defaultModel.rawValue,
            displayName: AgentModel.defaultModel.displayName,
            description: AgentModel.defaultModel.description,
            isPlaceholderDefault: true,
            isProviderDefault: false
        )
        let discovered = records.map { record in
            AgentModelOption(
                rawValue: record.catalogRawValue,
                displayName: record.catalogDisplayName,
                description: record.provider.isEmpty ? nil : record.provider,
                isPlaceholderDefault: false,
                isProviderDefault: false
            )
        }
        return [fallback] + discovered
    }

    static func clear() {
        store.clear()
    }

    // MARK: - Store

    private final class Store {
        private let lock = NSLock()
        private var liveRecords: [ModelRecord] = []
        private var didLoadPersisted = false

        /// Registers a discovery snapshot. Returns whether the resolved records changed.
        @discardableResult
        func update(records: [ModelRecord]) -> Bool {
            let deduped = dedupe(records)
            let sorted = deduped.sorted {
                if $0.provider != $1.provider {
                    return $0.provider < $1.provider
                }
                return $0.id < $1.id
            }
            lock.lock()
            loadPersistedIfNeededLocked()
            let didChange = liveRecords != sorted
            if didChange {
                liveRecords = sorted
            }
            lock.unlock()
            if didChange {
                persist(sorted)
            }
            return didChange
        }

        func resolvedRecords() -> [ModelRecord] {
            lock.lock()
            defer { lock.unlock() }
            loadPersistedIfNeededLocked()
            return liveRecords
        }

        func clear() {
            lock.lock()
            liveRecords = []
            didLoadPersisted = true
            lock.unlock()
            UserDefaults.standard.removeObject(forKey: PiModelRegistry.storeKey)
        }

        private func dedupe(_ records: [ModelRecord]) -> [ModelRecord] {
            var seen = Set<String>()
            return records.filter { record in
                let key = record.catalogRawValue.lowercased()
                guard !seen.contains(key) else { return false }
                seen.insert(key)
                return true
            }
        }

        private func loadPersistedIfNeededLocked() {
            guard !didLoadPersisted else { return }
            didLoadPersisted = true
            guard let data = UserDefaults.standard.data(forKey: PiModelRegistry.storeKey),
                  let decoded = try? JSONDecoder().decode([ModelRecord].self, from: data)
            else { return }
            liveRecords = decoded
        }

        private func persist(_ records: [ModelRecord]) {
            guard let data = try? JSONEncoder().encode(records) else { return }
            UserDefaults.standard.set(data, forKey: PiModelRegistry.storeKey)
        }
    }
}
