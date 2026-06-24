import Foundation

/// Define size_t for C interop
typealias size_t = Int

/// Immutable high-performance path search index backed by C-owned sorted arrays.
///
/// The C storage is read-only after initialization, so concurrent readers can safely retain and
/// query an older generation while a replacement index is built and published elsewhere.
final class PathSearchIndex: @unchecked Sendable {
    struct Candidate: Equatable {
        let index: Int
        let path: String
        let filename: String
        let score: Int32
        let tieBreakKey: String
    }

    struct ProjectedSearchDiagnostics: Equatable {
        let examinedCount: Int
        let matchedCount: Int
        let heapPeakCount: Int
        let heapComparisonCount: Int
        let scratchBytes: Int
    }

    enum ProjectedSearchOutcome {
        case completed([Candidate], ProjectedSearchDiagnostics)
        case cancelled(ProjectedSearchDiagnostics)
    }

    private let cIndex: OpaquePointer? // const path_search_index_t*
    private let originalPaths: [String]
    private let filenames: [String]

    init(paths: [String]) {
        originalPaths = paths
        filenames = paths.map { path in
            URL(fileURLWithPath: path).lastPathComponent
        }

        guard !paths.isEmpty else {
            cIndex = nil
            return
        }

        let cPaths = paths.map { strdup($0) }
        defer { cPaths.forEach { free($0) } }
        let cPathPointers = cPaths.map { UnsafePointer<CChar>($0) }
        cIndex = cPathPointers.withUnsafeBufferPointer { buffer in
            path_search_create(buffer.baseAddress, paths.count)
        }
    }

    deinit {
        if let cIndex {
            path_search_destroy(cIndex)
        }
    }

    /// Builds an immutable index from a non-actor async context so UI callers do not perform the
    /// C allocation and sort on `MainActor`.
    static func build(paths: [String]) async -> PathSearchIndex {
        PathSearchIndex(paths: paths)
    }

    /// Returns candidates in the C index's authoritative rank order: descending score, then
    /// ascending lexical tie-break key. The current matcher is boolean, so accepted matches all
    /// have score 1 and retain the historical lexical ordering exactly.
    func search(_ pattern: String, limit: Int = 300) async -> [Candidate] {
        searchSynchronously(pattern, limit: limit)
    }

    /// Synchronous immutable query used by readers that already execute away from UI actors.
    func searchSynchronously(_ pattern: String, limit: Int = 300) -> [Candidate] {
        guard let cIndex, limit > 0 else { return [] }
        let result = pattern.withCString { patternCString in
            path_search_find(cIndex, patternCString, limit)
        }
        guard let result else { return [] }
        defer { search_result_destroy(result) }

        let resultPointer = UnsafePointer<search_result_t>(result)
        let count = Int(resultPointer.pointee.count)
        guard count > 0,
              let indices = resultPointer.pointee.indices,
              let scores = resultPointer.pointee.scores,
              let tieBreakKeys = resultPointer.pointee.tieBreakKeys
        else { return [] }

        var candidates: [Candidate] = []
        candidates.reserveCapacity(count)
        for resultIndex in 0 ..< count {
            let pathIndex = Int(indices[resultIndex])
            guard originalPaths.indices.contains(pathIndex),
                  let tieBreakCString = tieBreakKeys[resultIndex]
            else { continue }
            candidates.append(Candidate(
                index: pathIndex,
                path: originalPaths[pathIndex],
                filename: filenames[pathIndex],
                score: scores[resultIndex],
                tieBreakKey: String(cString: tieBreakCString)
            ))
        }
        return candidates
    }

    func searchProjectedSynchronously(
        _ pattern: String,
        displayPrefix: String,
        absolutePrefix: String,
        limit: Int = 300
    ) -> [Candidate] {
        switch searchProjectedSynchronously(
            pattern,
            displayPrefix: displayPrefix,
            absolutePrefix: absolutePrefix,
            limit: limit,
            cancellation: nil
        ) {
        case let .completed(candidates, _): candidates
        case .cancelled: []
        }
    }

    func searchProjected(
        _ pattern: String,
        displayPrefix: String,
        absolutePrefix: String,
        limit: Int = 300
    ) async -> ProjectedSearchOutcome {
        guard let cancellation = PathSearchCancellation() else {
            return searchProjectedSynchronously(
                pattern,
                displayPrefix: displayPrefix,
                absolutePrefix: absolutePrefix,
                limit: limit,
                cancellation: nil
            )
        }
        let worker = Task.detached { [self, cancellation] in
            searchProjectedSynchronously(
                pattern,
                displayPrefix: displayPrefix,
                absolutePrefix: absolutePrefix,
                limit: limit,
                cancellation: cancellation
            )
        }
        return await withTaskCancellationHandler {
            if Task.isCancelled {
                cancellation.cancel()
                worker.cancel()
            }
            return await worker.value
        } onCancel: {
            cancellation.cancel()
            worker.cancel()
        }
    }

