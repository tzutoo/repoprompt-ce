import Foundation

enum WorkspaceRootSeedServingPlanningOutcome: Equatable {
    case planned(
        plan: WorkspaceRootSeedPlan,
        authorityFence: GitWorkspacePendingInitializationAuthorityFence
    )
    case fallback(WorkspaceRootSeedFallbackReason)
}

actor WorkspaceRootSeedPlanner {
    static let shared = WorkspaceRootSeedPlanner()

    private struct SeedEntry {
        let mode: String
        let kind: GitTreeEntryKind
    }

    private let gitService: GitService
    private let authority: GitWorkspaceStateAuthority
    private let limits: WorkspaceRootSeedPlannerLimits

    init(
        gitService: GitService = GitService(),
        authority: GitWorkspaceStateAuthority = .shared,
        limits: WorkspaceRootSeedPlannerLimits = .production
    ) {
        self.gitService = gitService
        self.authority = authority
        self.limits = limits
    }

    func plan(
        hint: WorkspaceRootMaterializationHint,
        service: FileSystemService
    ) async -> WorkspaceRootSeedPlannerOutcome {
        let result = await planningResult(
            hint: hint,
            service: service,
            retainFinalAuthorityFence: false
        )
        return result.outcome
    }

    func planForServing(
        hint: WorkspaceRootMaterializationHint,
        service: FileSystemService
    ) async -> WorkspaceRootSeedServingPlanningOutcome {
        let result = await planningResult(
            hint: hint,
            service: service,
            retainFinalAuthorityFence: true
        )
        switch result.outcome {
        case let .fallback(reason):
            return .fallback(reason)
        case let .planned(plan):
            guard let fence = result.authorityFence else {
                return .fallback(.authorityUnstable)
            }
            return .planned(plan: plan, authorityFence: fence)
        }
    }

    private func planningResult(
        hint: WorkspaceRootMaterializationHint,
        service: FileSystemService,
        retainFinalAuthorityFence: Bool
    ) async -> (outcome: WorkspaceRootSeedPlannerOutcome, authorityFence: GitWorkspacePendingInitializationAuthorityFence?) {
        do {
            try Task.checkCancellation()
            guard let snapshot = await authority.reusableSnapshot(
                identity: hint.creationReceipt.parentSnapshotIdentity,
                expectedCompatibilityKey: hint.creationReceipt.parentCompatibilityKey
            ) else { return (.fallback(.baseEvicted), nil) }

            let receipt = hint.creationReceipt
            let before = try await gitService.generationFencedAuthoritySnapshot(
                layout: receipt.targetLayout,
                prefix: receipt.repositoryRelativeRootPrefix
            )
            let targetCompatibility = WorkspaceRootSeedCompatibilityKey(authority: before)
            guard targetCompatibility.isDeltaCompatible(with: snapshot.compatibilityKey) else {
                return (.fallback(.compatibilityMismatch), nil)
            }

            let treeDelta = try await gitService.diffTrees(
                baseTreeOID: snapshot.compatibilityKey.treeOID,
                targetTreeOID: before.treeOID,
                in: receipt.targetLayout,
                prefix: receipt.repositoryRelativeRootPrefix
            )
            let index = try await gitService.indexManifest(
                in: receipt.targetLayout,
                prefix: receipt.repositoryRelativeRootPrefix
            )
            let status = try await gitService.worktreeStatus(
                in: receipt.targetLayout,
                prefix: receipt.repositoryRelativeRootPrefix
            )

            let verificationScope = try Self.verificationScope(
                treeDelta: treeDelta,
                status: status,
                copiedRepositoryRelativePaths: receipt.exactCopiedRelativePaths,
                witnessRepositoryRelativePaths: receipt.witnessCoverage.destinationRelativePaths,
                witnessRepositoryRelativeDirectories: receipt.witnessCoverage.affectedDestinationRelativeDirectories,
                prefix: receipt.repositoryRelativeRootPrefix,
                limits: limits
            )
            let facts = try await service.workspaceRootSeedVerificationFacts(
                relativePaths: verificationScope.paths,
                affectedDirectories: verificationScope.directories,
                allowRepositoryMetadataAtRoot: receipt.repositoryRelativeRootPrefix.value.isEmpty,
                limits: limits
            )

            let authorityFence: GitWorkspacePendingInitializationAuthorityFence?
            let after: GitWorkspaceAuthoritySnapshot
            if retainFinalAuthorityFence {
                let fence = try await gitService.pendingInitializationAuthorityFence(
                    layout: receipt.targetLayout,
                    prefix: receipt.repositoryRelativeRootPrefix
                )
                authorityFence = fence
                after = fence.snapshot
            } else {
                authorityFence = nil
                after = try await gitService.generationFencedAuthoritySnapshot(
                    layout: receipt.targetLayout,
                    prefix: receipt.repositoryRelativeRootPrefix
                )
            }
            guard before == after else {
                if let authorityFence {
                    await gitService.releasePendingInitializationAuthorityFence(authorityFence)
                }
                return (.fallback(.authorityUnstable), nil)
            }
            let outcome = Self.materialize(
                snapshot: snapshot,
                targetTreeOID: before.treeOID,
                treeDelta: treeDelta,
                index: index,
                status: status,
                verificationFacts: facts,
                copiedRepositoryRelativePaths: receipt.exactCopiedRelativePaths,
                prefix: receipt.repositoryRelativeRootPrefix,
                limits: limits
            )
            if case .fallback = outcome, let authorityFence {
                await gitService.releasePendingInitializationAuthorityFence(authorityFence)
                return (outcome, nil)
            }
            return (outcome, authorityFence)
        } catch is CancellationError {
            return (.fallback(.cancellation), nil)
        } catch WorkspaceRootSeedVerificationError.limitExceeded {
            return (.fallback(.verificationLimitExceeded), nil)
        } catch WorkspaceRootSeedVerificationError.invalidPath {
            return (.fallback(.unexplainedFilesystemEntry), nil)
        } catch WorkspaceRootSeedVerificationError.unsupportedTopology {
            return (.fallback(.submoduleOrNestedRepository), nil)
        } catch let reason as GitWorkspaceAuthorityUnavailableReason {
            switch reason {
            case .mutationInProgress, .metadataEventPending:
                return (.fallback(.authorityChanging), nil)
            case .noSnapshot, .monitorCoverageUnavailable, .superseded,
                 .invalidatedDuringCollection, .collectionScopeMismatch:
                return (.fallback(.authorityUnstable), nil)
            }
        } catch let error as GitWorktreeInitializationError {
            switch error.reason {
            case .timeout:
                return (.fallback(.gitTimeout), nil)
            case .cappedOutput, .recordLimitExceeded, .pathLimitExceeded:
                return (.fallback(.gitCappedOutput), nil)
            case .malformedOutput, .invalidRootPrefix:
                return (.fallback(.gitMalformedOutput), nil)
            case .gitError:
                return (.fallback(.gitError), nil)
            case .cancelled:
                return (.fallback(.cancellation), nil)
            }
        } catch {
            return (.fallback(.gitError), nil)
        }
    }

    static func materialize(
        snapshot: WorkspaceRootReusableSnapshot,
        targetTreeOID: GitObjectID,
        treeDelta: [GitTreeDeltaRecord],
        index: GitIndexManifest,
        status: GitStatusPorcelainV2Snapshot,
        verificationFacts: [String: WorkspaceRootSeedVerificationFact],
        copiedRepositoryRelativePaths: [String],
        prefix: GitRepositoryRelativeRootPrefix,
        limits: WorkspaceRootSeedPlannerLimits = .production
    ) -> WorkspaceRootSeedPlannerOutcome {
        guard snapshot.compatibilityKey.repositoryRelativeRootPrefix == prefix,
              index.rootPrefix == prefix,
              snapshot.compatibilityKey.objectFormat == targetTreeOID.objectFormat
        else { return .fallback(.compatibilityMismatch) }

        guard !index.sparseCheckoutEnabled else { return .fallback(.sparseCheckout) }

        let baseFilePaths = Set(snapshot.inventory.entries.compactMap { entry in
            entry.isSearchableFile ? StandardizedPath.relative(entry.relativePath) : nil
        })
        if snapshot.inventory.entries.contains(where: { $0.mode == "160000" || $0.kind == .commit }) {
            return .fallback(.submoduleOrNestedRepository)
        }
        if snapshot.inventory.entries.contains(where: { !supported(mode: $0.mode, kind: $0.kind) }) {
            return .fallback(.symlinkOrSpecialTopology)
        }

        var targetTree: [String: SeedEntry] = [:]
        for entry in snapshot.inventory.entries {
            targetTree[StandardizedPath.relative(entry.relativePath)] = SeedEntry(
                mode: entry.mode,
                kind: entry.kind
            )
        }
        var changedPaths = Set<String>()
        for delta in treeDelta {
            guard delta.status != .unmerged else { return .fallback(.conflictOrUnmergedIndex) }
            guard let destination = rootRelative(delta.repositoryRelativePath, prefix: prefix) else {
                return .fallback(.compatibilityMismatch)
            }
            if case .renamed = delta.status {
                guard let source = delta.sourceRepositoryRelativePath.flatMap({ rootRelative($0, prefix: prefix) }) else {
                    return .fallback(.gitMalformedOutput)
                }
                targetTree.removeValue(forKey: source)
                changedPaths.insert(source)
            }
            if case .deleted = delta.status {
                targetTree.removeValue(forKey: destination)
                changedPaths.insert(destination)
                continue
            }
            if delta.newMode == "160000" { return .fallback(.submoduleOrNestedRepository) }
            guard let mode = delta.newMode,
                  delta.newObjectID != nil,
                  let kind = kind(for: mode),
                  supported(mode: mode, kind: kind)
            else { return .fallback(.symlinkOrSpecialTopology) }
            targetTree[destination] = SeedEntry(mode: mode, kind: kind)
            changedPaths.insert(destination)
        }
        for delta in treeDelta where delta.status == .typeChanged || delta.oldMode != delta.newMode {
            guard let relativePath = rootRelative(delta.repositoryRelativePath, prefix: prefix),
                  let fact = verificationFacts[relativePath]
            else { return .fallback(.unexplainedFilesystemEntry) }
            guard factMatches(mode: delta.newMode, fact: fact) else {
                return .fallback(.symlinkOrSpecialTopology)
            }
        }

        var tracked: [String: SeedEntry] = [:]
        for entry in index.entries {
            guard entry.stage == 0 else { return .fallback(.conflictOrUnmergedIndex) }
            guard !entry.assumeUnchanged else { return .fallback(.assumeUnchangedIndexEntry) }
            guard !entry.skipWorktree else { return .fallback(.sparseCheckout) }
            if entry.mode == "160000" { return .fallback(.submoduleOrNestedRepository) }
            guard let relativePath = rootRelative(entry.repositoryRelativePath, prefix: prefix),
                  let kind = kind(for: entry.mode),
                  supported(mode: entry.mode, kind: kind)
            else { return .fallback(.symlinkOrSpecialTopology) }
            tracked[relativePath] = SeedEntry(mode: entry.mode, kind: kind)
        }
        let targetTreeFilePaths = Set(targetTree.compactMap { relativePath, entry in
            entry.kind == .blob && (entry.mode == "100644" || entry.mode == "100755")
                ? relativePath
                : nil
        })
        changedPaths.formUnion(targetTreeFilePaths.symmetricDifference(Set(tracked.keys)))

        var files = Set(tracked.keys)
        var explicitFolders = Set<String>()
        for record in status.pathRecords {
            guard record.kind != .unmerged else { return .fallback(.conflictOrUnmergedIndex) }
            if let submoduleState = record.submoduleState,
               submoduleState.first != "N"
            {
                return .fallback(.submoduleOrNestedRepository)
            }
            guard let relativePath = rootRelative(record.path, prefix: prefix) else {
                return .fallback(.compatibilityMismatch)
            }
            switch record.kind {
            case .unmerged:
                return .fallback(.conflictOrUnmergedIndex)
            case .ignored:
                continue
            case .untracked:
                changedPaths.insert(relativePath)
                guard let fact = verificationFacts[relativePath] else {
                    return .fallback(.unexplainedFilesystemEntry)
                }
                guard applyUntrackedFact(fact, files: &files, folders: &explicitFolders) else {
                    return .fallback(.symlinkOrSpecialTopology)
                }
            case let .renamedOrCopied(originalPath, score):
                changedPaths.insert(relativePath)
                guard let source = rootRelative(originalPath, prefix: prefix),
                      let fact = verificationFacts[relativePath]
                else { return .fallback(.unexplainedFilesystemEntry) }
                if score.first == "R" { files.remove(source) }
                guard applyTrackedFact(
                    fact,
                    expectedMode: record.workTreeMode ?? record.indexMode,
                    files: &files,
                    folders: &explicitFolders
                ) else { return .fallback(.symlinkOrSpecialTopology) }
                changedPaths.insert(source)
            case .ordinary:
                if record.hasWorkTreeChange || record.hasIndexChange {
                    changedPaths.insert(relativePath)
                }
                if record.workTreeStatus == "D" {
                    files.remove(relativePath)
                    continue
                }
                if record.hasWorkTreeChange || record.hasIndexChange {
                    guard let fact = verificationFacts[relativePath] else {
                        return .fallback(.unexplainedFilesystemEntry)
                    }
                    guard applyTrackedFact(
                        fact,
                        expectedMode: record.workTreeMode ?? record.indexMode,
                        files: &files,
                        folders: &explicitFolders
                    ) else { return .fallback(.symlinkOrSpecialTopology) }
                }
            }
        }

        let copiedRelativePaths = copiedRepositoryRelativePaths.compactMap { rootRelative($0, prefix: prefix) }
        for relativePath in copiedRelativePaths {
            guard let fact = verificationFacts[relativePath] else {
                return .fallback(.unknownCopiedPath)
            }
            guard applyUntrackedFact(fact, files: &files, folders: &explicitFolders) else {
                return .fallback(.symlinkOrSpecialTopology)
            }
            if !fact.isIgnored { changedPaths.insert(relativePath) }
        }

        // Receipt-affected directory enumeration may expose additional untracked siblings.
        for fact in verificationFacts.values where !tracked.keys.contains(fact.relativePath) {
            guard applyUntrackedFact(fact, files: &files, folders: &explicitFolders) else {
                return .fallback(.symlinkOrSpecialTopology)
            }
            if !fact.isIgnored, fact.kind != .missing {
                changedPaths.insert(fact.relativePath)
            }
        }

        var folders = explicitFolders
        for path in files {
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty, parent != "." {
                folders.insert(StandardizedPath.relative(parent))
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        guard changedPaths.count < limits.maximumOverlayChangedFileCount else {
            return .fallback(.overlayThresholdExceeded)
        }
        return .planned(WorkspaceRootSeedPlan(
            snapshotIdentity: snapshot.identity,
            targetTreeOID: targetTreeOID,
            relativeFilePaths: files,
            relativeFolderPaths: folders,
            baseRelativeFilePaths: baseFilePaths,
            changedRelativeFilePaths: changedPaths,
            tombstonedBaseRelativeFilePaths: baseFilePaths.subtracting(files),
            verifiedPathCount: verificationFacts.count
        ))
    }

    private static func verificationScope(
        treeDelta: [GitTreeDeltaRecord],
        status: GitStatusPorcelainV2Snapshot,
        copiedRepositoryRelativePaths: [String],
        witnessRepositoryRelativePaths: [String],
        witnessRepositoryRelativeDirectories: [String],
        prefix: GitRepositoryRelativeRootPrefix,
        limits: WorkspaceRootSeedPlannerLimits
    ) throws -> (paths: Set<String>, directories: Set<String>) {
        var paths = Set<String>()
        for record in treeDelta {
            if let relative = rootRelative(record.repositoryRelativePath, prefix: prefix) { paths.insert(relative) }
            if let source = record.sourceRepositoryRelativePath.flatMap({ rootRelative($0, prefix: prefix) }) {
                paths.insert(source)
            }
        }
        for record in status.pathRecords {
            if let relative = rootRelative(record.path, prefix: prefix) { paths.insert(relative) }
            if case let .renamedOrCopied(originalPath, _) = record.kind,
               let source = rootRelative(originalPath, prefix: prefix)
            {
                paths.insert(source)
            }
        }
        for path in copiedRepositoryRelativePaths {
            if let relative = rootRelative(path, prefix: prefix) { paths.insert(relative) }
        }
        for path in witnessRepositoryRelativePaths
            where !path.isEmpty && path != ".git" && !path.hasPrefix(".git/")
        {
            if let relative = rootRelative(path, prefix: prefix) { paths.insert(relative) }
        }
        var directories = Set<String>(witnessRepositoryRelativeDirectories.compactMap { value -> String? in
            guard !value.isEmpty, value != ".git", !value.hasPrefix(".git/") else { return nil }
            return rootRelativeDirectory(value, prefix: prefix)
        })
        directories.remove(".")
        directories.remove("")
        guard paths.count <= limits.maximumVerificationPathCount,
              directories.count <= limits.maximumAffectedDirectoryCount
        else { throw WorkspaceRootSeedVerificationError.limitExceeded }
        return (paths, directories)
    }

    private static func rootRelative(
        _ repositoryRelativePath: String,
        prefix: GitRepositoryRelativeRootPrefix
    ) -> String? {
        guard prefix.contains(repositoryRelativePath) else { return nil }
        if prefix.value.isEmpty { return StandardizedPath.relative(repositoryRelativePath) }
        guard repositoryRelativePath != prefix.value else { return nil }
        return StandardizedPath.relative(String(repositoryRelativePath.dropFirst(prefix.value.count + 1)))
    }

    private static func rootRelativeDirectory(
        _ repositoryRelativePath: String,
        prefix: GitRepositoryRelativeRootPrefix
    ) -> String? {
        if repositoryRelativePath.isEmpty { return prefix.value.isEmpty ? "" : nil }
        if repositoryRelativePath == prefix.value { return "" }
        return rootRelative(repositoryRelativePath, prefix: prefix)
    }

    private static func kind(for mode: String) -> GitTreeEntryKind? {
        switch mode {
        case "040000": .tree
        case "100644", "100755", "120000": .blob
        case "160000": .commit
        default: nil
        }
    }

    private static func supported(mode: String, kind: GitTreeEntryKind) -> Bool {
        kind == .tree || (kind == .blob && (mode == "100644" || mode == "100755"))
    }

    private static func factMatches(
        mode: String?,
        fact: WorkspaceRootSeedVerificationFact
    ) -> Bool {
        switch (mode, fact.kind) {
        case (nil, .missing):
            true
        case ("040000", .directory):
            true
        case ("100644", .regularFile(isExecutable: false)):
            true
        case ("100755", .regularFile(isExecutable: true)):
            true
        default:
            false
        }
    }

    @discardableResult
    private static func applyTrackedFact(
        _ fact: WorkspaceRootSeedVerificationFact,
        expectedMode: String?,
        files: inout Set<String>,
        folders: inout Set<String>
    ) -> Bool {
        switch fact.kind {
        case .missing:
            files.remove(fact.relativePath)
            return true
        case let .regularFile(isExecutable):
            if let expectedMode,
               (expectedMode == "100755") != isExecutable,
               expectedMode == "100644" || expectedMode == "100755"
            {
                return false
            }
            files.insert(fact.relativePath)
            return true
        case .directory:
            files.remove(fact.relativePath)
            folders.insert(fact.relativePath)
            return true
        case .symbolicLink, .special:
            return false
        }
    }

    @discardableResult
    private static func applyUntrackedFact(
        _ fact: WorkspaceRootSeedVerificationFact,
        files: inout Set<String>,
        folders: inout Set<String>
    ) -> Bool {
        guard !fact.isIgnored else { return true }
        switch fact.kind {
        case .regularFile:
            files.insert(fact.relativePath)
            return true
        case .directory:
            folders.insert(fact.relativePath)
            return true
        case .missing:
            return true
        case .symbolicLink, .special:
            return false
        }
    }
}
