import Foundation

/// Discovered-model registry for the pi coding agent.
///
/// Mirrors the ACP discovered-models pattern with a pi-specific store: the
/// Settings connect probe captures `get_available_models` output and registers
/// it here; the Agent Mode catalog consults the resolved options before
/// falling back to the Default-only static list. Snapshots persist to
/// UserDefaults so selections survive app restarts without a fresh probe.
final class PiModelRegistry {
    static let shared = PiModelRegistry()

    struct ModelRecord: Codable, Equatable {
        let id: String
        let name: String
        let provider: String
        let reasoning: Bool
        let contextWindow: Int
    }

    private static let storeKey = "PiDiscoveredModels"

    private let lock = NSLock()
    private var liveRecords: [ModelRecord] = []
    private var didLoadPersisted = false

    private init() {}

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

    /// Discovered records, Default placeholder excluded.
    func resolvedRecords() -> [ModelRecord] {
        lock.lock()
        defer { lock.unlock() }
        loadPersistedIfNeededLocked()
        return liveRecords
    }

    func contains(rawModel: String) -> Bool {
        let normalized = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        return resolvedRecords().contains {
            $0.id.caseInsensitiveCompare(normalized) == .orderedSame
        }
    }

    func contextWindow(forRaw rawModel: String) -> Int? {
        let normalized = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return resolvedRecords().first {
            $0.id.caseInsensitiveCompare(normalized) == .orderedSame
        }?.contextWindow
    }

    /// Catalog options: the Default placeholder first, then discovered models.
    /// Returns `nil` when nothing has been discovered yet so the caller falls
    /// back to the static list.
    func resolvedOptions() -> [AgentModelOption]? {
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
                rawValue: record.id,
                displayName: record.name.isEmpty ? record.id : record.name,
                description: record.provider.isEmpty ? nil : record.provider,
                isPlaceholderDefault: false,
                isProviderDefault: false
            )
        }
        return [fallback] + discovered
    }

    func clear() {
        lock.lock()
        liveRecords = []
        didLoadPersisted = true
        lock.unlock()
        UserDefaults.standard.removeObject(forKey: Self.storeKey)
    }

    // MARK: - Internals

    private func dedupe(_ records: [ModelRecord]) -> [ModelRecord] {
        var seen = Set<String>()
        return records.filter { record in
            let key = record.id.lowercased()
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    private func loadPersistedIfNeededLocked() {
        guard !didLoadPersisted else { return }
        didLoadPersisted = true
        guard let data = UserDefaults.standard.data(forKey: Self.storeKey),
              let decoded = try? JSONDecoder().decode([ModelRecord].self, from: data)
        else { return }
        liveRecords = decoded
    }

    private func persist(_ records: [ModelRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: Self.storeKey)
    }
}