    private func searchProjectedSynchronously(
        _ pattern: String,
        displayPrefix: String,
        absolutePrefix: String,
        limit: Int,
        cancellation: PathSearchCancellation?
    ) -> ProjectedSearchOutcome {
        let emptyDiagnostics = ProjectedSearchDiagnostics(
            examinedCount: 0,
            matchedCount: 0,
            heapPeakCount: 0,
            heapComparisonCount: 0,
            scratchBytes: 0
        )
        guard let cIndex, limit > 0 else { return .completed([], emptyDiagnostics) }
        var stats = path_search_work_stats_t()
        let result = pattern.withCString { patternCString in
            displayPrefix.withCString { displayCString in
                absolutePrefix.withCString { absoluteCString in
                    path_search_projected_find_cancellable(
                        cIndex,
                        patternCString,
                        displayCString,
                        absoluteCString,
                        limit,
                        cancellation?.pointer,
                        &stats
                    )
                }
            }
        }
        let diagnostics = ProjectedSearchDiagnostics(
            examinedCount: stats.examinedCount,
            matchedCount: stats.matchedCount,
            heapPeakCount: stats.heapPeakCount,
            heapComparisonCount: stats.heapComparisonCount,
            scratchBytes: stats.scratchBytes
        )
        guard let result else {
            return stats.cancelled ? .cancelled(diagnostics) : .completed([], diagnostics)
        }
        defer { search_result_destroy(result) }

        if stats.cancelled { return .cancelled(diagnostics) }

        let resultPointer = UnsafePointer<search_result_t>(result)
        let count = Int(resultPointer.pointee.count)
        guard count > 0,
              let indices = resultPointer.pointee.indices,
              let scores = resultPointer.pointee.scores
        else { return .completed([], diagnostics) }
        let candidates: [Candidate] = (0 ..< count).compactMap { resultIndex in
            let pathIndex = Int(indices[resultIndex])
            guard originalPaths.indices.contains(pathIndex) else { return nil }
            let relativePath = originalPaths[pathIndex]
            return Candidate(
                index: pathIndex,
                path: relativePath,
                filename: filenames[pathIndex],
                score: scores[resultIndex],
                tieBreakKey: displayPrefix + relativePath + "\n" + absolutePrefix + relativePath
            )
        }
        return .completed(candidates, diagnostics)
    }

    func path(at index: Int) -> String? {
        guard originalPaths.indices.contains(index) else { return nil }
        return originalPaths[index]
    }

    func filename(at index: Int) -> String? {
        guard filenames.indices.contains(index) else { return nil }
        return filenames[index]
    }

    var count: Int {
        originalPaths.count
    }
}

private final class PathSearchCancellation: @unchecked Sendable {
    let pointer: OpaquePointer

    init?() {
        guard let pointer = path_search_cancellation_create() else { return nil }
        self.pointer = pointer
    }

    deinit {
        path_search_cancellation_destroy(pointer)
    }

    func cancel() {
        path_search_cancellation_cancel(pointer)
    }
}

struct WorkspaceSearchRootPathIndexIdentity: Equatable, Hashable {
    let rootID: UUID
    let lifetimeID: UUID
    let topologyGeneration: UInt64
}

final class WorkspaceProjectedPathSearchShadowControl: @unchecked Sendable {
    struct Lease {
        let projection: WorkspaceProjectedPathSearchIndex
        fileprivate let generation: UInt64
    }

    let scope: WorkspaceRootSeedShadowScope
    private let lock = NSLock()
    private var projection: WorkspaceProjectedPathSearchIndex?
    private var generation: UInt64 = 0

    init(scope: WorkspaceRootSeedShadowScope, projection: WorkspaceProjectedPathSearchIndex) {
        self.scope = scope
        self.projection = projection
    }

    func begin() -> Lease? {
        lock.lock()
        defer { lock.unlock() }
        guard let projection else { return nil }
        return Lease(projection: projection, generation: generation)
    }

    /// Returns true only when this completion still owns the active generation.
    /// A mismatch drops the projection before releasing the lock, so no later query can rerun it.
    func complete(_ lease: Lease, matched: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard projection != nil, generation == lease.generation else { return false }
        if !matched {
            projection = nil
            generation &+= 1
        }
        return true
    }

    @discardableResult
    func invalidate() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard projection != nil else { return false }
        projection = nil
        generation &+= 1
        return true
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return projection != nil
    }
}

/// Immutable root-local search projection retained by catalog snapshots and active readers.
///
/// Small shard patches share one materialized base index and rebuild only a bounded overlay.
/// Every published generation owns immutable overlay/tombstone values, so older readers can safely
/// continue querying the base and overlay generation they captured.
final class WorkspaceSearchRootPathIndex: @unchecked Sendable {
    enum BuildKind: Equatable {
        case full
        case overlay
        case reused
        case projectedReuse
    }

