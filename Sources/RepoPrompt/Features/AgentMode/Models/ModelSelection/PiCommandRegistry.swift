import Foundation

/// Last-seen `get_commands` snapshot for idle Pi slash suggestions.
///
/// Live Agent Mode sessions prefer the running controller. This registry keeps
/// Settings-connect and previous-run commands so `/` works before the first
/// managed `pi --mode rpc` process is up.
enum PiCommandRegistry {
    struct CommandRecord: Codable, Equatable {
        let name: String
        let description: String?
        let source: String?
    }

    private static let storeKey = "PiDiscoveredCommands"
    private static let store = Store()

    @discardableResult
    static func update(commands: [PiProviderRuntimeBridge.DiscoveredCommand]) -> Bool {
        store.update(records: commands.map {
            CommandRecord(name: $0.name, description: $0.description, source: $0.source)
        })
    }

    static func resolvedCommands() -> [PiProviderRuntimeBridge.DiscoveredCommand] {
        store.resolvedRecords().map {
            PiProviderRuntimeBridge.DiscoveredCommand(
                name: $0.name,
                description: $0.description,
                source: $0.source
            )
        }
    }

    static func clear() {
        store.clear()
    }

    private final class Store {
        private let lock = NSLock()
        private var liveRecords: [CommandRecord] = []
        private var didLoadPersisted = false

        @discardableResult
        func update(records: [CommandRecord]) -> Bool {
            let deduped = dedupe(records)
            lock.lock()
            loadPersistedIfNeededLocked()
            let didChange = liveRecords != deduped
            if didChange {
                liveRecords = deduped
            }
            lock.unlock()
            if didChange {
                persist(deduped)
            }
            return didChange
        }

        func resolvedRecords() -> [CommandRecord] {
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
            UserDefaults.standard.removeObject(forKey: PiCommandRegistry.storeKey)
        }

        private func dedupe(_ records: [CommandRecord]) -> [CommandRecord] {
            var seen = Set<String>()
            return records.filter { record in
                let key = record.name.lowercased()
                guard !seen.contains(key) else { return false }
                seen.insert(key)
                return true
            }
        }

        private func loadPersistedIfNeededLocked() {
            guard !didLoadPersisted else { return }
            didLoadPersisted = true
            guard let data = UserDefaults.standard.data(forKey: PiCommandRegistry.storeKey),
                  let decoded = try? JSONDecoder().decode([CommandRecord].self, from: data)
            else { return }
            liveRecords = decoded
        }

        private func persist(_ records: [CommandRecord]) {
            guard let data = try? JSONEncoder().encode(records) else { return }
            UserDefaults.standard.set(data, forKey: PiCommandRegistry.storeKey)
        }
    }
}
