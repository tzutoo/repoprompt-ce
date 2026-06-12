@testable import RepoPrompt
import XCTest

#if DEBUG
    final class WorkspaceCatalogShardTests: XCTestCase {
        private var temporaryRoots: [URL] = []

        override func tearDownWithError() throws {
            for url in temporaryRoots {
                try? FileManager.default.removeItem(at: url)
            }
            temporaryRoots.removeAll()
            try super.tearDownWithError()
        }

        func testTopologyChurnRebuildsOnlyAffectedRootShardsAndShadowMatchesAuthoritativeBytes() async throws {
            let visibleAURL = try makeTemporaryRoot(name: "ShardVisibleA")
            let visibleBURL = try makeTemporaryRoot(name: "ShardVisibleB")
            let gitDataURL = try makeTemporaryRoot(name: "ShardGitData")
            let supplementalURL = try makeTemporaryRoot(name: "ShardSupplemental")
            let worktreeURL = try makeTemporaryRoot(name: "ShardWorktree")
            try write("a", to: visibleAURL.appendingPathComponent("Z.swift"))
            try write("b", to: visibleBURL.appendingPathComponent("A.swift"))
            try write("git", to: gitDataURL.appendingPathComponent("MAP.txt"))
            try write("system", to: supplementalURL.appendingPathComponent("System.swift"))
            try write("worktree", to: worktreeURL.appendingPathComponent("Worktree.swift"))

            let store = WorkspaceFileContextStore()
            let visibleA = try await store.loadRoot(path: visibleAURL.path)
            let visibleB = try await store.loadRoot(path: visibleBURL.path)
            let gitData = try await store.loadRoot(path: gitDataURL.path, kind: .workspaceGitData)
            let supplemental = try await store.loadRoot(path: supplementalURL.path, kind: .supplementalSystem)
            let worktree = try await store.loadRoot(path: worktreeURL.path, kind: .sessionWorktree)
            let sessionScope = WorkspaceLookupRootScope.sessionBoundWorkspace(
                logicalRootPaths: [visibleAURL.path],
                physicalRootPaths: [worktreeURL.path]
            )

            let visibleSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            let gitDataSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspacePlusGitData)
            let allLoadedSnapshot = await store.searchCatalogSnapshot(rootScope: .allLoaded)
            let sessionSnapshot = await store.searchCatalogSnapshot(rootScope: sessionScope)
            XCTAssertEqual(visibleSnapshot.roots.map(\.id), [visibleA.id, visibleB.id])
            XCTAssertEqual(gitDataSnapshot.roots.map(\.id), [visibleA.id, visibleB.id, gitData.id])
            XCTAssertEqual(allLoadedSnapshot.roots.map(\.id), [visibleA.id, visibleB.id, gitData.id, supplemental.id, worktree.id])
            XCTAssertEqual(sessionSnapshot.roots.map(\.id), [visibleB.id, worktree.id])
            for snapshot in [visibleSnapshot, gitDataSnapshot, allLoadedSnapshot, sessionSnapshot] {
                XCTAssertEqual(snapshot.files.map(\.standardizedFullPath), snapshot.files.map(\.standardizedFullPath).sorted())
            }

            var diagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            XCTAssertEqual(diagnostics.shadowComparisonCount, 4)
            XCTAssertEqual(diagnostics.shadowMismatchCount, 0)
            XCTAssertGreaterThan(diagnostics.lastShadowByteCount, 0)
            XCTAssertEqual(diagnostics.publishedShardCount, 5)
            XCTAssertEqual(buildCount(rootID: visibleA.id, in: diagnostics), 1)
            XCTAssertEqual(buildCount(rootID: visibleB.id, in: diagnostics), 1)
            XCTAssertEqual(buildCount(rootID: gitData.id, in: diagnostics), 1)
            XCTAssertEqual(buildCount(rootID: supplemental.id, in: diagnostics), 1)
            XCTAssertEqual(buildCount(rootID: worktree.id, in: diagnostics), 1)

            try write("added", to: visibleAURL.appendingPathComponent("Middle.swift"))
            await store.replayObservedFileSystemDeltas(rootID: visibleA.id, deltas: [.fileAdded("Middle.swift")])
            let changedVisible = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            let changedAllLoaded = await store.searchCatalogSnapshot(rootScope: .allLoaded)
            XCTAssertTrue(changedVisible.files.contains { $0.standardizedRelativePath == "Middle.swift" })
            XCTAssertTrue(changedAllLoaded.files.contains { $0.standardizedRelativePath == "Middle.swift" })

            diagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            XCTAssertEqual(buildCount(rootID: visibleA.id, in: diagnostics), 2)
            XCTAssertEqual(buildCount(rootID: visibleB.id, in: diagnostics), 1)
            XCTAssertEqual(buildCount(rootID: gitData.id, in: diagnostics), 1)
            XCTAssertEqual(buildCount(rootID: supplemental.id, in: diagnostics), 1)
            XCTAssertEqual(buildCount(rootID: worktree.id, in: diagnostics), 1)

            await store.unloadRoot(id: visibleB.id)
            let afterUnload = await store.searchCatalogSnapshot(rootScope: .allLoaded)
            XCTAssertFalse(afterUnload.roots.contains { $0.id == visibleB.id })
            diagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            XCTAssertEqual(diagnostics.publishedShardCount, 4)
            XCTAssertEqual(buildCount(rootID: visibleA.id, in: diagnostics), 2)
            XCTAssertEqual(buildCount(rootID: gitData.id, in: diagnostics), 1)
            XCTAssertEqual(buildCount(rootID: supplemental.id, in: diagnostics), 1)
            XCTAssertEqual(buildCount(rootID: worktree.id, in: diagnostics), 1)

            let replacementB = try await store.loadRoot(path: visibleBURL.path)
            let afterReload = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertNotEqual(replacementB.id, visibleB.id)
            XCTAssertTrue(afterReload.roots.contains { $0.id == replacementB.id })
            diagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            XCTAssertEqual(buildCount(rootID: replacementB.id, in: diagnostics), 1)
            XCTAssertEqual(buildCount(rootID: visibleA.id, in: diagnostics), 2)
            XCTAssertEqual(buildCount(rootID: gitData.id, in: diagnostics), 1)
            XCTAssertEqual(buildCount(rootID: supplemental.id, in: diagnostics), 1)
            XCTAssertEqual(buildCount(rootID: worktree.id, in: diagnostics), 1)
            XCTAssertEqual(diagnostics.shadowComparisonCount, 8)
            XCTAssertEqual(diagnostics.shadowMismatchCount, 0)
        }

        func testRetainedSnapshotsKeepOldGenerationsAliveAndBackstopRecoversAfterRelease() async throws {
            let rootURL = try makeTemporaryRoot(name: "ShardRetention")
            try write("seed", to: rootURL.appendingPathComponent("Seed.swift"))

            let store = WorkspaceFileContextStore()
            let root = try await store.loadRoot(path: rootURL.path)
            var retainedSnapshots = await [store.searchCatalogSnapshot(rootScope: .visibleWorkspace)]
            let cap = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards.liveGenerationCapPerRoot
            XCTAssertGreaterThan(cap, 1)

            for generation in 1 ..< cap {
                let relativePath = "Retained-\(generation).swift"
                try write("retained", to: rootURL.appendingPathComponent(relativePath))
                await store.replayObservedFileSystemDeltas(rootID: root.id, deltas: [.fileAdded(relativePath)])
                await retainedSnapshots.append(store.searchCatalogSnapshot(rootScope: .visibleWorkspace))
            }

            var diagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            var rootDiagnostics = try XCTUnwrap(diagnostics.roots.first { $0.rootID == root.id })
            XCTAssertEqual(rootDiagnostics.liveTopologyGenerations.count, cap)
            XCTAssertEqual(rootDiagnostics.retainedTopologyGenerations.count, cap - 1)
            XCTAssertEqual(rootDiagnostics.buildCount, cap)
            XCTAssertEqual(rootDiagnostics.backstopCount, 0)
            XCTAssertEqual(rootDiagnostics.maxLiveGenerationCount, cap)

            let backstopPath = "Backstop.swift"
            try write("backstop", to: rootURL.appendingPathComponent(backstopPath))
            await store.replayObservedFileSystemDeltas(rootID: root.id, deltas: [.fileAdded(backstopPath)])
            let backstopSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertTrue(backstopSnapshot.files.contains { $0.standardizedRelativePath == backstopPath })

            diagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            rootDiagnostics = try XCTUnwrap(diagnostics.roots.first { $0.rootID == root.id })
            XCTAssertNil(rootDiagnostics.publishedTopologyGeneration)
            XCTAssertEqual(rootDiagnostics.liveTopologyGenerations.count, cap)
            XCTAssertEqual(rootDiagnostics.retainedTopologyGenerations.count, cap)
            XCTAssertEqual(rootDiagnostics.buildCount, cap)
            XCTAssertEqual(rootDiagnostics.backstopCount, 1)
            XCTAssertEqual(diagnostics.totalBackstopCount, 1)
            XCTAssertEqual(diagnostics.shadowComparisonCount, cap)
            XCTAssertEqual(diagnostics.shadowMismatchCount, 0)

            retainedSnapshots.removeAll(keepingCapacity: false)
            let recoveredSnapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertEqual(recoveredSnapshot, backstopSnapshot)

            diagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            rootDiagnostics = try XCTUnwrap(diagnostics.roots.first { $0.rootID == root.id })
            XCTAssertNotNil(rootDiagnostics.publishedTopologyGeneration)
            XCTAssertEqual(rootDiagnostics.liveTopologyGenerations.count, 1)
            XCTAssertTrue(rootDiagnostics.retainedTopologyGenerations.isEmpty)
            XCTAssertEqual(rootDiagnostics.buildCount, cap + 1)
            XCTAssertEqual(rootDiagnostics.backstopCount, 1)
            XCTAssertEqual(diagnostics.shadowComparisonCount, cap + 1)
            XCTAssertEqual(diagnostics.shadowMismatchCount, 0)
        }

        private func buildCount(
            rootID: UUID,
            in diagnostics: WorkspaceFileContextStore.RootCatalogShardDebugSnapshot
        ) -> Int {
            diagnostics.roots.first { $0.rootID == rootID }?.buildCount ?? 0
        }

        private func makeTemporaryRoot(name: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("RepoPrompt-\(name)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            temporaryRoots.append(url)
            return url
        }

        private func write(_ content: String, to url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }
#endif