    struct Candidate {
        let entry: WorkspaceSearchCatalogEntry
        let score: Int32
        let tieBreakKey: String
    }

    static let maxOverlayChangedFileCount = 32

    private final class MaterializedBase: @unchecked Sendable {
        let entries: [WorkspaceSearchCatalogEntry]
        let index: PathSearchIndex

        init(entries: [WorkspaceSearchCatalogEntry]) {
            self.entries = entries
            #if DEBUG
                let keyStart = WorkspaceFileSearchDebugTiming.now()
                let keys = entries.map(\.pathSearchIndexKey)
                let keyEnd = WorkspaceFileSearchDebugTiming.now()
                WorkspaceFileSearchDebugContext.catalogBuildObserver?.recordPathIndexKey(
                    nanoseconds: WorkspaceFileSearchDebugTiming.elapsed(since: keyStart, through: keyEnd)
                )
                let indexStart = WorkspaceFileSearchDebugTiming.now()
                index = PathSearchIndex(paths: keys)
                let indexEnd = WorkspaceFileSearchDebugTiming.now()
                WorkspaceFileSearchDebugContext.catalogBuildObserver?.recordPathIndexConstruction(
                    nanoseconds: WorkspaceFileSearchDebugTiming.elapsed(since: indexStart, through: indexEnd)
                )
            #else
                index = PathSearchIndex(paths: entries.map(\.pathSearchIndexKey))
            #endif
        }
    }

    let identity: WorkspaceSearchRootPathIndexIdentity
    let rootPath: String
    let entries: [WorkspaceSearchCatalogEntry]
    let buildKind: BuildKind

    private let base: MaterializedBase?
    private let projectedIndex: WorkspaceProjectedPathSearchIndex?
    private let overlayEntries: [WorkspaceSearchCatalogEntry]
    private let overlayIndex: PathSearchIndex?
    private let tombstonedBaseEntryIDs: Set<UUID>
    private let accumulatedChangedFileIDs: Set<UUID>
    private let shadowControl: WorkspaceProjectedPathSearchShadowControl?

    init(
        identity: WorkspaceSearchRootPathIndexIdentity,
        rootPath: String,
        entries: [WorkspaceSearchCatalogEntry],
        shadowControl: WorkspaceProjectedPathSearchShadowControl? = nil
    ) {
        self.identity = identity
        self.rootPath = rootPath
        self.entries = entries
        buildKind = .full
        base = MaterializedBase(entries: entries)
        projectedIndex = nil
        overlayEntries = []
        overlayIndex = nil
        tombstonedBaseEntryIDs = []
        accumulatedChangedFileIDs = []
        self.shadowControl = shadowControl
    }

    private init(
        identity: WorkspaceSearchRootPathIndexIdentity,
        rootPath: String,
        entries: [WorkspaceSearchCatalogEntry],
        buildKind: BuildKind,
        base: MaterializedBase,
        overlayEntries: [WorkspaceSearchCatalogEntry],
        preparedOverlayIndex: PathSearchIndex? = nil,
        tombstonedBaseEntryIDs: Set<UUID>,
        accumulatedChangedFileIDs: Set<UUID>,
        shadowControl: WorkspaceProjectedPathSearchShadowControl?
    ) {
        self.identity = identity
        self.rootPath = rootPath
        self.entries = entries
        self.buildKind = buildKind
        self.base = base
        projectedIndex = nil
        self.overlayEntries = overlayEntries
        overlayIndex = preparedOverlayIndex ?? (
            overlayEntries.isEmpty
                ? nil
                : PathSearchIndex(paths: overlayEntries.map(\.pathSearchIndexKey))
        )
        self.tombstonedBaseEntryIDs = tombstonedBaseEntryIDs
        self.accumulatedChangedFileIDs = accumulatedChangedFileIDs
        self.shadowControl = shadowControl
    }

    init(
        identity: WorkspaceSearchRootPathIndexIdentity,
        rootPath: String,
        entries: [WorkspaceSearchCatalogEntry],
        projectedIndex: WorkspaceProjectedPathSearchIndex
    ) {
        precondition(projectedIndex.entries == entries)
        self.identity = identity
        self.rootPath = rootPath
        self.entries = entries
        buildKind = .projectedReuse
        base = nil
        self.projectedIndex = projectedIndex
        overlayEntries = []
        overlayIndex = nil
        tombstonedBaseEntryIDs = []
        accumulatedChangedFileIDs = []
        shadowControl = nil
    }

    convenience init?(
        identity: WorkspaceSearchRootPathIndexIdentity,
        root: WorkspaceRootRecord,
        projectedSnapshot snapshot: WorkspaceRootReusableSnapshot,
        projectedPlan plan: WorkspaceRootSeedPlan,
        entries: [WorkspaceSearchCatalogEntry]
    ) {
        guard let projectedIndex = WorkspaceProjectedPathSearchIndex(
            snapshot: snapshot,
            plan: plan,
            root: root,
            authoritativeEntries: entries
        ) else { return nil }
        self.init(
            identity: identity,
            rootPath: root.standardizedFullPath,
            entries: entries,
            projectedIndex: projectedIndex
        )
    }

