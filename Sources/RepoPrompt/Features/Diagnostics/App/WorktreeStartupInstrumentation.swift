import Foundation

enum WorktreeStartupServingControl: Equatable {
    case automatic
    case forceFullCrawl
}

struct WorktreeStartupFeatureFlags: Equatable {
    static let observeDefaultsKey = "observeDiffSeededWorktreeStartup"
    static let serveDefaultsKey = "serveDiffSeededWorktreeStartup"

    let observeDiffSeededWorktreeStartup: Bool
    let serveDiffSeededWorktreeStartup: Bool

    init(
        observeDiffSeededWorktreeStartup: Bool = false,
        serveDiffSeededWorktreeStartup: Bool = false
    ) {
        self.observeDiffSeededWorktreeStartup = observeDiffSeededWorktreeStartup
        // Serving can never be active without observation authority.
        self.serveDiffSeededWorktreeStartup = serveDiffSeededWorktreeStartup
            && observeDiffSeededWorktreeStartup
    }

    static func current(defaults: UserDefaults = .standard) -> Self {
        Self(
            observeDiffSeededWorktreeStartup: defaults.bool(forKey: observeDefaultsKey),
            serveDiffSeededWorktreeStartup: defaults.bool(forKey: serveDefaultsKey)
        )
    }
}

struct WorktreeStartupContext: Equatable {
    let agentSessionID: UUID
    let correlationID: UUID
    let flags: WorktreeStartupFeatureFlags
    let servingControl: WorktreeStartupServingControl

    init(
        agentSessionID: UUID,
        correlationID: UUID = UUID(),
        flags: WorktreeStartupFeatureFlags = .current(),
        servingControl: WorktreeStartupServingControl = .automatic
    ) {
        self.agentSessionID = agentSessionID
        self.correlationID = correlationID
        self.flags = flags
        self.servingControl = servingControl
    }
}

enum WorkspaceRootStartupRoute: String, Equatable {
    case fullCrawl
    case diffSeedObservation
    case diffSeedServing
}

enum WorkspaceRootSeedFallbackReason: String, Equatable {
    case noReceipt
    case expiredReceipt
    case unsupportedDestination
    case baseUnavailable
    case baseEvicted
    case compatibilityMismatch
    case authorityChanging
    case authorityUnstable
    case gitTimeout
    case gitError
    case gitMalformedOutput
    case gitCappedOutput
    case witnessGap
    case witnessDrop
    case witnessOverflow
    case includeCopyFailure
    case unknownCopiedPath
    case changedIgnoreAuthority
    case conflictOrUnmergedIndex
    case assumeUnchangedIndexEntry
    case sparseCheckout
    case submoduleOrNestedRepository
    case symlinkOrSpecialTopology
    case verificationLimitExceeded
    case unexplainedFilesystemEntry
    case projectedSearchMismatch
    case overlayThresholdExceeded
    case ownerSuperseded
    case serviceIngressGenerationChanged
    case watcherRecoveryUncertain
    case watcherActivationFailure
    case watcherDrop
    case watcherOverflow
    case pendingIngressSequenceGap
    case seededShardPreparationFailure
    case cancellation
}

enum WorktreeStartupPhase: String, Equatable {
    case agentRunStarted
    case worktreePreparationStarted
    case bindingTransitionStarted
    case rootLoadStarted
    case shadowVerified
    case seedWatcherAttached
    case seedReplayFenced
    case seedReadyForCommit
    case seedPublished
    case seedFallback
    case rootReady
    case providerStart
    case failed
}

enum GitProcessCommandFamily: String, Equatable {
    case treeResolution
    case treeInventory
    case treeDelta
    case indexManifest
    case status
    case authorityMetadata
    case codemapAuthority
    case repositoryRead
    case mutation
}

enum WorktreeStartupInstrumentation {
    struct Event: Equatable {
        let correlationID: UUID
        let phase: WorktreeStartupPhase
        let route: WorkspaceRootStartupRoute?
        let fallback: WorkspaceRootSeedFallbackReason?
        let observationEnabled: Bool
        let servingEnabled: Bool
    }

