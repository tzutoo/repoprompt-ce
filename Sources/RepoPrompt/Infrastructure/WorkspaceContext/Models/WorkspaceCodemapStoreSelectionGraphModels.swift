import Foundation

struct WorkspaceCodemapSelectionGraphFactory {
    private let makeGraph: @Sendable (WorkspaceCodemapRootEpoch) -> WorkspaceCodemapSelectionGraph

    init(
        makeGraph: @escaping @Sendable (WorkspaceCodemapRootEpoch) -> WorkspaceCodemapSelectionGraph
    ) {
        self.makeGraph = makeGraph
    }

    func make(rootEpoch: WorkspaceCodemapRootEpoch) -> WorkspaceCodemapSelectionGraph {
        makeGraph(rootEpoch)
    }

    static let production = Self { rootEpoch in
        WorkspaceCodemapSelectionGraph(rootEpoch: rootEpoch)
    }
}

struct WorkspaceCodemapStoreSelectionGraphSourceIdentity: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let ticket: WorkspaceCodemapArtifactDemandTicket

    init(ticket: WorkspaceCodemapArtifactDemandTicket) {
        rootEpoch = ticket.rootEpoch
        self.ticket = ticket
    }

    init(
        rootEpoch: WorkspaceCodemapRootEpoch,
        ticket: WorkspaceCodemapArtifactDemandTicket
    ) {
        self.rootEpoch = rootEpoch
        self.ticket = ticket
    }
}

struct WorkspaceCodemapStoreSelectionGraphQuery: Hashable {
    let selectedSources: [WorkspaceCodemapStoreSelectionGraphSourceIdentity]
}

struct WorkspaceCodemapStoreSelectionGraphQueryBudgetPolicy: Hashable {
    static let initial = Self(
        maximumTargetCount: 100_000,
        maximumResolutionCount: 100_000,
        maximumReferenceFailureCount: 100_000
    )

    let maximumTargetCount: Int
    let maximumResolutionCount: Int
    let maximumReferenceFailureCount: Int

    init(
        maximumTargetCount: Int,
        maximumResolutionCount: Int,
        maximumReferenceFailureCount: Int
    ) {
        precondition(maximumTargetCount > 0)
        precondition(maximumResolutionCount > 0)
        precondition(maximumReferenceFailureCount > 0)
        self.maximumTargetCount = maximumTargetCount
        self.maximumResolutionCount = maximumResolutionCount
        self.maximumReferenceFailureCount = maximumReferenceFailureCount
    }
}

enum WorkspaceCodemapStoreSelectionGraphPartialReason: Hashable {
    case sourceCoverageIncomplete
    case definitionUniverseIncomplete
    case referenceFailuresPresent
}

struct WorkspaceCodemapStoreSelectionGraphRootResult: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let result: WorkspaceCodemapSelectionGraphRuntimeQueryResult
    let partialReasons: Set<WorkspaceCodemapStoreSelectionGraphPartialReason>
}

struct WorkspaceCodemapStoreSelectionGraphQueryResult: Hashable {
    let roots: [WorkspaceCodemapStoreSelectionGraphRootResult]
}

enum WorkspaceCodemapStoreSelectionGraphQueryUnavailableReason: Hashable {
    case emptySources
    case foreignRootEpoch(UUID)
    case duplicateSourceConflict(UUID)
    case sourceNotReady(UUID)
    case notActivated(WorkspaceCodemapRootEpoch)
    case invalidGraphResult(WorkspaceCodemapRootEpoch)
    case runtime(
        rootEpoch: WorkspaceCodemapRootEpoch,
        reason: WorkspaceCodemapSelectionGraphRuntimeQueryUnavailableReason
    )
}

enum WorkspaceCodemapStoreSelectionGraphQueryStaleReason: Hashable {
    case currentness(WorkspaceCodemapRootEpoch)
    case runtime(
        rootEpoch: WorkspaceCodemapRootEpoch,
        reason: WorkspaceCodemapSelectionGraphRuntimeQueryUnavailableReason
    )
}

enum WorkspaceCodemapStoreSelectionGraphQueryBusyReason: Hashable {
    case runtime(
        rootEpoch: WorkspaceCodemapRootEpoch,
        reason: WorkspaceCodemapSelectionGraphRuntimeQueryUnavailableReason
    )
}

enum WorkspaceCodemapStoreSelectionGraphQueryBudgetReason: Hashable {
    case sourceLimit(attempted: Int, limit: Int)
    case rootLimit(attempted: Int, limit: Int)
    case targetLimit(attempted: Int, limit: Int)
    case resolutionLimit(attempted: Int, limit: Int)
    case referenceFailureLimit(attempted: Int, limit: Int)
    case accountingOverflow
    case runtime(
        rootEpoch: WorkspaceCodemapRootEpoch,
        reason: WorkspaceCodemapSelectionGraphRuntimeQueryUnavailableReason
    )
}

enum WorkspaceCodemapStoreSelectionGraphQueryDisposition: Hashable {
    case readyPartial(WorkspaceCodemapStoreSelectionGraphQueryResult)
    case unavailable(WorkspaceCodemapStoreSelectionGraphQueryUnavailableReason)
    case stale(WorkspaceCodemapStoreSelectionGraphQueryStaleReason)
    case busy(WorkspaceCodemapStoreSelectionGraphQueryBusyReason)
    case budget(WorkspaceCodemapStoreSelectionGraphQueryBudgetReason)
}