    var count: Int {
        entries.count
    }

    func applyingPatch(
        identity: WorkspaceSearchRootPathIndexIdentity,
        entries: [WorkspaceSearchCatalogEntry],
        changedFileIDs: Set<UUID>
    ) -> WorkspaceSearchRootPathIndex {
        guard identity.rootID == self.identity.rootID,
              identity.lifetimeID == self.identity.lifetimeID
        else {
            return WorkspaceSearchRootPathIndex(identity: identity, rootPath: rootPath, entries: entries)
        }

        guard !changedFileIDs.isEmpty else {
            if let projectedIndex {
                return WorkspaceSearchRootPathIndex(
                    identity: identity,
                    rootPath: rootPath,
                    entries: entries,
                    projectedIndex: projectedIndex
                )
            }
            guard let base else {
                return WorkspaceSearchRootPathIndex(identity: identity, rootPath: rootPath, entries: entries)
            }
            return WorkspaceSearchRootPathIndex(
                identity: identity,
                rootPath: rootPath,
                entries: entries,
                buildKind: .reused,
                base: base,
                overlayEntries: overlayEntries,
                preparedOverlayIndex: overlayIndex,
                tombstonedBaseEntryIDs: tombstonedBaseEntryIDs,
                accumulatedChangedFileIDs: accumulatedChangedFileIDs,
                shadowControl: shadowControl
            )
        }

        if let projectedIndex {
            let previousEntriesByID = Dictionary(
                uniqueKeysWithValues: self.entries.map { ($0.id, $0) }
            )
            let currentEntriesByID = Dictionary(
                uniqueKeysWithValues: entries.map { ($0.id, $0) }
            )
            var changedRelativePaths = Set<String>()
            changedRelativePaths.reserveCapacity(changedFileIDs.count * 2)
            for fileID in changedFileIDs {
                var resolvedPath = false
                if let previous = previousEntriesByID[fileID] {
                    changedRelativePaths.insert(previous.standardizedRelativePath)
                    resolvedPath = true
                }
                if let current = currentEntriesByID[fileID] {
                    changedRelativePaths.insert(current.standardizedRelativePath)
                    resolvedPath = true
                }
                guard resolvedPath else {
                    return WorkspaceSearchRootPathIndex(identity: identity, rootPath: rootPath, entries: entries)
                }
            }
            guard let nextProjectedIndex = projectedIndex.applyingPatch(
                entries: entries,
                changedRelativePaths: changedRelativePaths
            ) else {
                return WorkspaceSearchRootPathIndex(identity: identity, rootPath: rootPath, entries: entries)
            }
            return WorkspaceSearchRootPathIndex(
                identity: identity,
                rootPath: rootPath,
                entries: entries,
                projectedIndex: nextProjectedIndex
            )
        }

        let nextChangedFileIDs = accumulatedChangedFileIDs.union(changedFileIDs)
        shadowControl?.invalidate()
        guard nextChangedFileIDs.count < Self.maxOverlayChangedFileCount else {
            return WorkspaceSearchRootPathIndex(identity: identity, rootPath: rootPath, entries: entries)
        }

        guard let base else {
            return WorkspaceSearchRootPathIndex(identity: identity, rootPath: rootPath, entries: entries)
        }
        var nextTombstonedBaseEntryIDs = tombstonedBaseEntryIDs
        var nextOverlayEntriesByID = Dictionary(
            uniqueKeysWithValues: overlayEntries.map { ($0.id, $0) }
        )
        let currentEntriesByChangedID = Dictionary(
            uniqueKeysWithValues: entries.compactMap { entry in
                changedFileIDs.contains(entry.id) ? (entry.id, entry) : nil
            }
        )
        let baseEntryIDs = Set(base.entries.lazy.compactMap { entry in
            changedFileIDs.contains(entry.id) ? entry.id : nil
        })

        for fileID in changedFileIDs {
            nextOverlayEntriesByID.removeValue(forKey: fileID)
            if baseEntryIDs.contains(fileID) {
                nextTombstonedBaseEntryIDs.insert(fileID)
            }
            if let currentEntry = currentEntriesByChangedID[fileID] {
                nextOverlayEntriesByID[fileID] = currentEntry
            }
        }

        let nextOverlayEntries = entries.compactMap { nextOverlayEntriesByID[$0.id] }
        return WorkspaceSearchRootPathIndex(
            identity: identity,
            rootPath: rootPath,
            entries: entries,
            buildKind: .overlay,
            base: base,
            overlayEntries: nextOverlayEntries,
            tombstonedBaseEntryIDs: nextTombstonedBaseEntryIDs,
            accumulatedChangedFileIDs: nextChangedFileIDs,
            shadowControl: nil
        )
    }