    struct GitCommandMetric: Equatable {
        let family: GitProcessCommandFamily
        let priority: GitProcessAdmissionPriority
        let queueWaitMicroseconds: Int
        let durationMicroseconds: Int
        let outputByteCount: Int
        let cancelled: Bool
    }

    struct Snapshot: Equatable {
        let events: [Event]
        let gitCommands: [GitCommandMetric]
        let routeCounts: [WorkspaceRootStartupRoute: Int]
        let fallbackCounts: [WorkspaceRootSeedFallbackReason: Int]
        let shadow: ShadowCounters
        let seed: SeedCounters
    }

    struct ShadowCounters: Equatable {
        var inventoryComparisons = 0
        var inventoryMatches = 0
        var inventoryMismatches = 0
        var projectedSearchComparisons = 0
        var projectedSearchMatches = 0
        var projectedSearchMismatches = 0
        var latestBaseEntryCount = 0
        var latestOverlayEntryCount = 0
        var latestTombstoneCount = 0
    }

    struct SeedCounters: Equatable {
        var receiptJournalCutPresent = 0
        var receiptJournalCutAbsent = 0
        var acceptedReplayPayloadCount = 0
        var acceptedReplayEventCount = 0
        var latestInitializationWatermarkDelta = 0
        var latestServiceSequenceDelta = 0
        var latestReplayChangedPathCount = 0
        var metadataRevalidationChecks = 0
        var metadataRevalidationUses = 0
        var latestProjectedBaseEntryCount = 0
        var latestProjectedOverlayEntryCount = 0
        var latestProjectedTombstoneCount = 0
        var fullCrawlFallbackCount = 0
    }

    private static let lock = NSLock()
    private static let maximumEventCount = 512
    private static let maximumGitCommandMetricCount = 1024
    private static let maximumSeedMetricValue = 1_000_000
    private static var events: [Event] = []
    private static var gitCommands: [GitCommandMetric] = []
    private static var routeCounts: [WorkspaceRootStartupRoute: Int] = [:]
    private static var fallbackCounts: [WorkspaceRootSeedFallbackReason: Int] = [:]
    private static var shadowCounters = ShadowCounters()
    private static var seedCounters = SeedCounters()

    static func record(
        _ phase: WorktreeStartupPhase,
        context: WorktreeStartupContext,
        route: WorkspaceRootStartupRoute? = nil,
        fallback: WorkspaceRootSeedFallbackReason? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        if events.count == maximumEventCount {
            events.removeFirst()
        }
        events.append(Event(
            correlationID: context.correlationID,
            phase: phase,
            route: route,
            fallback: fallback,
            observationEnabled: context.flags.observeDiffSeededWorktreeStartup,
            servingEnabled: context.flags.serveDiffSeededWorktreeStartup
        ))
        if let route {
            routeCounts[route, default: 0] += 1
        }
        if let fallback {
            fallbackCounts[fallback, default: 0] += 1
        }
    }

    static func recordGitCommand(
        family: GitProcessCommandFamily,
        priority: GitProcessAdmissionPriority,
        queueWaitMicroseconds: Int,
        durationMicroseconds: Int,
        outputByteCount: Int,
        cancelled: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }
        if gitCommands.count == maximumGitCommandMetricCount {
            gitCommands.removeFirst()
        }
        gitCommands.append(GitCommandMetric(
            family: family,
            priority: priority,
            queueWaitMicroseconds: queueWaitMicroseconds,
            durationMicroseconds: durationMicroseconds,
            outputByteCount: outputByteCount,
            cancelled: cancelled
        ))
    }

    static func recordInventoryComparison(matched: Bool) {
        lock.lock()
        shadowCounters.inventoryComparisons = incremented(shadowCounters.inventoryComparisons)
        if matched {
            shadowCounters.inventoryMatches = incremented(shadowCounters.inventoryMatches)
        } else {
            shadowCounters.inventoryMismatches = incremented(shadowCounters.inventoryMismatches)
        }
        lock.unlock()
    }

    static func recordShadowFallback(_ reason: WorkspaceRootSeedFallbackReason) {
        lock.lock()
        fallbackCounts[reason, default: 0] = incremented(fallbackCounts[reason, default: 0])
        lock.unlock()
    }

    static func recordProjectedSearchComparison(
        matched: Bool,
        baseEntryCount: Int,
        overlayEntryCount: Int,
        tombstoneCount: Int
    ) {
        lock.lock()
        shadowCounters.projectedSearchComparisons = incremented(shadowCounters.projectedSearchComparisons)
        if matched {
            shadowCounters.projectedSearchMatches = incremented(shadowCounters.projectedSearchMatches)
        } else {
            shadowCounters.projectedSearchMismatches = incremented(shadowCounters.projectedSearchMismatches)
            fallbackCounts[.projectedSearchMismatch, default: 0] = incremented(
                fallbackCounts[.projectedSearchMismatch, default: 0]
            )
        }
        shadowCounters.latestBaseEntryCount = max(0, baseEntryCount)
        shadowCounters.latestOverlayEntryCount = max(0, overlayEntryCount)
        shadowCounters.latestTombstoneCount = max(0, tombstoneCount)
        lock.unlock()
    }

    static func recordSeedReceiptJournalCut(present: Bool) {
        lock.lock()
        if present {
            seedCounters.receiptJournalCutPresent = incremented(seedCounters.receiptJournalCutPresent)
        } else {
            seedCounters.receiptJournalCutAbsent = incremented(seedCounters.receiptJournalCutAbsent)
        }
        lock.unlock()
    }

    static func recordSeedReplay(
        acceptedPayloadCount: Int,
        acceptedEventCount: Int,
        initializationWatermarkDelta: Int,
        serviceSequenceDelta: Int,
        changedPathCount: Int
    ) {
        lock.lock()
        seedCounters.acceptedReplayPayloadCount = added(
            seedCounters.acceptedReplayPayloadCount,
            acceptedPayloadCount
        )
        seedCounters.acceptedReplayEventCount = added(
            seedCounters.acceptedReplayEventCount,
            acceptedEventCount
        )
        seedCounters.latestInitializationWatermarkDelta = bounded(initializationWatermarkDelta)
        seedCounters.latestServiceSequenceDelta = bounded(serviceSequenceDelta)
        seedCounters.latestReplayChangedPathCount = bounded(changedPathCount)
        lock.unlock()
    }

    static func recordSeedMetadataRevalidation(used: Bool) {
        lock.lock()
        seedCounters.metadataRevalidationChecks = incremented(seedCounters.metadataRevalidationChecks)
        if used {
            seedCounters.metadataRevalidationUses = incremented(seedCounters.metadataRevalidationUses)
        }
        lock.unlock()
    }

    static func recordSeedProjectedPreparation(
        baseEntryCount: Int,
        overlayEntryCount: Int,
        tombstoneCount: Int
    ) {
        lock.lock()
        seedCounters.latestProjectedBaseEntryCount = bounded(baseEntryCount)
        seedCounters.latestProjectedOverlayEntryCount = bounded(overlayEntryCount)
        seedCounters.latestProjectedTombstoneCount = bounded(tombstoneCount)
        lock.unlock()
    }

    static func recordSeedFullCrawlFallback() {
        lock.lock()
        seedCounters.fullCrawlFallbackCount = incremented(seedCounters.fullCrawlFallbackCount)
        lock.unlock()
    }

    static func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            events: events,
            gitCommands: gitCommands,
            routeCounts: routeCounts,
            fallbackCounts: fallbackCounts,
            shadow: shadowCounters,
            seed: seedCounters
        )
    }

    private static func incremented(_ value: Int) -> Int {
        value >= maximumSeedMetricValue ? maximumSeedMetricValue : value + 1
    }

    private static func bounded(_ value: Int) -> Int {
        min(max(0, value), maximumSeedMetricValue)
    }

    private static func added(_ current: Int, _ value: Int) -> Int {
        min(maximumSeedMetricValue, current + bounded(value))
    }

    #if DEBUG
        static func resetForTesting() {
            lock.lock()
            events.removeAll(keepingCapacity: true)
            gitCommands.removeAll(keepingCapacity: true)
            routeCounts.removeAll(keepingCapacity: true)
            fallbackCounts.removeAll(keepingCapacity: true)
            shadowCounters = ShadowCounters()
            seedCounters = SeedCounters()
            lock.unlock()
        }
    #endif
}