    func search(_ query: String, limit: Int) -> [Candidate] {
        guard limit > 0 else { return [] }
        if let projectedIndex {
            return projectedIndex.search(query, limit: limit)
        }
        guard let base else { return [] }

        let boundedBaseLimit = min(base.entries.count, limit)
        let baseOverfetch = min(
            tombstonedBaseEntryIDs.count,
            base.entries.count - boundedBaseLimit
        )
        let baseCandidates = base.index
            .searchSynchronously(query, limit: boundedBaseLimit + baseOverfetch)
            .compactMap { candidate -> Candidate? in
                guard base.entries.indices.contains(candidate.index) else { return nil }
                let entry = base.entries[candidate.index]
                guard !tombstonedBaseEntryIDs.contains(entry.id) else { return nil }
                return Candidate(
                    entry: entry,
                    score: candidate.score,
                    tieBreakKey: candidate.tieBreakKey
                )
            }

        let overlayCandidates = overlayIndex?
            .searchSynchronously(query, limit: min(limit, overlayEntries.count))
            .compactMap { candidate -> Candidate? in
                guard overlayEntries.indices.contains(candidate.index) else { return nil }
                return Candidate(
                    entry: overlayEntries[candidate.index],
                    score: candidate.score,
                    tieBreakKey: candidate.tieBreakKey
                )
            } ?? []

        var baseIndex = 0
        var overlayIndex = 0
        var results: [Candidate] = []
        results.reserveCapacity(limit)
        while results.count < limit,
              baseIndex < baseCandidates.count || overlayIndex < overlayCandidates.count
        {
            if overlayIndex >= overlayCandidates.count {
                results.append(baseCandidates[baseIndex])
                baseIndex += 1
            } else if baseIndex >= baseCandidates.count {
                results.append(overlayCandidates[overlayIndex])
                overlayIndex += 1
            } else if Self.candidatePrecedes(
                overlayCandidates[overlayIndex],
                baseCandidates[baseIndex]
            ) {
                results.append(overlayCandidates[overlayIndex])
                overlayIndex += 1
            } else {
                results.append(baseCandidates[baseIndex])
                baseIndex += 1
            }
        }
        return results
    }

    func searchVerifyingShadow(_ query: String, limit: Int) async -> [Candidate] {
        let results = search(query, limit: limit)
        guard !Task.isCancelled, let lease = shadowControl?.begin() else { return results }
        let shadowProjection = lease.projection
        switch await shadowProjection.searchCancellable(query, limit: limit) {
        case .cancelled:
            return results
        case let .completed(projected, _):
            let matched = projected.count == results.count
                && zip(projected, results).allSatisfy { projected, authoritative in
                    projected.entry == authoritative.entry
                        && projected.score == authoritative.score
                        && projected.tieBreakKey == authoritative.tieBreakKey
                }
            if shadowControl?.complete(lease, matched: matched) == true {
                WorktreeStartupInstrumentation.recordProjectedSearchComparison(
                    matched: matched,
                    baseEntryCount: shadowProjection.baseEntryCount,
                    overlayEntryCount: shadowProjection.overlayEntryCount,
                    tombstoneCount: shadowProjection.tombstoneCount
                )
            }
        }
        return results
    }

    func recordEmptyQueryShadowParity(limit: Int) {
        guard let shadowControl, let lease = shadowControl.begin(), limit > 0 else { return }
        let shadowProjection = lease.projection
        let authoritative = Array(entries.prefix(limit))
        let projected = Array(shadowProjection.entries.prefix(limit))
        let matched = authoritative == projected
        if shadowControl.complete(lease, matched: matched) {
            WorktreeStartupInstrumentation.recordProjectedSearchComparison(
                matched: matched,
                baseEntryCount: shadowProjection.baseEntryCount,
                overlayEntryCount: shadowProjection.overlayEntryCount,
                tombstoneCount: shadowProjection.tombstoneCount
            )
        }
    }

    var projectedAccumulatedChangedPathCount: Int? {
        projectedIndex?.accumulatedChangedRelativePathCount
    }

    private static func candidatePrecedes(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        switch WorkspaceFileContextStore.compareUTF8Binary(lhs.tieBreakKey, rhs.tieBreakKey) {
        case .orderedAscending:
            return true
        case .orderedDescending:
            return false
        case .orderedSame:
            break
        }
        return WorkspaceFileContextStore.searchCatalogEntryPrecedes(lhs.entry, rhs.entry)
    }
}

final class WorkspaceProjectedPathSearchIndex: @unchecked Sendable {
    typealias Candidate = WorkspaceSearchRootPathIndex.Candidate

    enum CancellableSearchOutcome {
        case completed([Candidate], PathSearchIndex.ProjectedSearchDiagnostics)
        case cancelled(PathSearchIndex.ProjectedSearchDiagnostics)
    }

    let entries: [WorkspaceSearchCatalogEntry]
    let baseEntryCount: Int
    let overlayEntryCount: Int
    let tombstoneCount: Int
    let accumulatedChangedRelativePathCount: Int

    private let relativeBase: WorkspaceSearchRelativePathBase
    private let targetEntriesByBaseIndex: [WorkspaceSearchCatalogEntry?]
    private let overlayEntries: [WorkspaceSearchCatalogEntry]
    private let overlayIndex: PathSearchIndex?
    private let displayPrefix: String
    private let absolutePrefix: String
    private let accumulatedChangedRelativePaths: Set<String>

    init?(
        snapshot: WorkspaceRootReusableSnapshot,
        plan: WorkspaceRootSeedPlan,
        root: WorkspaceRootRecord,
        authoritativeEntries: [WorkspaceSearchCatalogEntry]
    ) {
        let changed = Set(
            plan.changedRelativeFilePaths
                .union(plan.tombstonedBaseRelativeFilePaths)
                .map(StandardizedPath.relative)
        )
        guard snapshot.identity == plan.snapshotIdentity,
              changed.count < WorkspaceSearchRootPathIndex.maxOverlayChangedFileCount
        else { return nil }
        let entriesByRelativePath = Dictionary(
            authoritativeEntries.map { ($0.standardizedRelativePath, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let projectedDisplayPrefix = root.name + "/"
        let projectedAbsolutePrefix = root.standardizedFullPath + "/"
        guard authoritativeEntries.allSatisfy({ entry in
            entry.displayPath == projectedDisplayPrefix + entry.standardizedRelativePath
                && entry.standardizedFullPath == projectedAbsolutePrefix + entry.standardizedRelativePath
        }) else { return nil }
        var targets: [WorkspaceSearchCatalogEntry?] = []
        targets.reserveCapacity(snapshot.searchBase.relativePaths.count)
        var baseRelativePaths = Set<String>()
        for relativePath in snapshot.searchBase.relativePaths {
            let standardized = StandardizedPath.relative(relativePath)
            baseRelativePaths.insert(standardized)
            if changed.contains(standardized)
                || plan.tombstonedBaseRelativeFilePaths.contains(standardized)
            {
                targets.append(nil)
            } else {
                guard let entry = entriesByRelativePath[standardized] else { return nil }
                targets.append(entry)
            }
        }

        relativeBase = snapshot.searchBase
        targetEntriesByBaseIndex = targets
        overlayEntries = authoritativeEntries.filter {
            changed.contains($0.standardizedRelativePath)
                || !baseRelativePaths.contains($0.standardizedRelativePath)
        }
        overlayIndex = overlayEntries.isEmpty
            ? nil
            : PathSearchIndex(paths: overlayEntries.map(\.pathSearchIndexKey))
        entries = authoritativeEntries
        baseEntryCount = targets.compactMap(\.self).count
        overlayEntryCount = overlayEntries.count
        tombstoneCount = targets.count - baseEntryCount
        accumulatedChangedRelativePaths = changed
        accumulatedChangedRelativePathCount = changed.count
        displayPrefix = projectedDisplayPrefix
        absolutePrefix = projectedAbsolutePrefix
    }

    private init?(
        relativeBase: WorkspaceSearchRelativePathBase,
        displayPrefix: String,
        absolutePrefix: String,
        accumulatedChangedRelativePaths: Set<String>,
        authoritativeEntries: [WorkspaceSearchCatalogEntry]
    ) {
        let changed = Set(accumulatedChangedRelativePaths.map(StandardizedPath.relative))
        guard changed.count < WorkspaceSearchRootPathIndex.maxOverlayChangedFileCount,
              authoritativeEntries.allSatisfy({ entry in
                  entry.displayPath == displayPrefix + entry.standardizedRelativePath
                      && entry.standardizedFullPath == absolutePrefix + entry.standardizedRelativePath
              })
        else { return nil }

        let entriesByRelativePath = Dictionary(
            authoritativeEntries.map { ($0.standardizedRelativePath, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var targets: [WorkspaceSearchCatalogEntry?] = []
        targets.reserveCapacity(relativeBase.relativePaths.count)
        var baseRelativePaths = Set<String>()
        for relativePath in relativeBase.relativePaths {
            let standardized = StandardizedPath.relative(relativePath)
            baseRelativePaths.insert(standardized)
            if changed.contains(standardized) {
                targets.append(nil)
            } else {
                guard let entry = entriesByRelativePath[standardized] else { return nil }
                targets.append(entry)
            }
        }

        let overlays = authoritativeEntries.filter {
            changed.contains($0.standardizedRelativePath)
                || !baseRelativePaths.contains($0.standardizedRelativePath)
        }
        self.relativeBase = relativeBase
        targetEntriesByBaseIndex = targets
        overlayEntries = overlays
        overlayIndex = overlays.isEmpty
            ? nil
            : PathSearchIndex(paths: overlays.map(\.pathSearchIndexKey))
        entries = authoritativeEntries
        baseEntryCount = targets.compactMap(\.self).count
        overlayEntryCount = overlays.count
        tombstoneCount = targets.count - baseEntryCount
        self.accumulatedChangedRelativePaths = changed
        accumulatedChangedRelativePathCount = changed.count
        self.displayPrefix = displayPrefix
        self.absolutePrefix = absolutePrefix
    }

    func applyingPatch(
        entries: [WorkspaceSearchCatalogEntry],
        changedRelativePaths: Set<String>
    ) -> WorkspaceProjectedPathSearchIndex? {
        WorkspaceProjectedPathSearchIndex(
            relativeBase: relativeBase,
            displayPrefix: displayPrefix,
            absolutePrefix: absolutePrefix,
            accumulatedChangedRelativePaths: accumulatedChangedRelativePaths.union(changedRelativePaths),
            authoritativeEntries: entries
        )
    }

    func search(_ query: String, limit: Int) -> [Candidate] {
        guard limit > 0 else { return [] }
        let boundedBaseLimit = min(targetEntriesByBaseIndex.count, limit)
        let baseOverfetch = min(tombstoneCount, targetEntriesByBaseIndex.count - boundedBaseLimit)
        let baseCandidates = relativeBase.index.searchProjectedSynchronously(
            query,
            displayPrefix: displayPrefix,
            absolutePrefix: absolutePrefix,
            limit: boundedBaseLimit + baseOverfetch
        ).compactMap { candidate -> Candidate? in
            guard targetEntriesByBaseIndex.indices.contains(candidate.index),
                  let entry = targetEntriesByBaseIndex[candidate.index]
            else { return nil }
            return Candidate(entry: entry, score: candidate.score, tieBreakKey: candidate.tieBreakKey)
        }
        let overlayCandidates = overlayIndex?.searchSynchronously(
            query,
            limit: min(limit, overlayEntries.count)
        ).compactMap { candidate -> Candidate? in
            guard overlayEntries.indices.contains(candidate.index) else { return nil }
            return Candidate(
                entry: overlayEntries[candidate.index],
                score: candidate.score,
                tieBreakKey: candidate.tieBreakKey
            )
        } ?? []

        var baseIndex = 0
        var overlayIndex = 0
        var results: [Candidate] = []
        results.reserveCapacity(limit)
        while results.count < limit,
              baseIndex < baseCandidates.count || overlayIndex < overlayCandidates.count
        {
            if overlayIndex >= overlayCandidates.count {
                results.append(baseCandidates[baseIndex])
                baseIndex += 1
            } else if baseIndex >= baseCandidates.count {
                results.append(overlayCandidates[overlayIndex])
                overlayIndex += 1
            } else if Self.candidatePrecedes(
                overlayCandidates[overlayIndex],
                baseCandidates[baseIndex]
            ) {
                results.append(overlayCandidates[overlayIndex])
                overlayIndex += 1
            } else {
                results.append(baseCandidates[baseIndex])
                baseIndex += 1
            }
        }
        return results
    }

    func searchCancellable(
        _ query: String,
        limit: Int
    ) async -> CancellableSearchOutcome {
        guard limit > 0 else {
            return .completed([], .init(
                examinedCount: 0,
                matchedCount: 0,
                heapPeakCount: 0,
                heapComparisonCount: 0,
                scratchBytes: 0
            ))
        }
        let boundedBaseLimit = min(targetEntriesByBaseIndex.count, limit)
        let baseOverfetch = min(tombstoneCount, targetEntriesByBaseIndex.count - boundedBaseLimit)
        let baseOutcome = await relativeBase.index.searchProjected(
            query,
            displayPrefix: displayPrefix,
            absolutePrefix: absolutePrefix,
            limit: boundedBaseLimit + baseOverfetch
        )
        let baseCandidates: [Candidate]
        let diagnostics: PathSearchIndex.ProjectedSearchDiagnostics
        switch baseOutcome {
        case let .cancelled(value):
            return .cancelled(value)
        case let .completed(candidates, value):
            diagnostics = value
            baseCandidates = candidates.compactMap { candidate -> Candidate? in
                guard targetEntriesByBaseIndex.indices.contains(candidate.index),
                      let entry = targetEntriesByBaseIndex[candidate.index]
                else { return nil }
                return Candidate(entry: entry, score: candidate.score, tieBreakKey: candidate.tieBreakKey)
            }
        }
        guard !Task.isCancelled else { return .cancelled(diagnostics) }
        let overlayCandidates = overlayIndex?.searchSynchronously(
            query,
            limit: min(limit, overlayEntries.count)
        ).compactMap { candidate -> Candidate? in
            guard overlayEntries.indices.contains(candidate.index) else { return nil }
            return Candidate(
                entry: overlayEntries[candidate.index],
                score: candidate.score,
                tieBreakKey: candidate.tieBreakKey
            )
        } ?? []

        var baseIndex = 0
        var overlayIndex = 0
        var results: [Candidate] = []
        results.reserveCapacity(limit)
        while results.count < limit,
              baseIndex < baseCandidates.count || overlayIndex < overlayCandidates.count
        {
            if Task.isCancelled { return .cancelled(diagnostics) }
            if overlayIndex >= overlayCandidates.count {
                results.append(baseCandidates[baseIndex])
                baseIndex += 1
            } else if baseIndex >= baseCandidates.count {
                results.append(overlayCandidates[overlayIndex])
                overlayIndex += 1
            } else if Self.candidatePrecedes(
                overlayCandidates[overlayIndex],
                baseCandidates[baseIndex]
            ) {
                results.append(overlayCandidates[overlayIndex])
                overlayIndex += 1
            } else {
                results.append(baseCandidates[baseIndex])
                baseIndex += 1
            }
        }
        return .completed(results, diagnostics)
    }

    private static func candidatePrecedes(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        switch WorkspaceFileContextStore.compareUTF8Binary(lhs.tieBreakKey, rhs.tieBreakKey) {
        case .orderedAscending:
            return true
        case .orderedDescending:
            return false
        case .orderedSame:
            return WorkspaceFileContextStore.searchCatalogEntryPrecedes(lhs.entry, rhs.entry)
        }
    }
}

extension WorkspaceSearchCatalogEntry {
    var pathSearchIndexKey: String {
        // Preserve the existing one-record index behavior for both UI display paths and absolute
        // path consumers. This exact string is also the global lexical tie-break key.
        displayPath + "\n" + standardizedFullPath
    }
}

// MARK: - LRU Cache Actor

/// Thread-safe LRU cache implementation using actors
actor LRUCacheActor<Key: Hashable, Value> {
    private struct Entry {
        let value: Value
        var timestamp: Date
    }

    private var cache: [Key: Entry] = [:]
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    func value(for key: Key) -> Value? {
        if var entry = cache[key] {
            entry.timestamp = Date()
            cache[key] = entry
            return entry.value
        }
        return nil
    }

    func set(_ value: Value, for key: Key) {
        cache[key] = Entry(value: value, timestamp: Date())

        // Evict oldest if over capacity
        if cache.count > capacity {
            let oldest = cache.min { $0.value.timestamp < $1.value.timestamp }
            if let oldestKey = oldest?.key {
                cache.removeValue(forKey: oldestKey)
            }
        }
    }

    func clear() {
        cache.removeAll()
    }
}

// MARK: - C Bridge Functions

@_silgen_name("path_search_create")
func path_search_create(_ paths: UnsafePointer<UnsafePointer<CChar>?>?, _ count: Int) -> OpaquePointer?

@_silgen_name("path_search_destroy")
func path_search_destroy(_ index: OpaquePointer?)

@_silgen_name("path_search_find")
func path_search_find(_ index: OpaquePointer?, _ pattern: UnsafePointer<CChar>?, _ limit: Int) -> OpaquePointer?

@_silgen_name("path_search_projected_find")
func path_search_projected_find(
    _ index: OpaquePointer?,
    _ pattern: UnsafePointer<CChar>?,
    _ displayPrefix: UnsafePointer<CChar>?,
    _ absolutePrefix: UnsafePointer<CChar>?,
    _ limit: Int
) -> OpaquePointer?

@_silgen_name("path_search_projected_find_cancellable")
func path_search_projected_find_cancellable(
    _ index: OpaquePointer?,
    _ pattern: UnsafePointer<CChar>?,
    _ displayPrefix: UnsafePointer<CChar>?,
    _ absolutePrefix: UnsafePointer<CChar>?,
    _ limit: Int,
    _ cancellation: OpaquePointer?,
    _ stats: UnsafeMutablePointer<path_search_work_stats_t>?
) -> OpaquePointer?

@_silgen_name("path_search_cancellation_create")
func path_search_cancellation_create() -> OpaquePointer?

@_silgen_name("path_search_cancellation_cancel")
func path_search_cancellation_cancel(_ cancellation: OpaquePointer?)

@_silgen_name("path_search_cancellation_destroy")
func path_search_cancellation_destroy(_ cancellation: OpaquePointer?)

@_silgen_name("search_result_destroy")
func search_result_destroy(_ result: OpaquePointer?)

struct search_result_t {
    var indices: UnsafeMutablePointer<size_t>?
    var scores: UnsafeMutablePointer<Int32>?
    var tieBreakKeys: UnsafeMutablePointer<UnsafePointer<CChar>?>?
    var count: size_t
    var capacity: size_t
}

struct path_search_work_stats_t {
    var examinedCount: size_t = 0
    var matchedCount: size_t = 0
    var heapPeakCount: size_t = 0
    var heapComparisonCount: size_t = 0
    var scratchBytes: size_t = 0
    var cancelled = false
}
