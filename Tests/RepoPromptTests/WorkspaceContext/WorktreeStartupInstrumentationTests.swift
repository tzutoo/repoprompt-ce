import Foundation
@testable import RepoPrompt
import XCTest

#if DEBUG
    final class WorktreeStartupInstrumentationTests: XCTestCase {
        func testObservationAndServingFlagsDefaultDisabledAndServingRequiresObservation() throws {
            let suiteName = "WorktreeStartupInstrumentationTests-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            XCTAssertEqual(WorktreeStartupFeatureFlags.current(defaults: defaults), .init())
            defaults.set(true, forKey: WorktreeStartupFeatureFlags.serveDefaultsKey)
            XCTAssertFalse(WorktreeStartupFeatureFlags.current(defaults: defaults).serveDiffSeededWorktreeStartup)
            defaults.set(true, forKey: WorktreeStartupFeatureFlags.observeDefaultsKey)
            XCTAssertEqual(
                WorktreeStartupFeatureFlags.current(defaults: defaults),
                .init(
                    observeDiffSeededWorktreeStartup: true,
                    serveDiffSeededWorktreeStartup: true
                )
            )

            let automatic = WorktreeStartupContext(agentSessionID: UUID())
            XCTAssertEqual(automatic.servingControl, .automatic)
            let forced = WorktreeStartupContext(
                agentSessionID: UUID(),
                flags: .init(
                    observeDiffSeededWorktreeStartup: true,
                    serveDiffSeededWorktreeStartup: true
                ),
                servingControl: .forceFullCrawl
            )
            XCTAssertEqual(forced.servingControl, .forceFullCrawl)
            XCTAssertTrue(forced.flags.serveDiffSeededWorktreeStartup)
        }

        func testNonGitMaterializationCarriesCorrelationUsesFullCrawlAndIssuesZeroGitCommands() async throws {
            let sandbox = FileManager.default.temporaryDirectory
                .appendingPathComponent("WorktreeStartupInstrumentationTests-\(UUID().uuidString)", isDirectory: true)
            let logicalURL = sandbox.appendingPathComponent("logical", isDirectory: true)
            let physicalURL = sandbox.appendingPathComponent("physical", isDirectory: true)
            try FileManager.default.createDirectory(at: logicalURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: physicalURL, withIntermediateDirectories: true)
            try "struct PlainRoot {}\n".write(
                to: physicalURL.appendingPathComponent("Plain.swift"),
                atomically: true,
                encoding: .utf8
            )
            defer { try? FileManager.default.removeItem(at: sandbox) }

            let store = WorkspaceFileContextStore()
            let logicalRecord = try await store.loadRoot(path: logicalURL.path)
            let logicalRoot = WorkspaceRootRef(
                id: logicalRecord.id,
                name: logicalRecord.name,
                fullPath: logicalRecord.standardizedFullPath
            )
            let physicalRoot = WorkspaceRootRef(id: UUID(), name: logicalRoot.name, fullPath: physicalURL.path)
            let binding = AgentSessionWorktreeBinding(
                id: "instrumentation-binding",
                repositoryID: "non-git",
                repoKey: "non-git",
                logicalRootPath: logicalRoot.standardizedFullPath,
                logicalRootName: logicalRoot.name,
                worktreeID: "plain-root",
                worktreeRootPath: physicalRoot.standardizedFullPath,
                source: "test"
            )
            let context = WorktreeStartupContext(
                agentSessionID: UUID(),
                correlationID: UUID(),
                flags: .init()
            )
            let sessionID = UUID()
            let materializer = WorkspaceRootBindingProjectionMaterializer(store: store)
            MCPToolWorkCountDiagnostics.resetForTesting()
            WorktreeStartupInstrumentation.resetForTesting()

            try await MCPToolWorkCountDiagnostics.withGitInvocation(operation: "non_git_worktree_startup") {
                let preparation = try await materializer.prepare(
                    sessionID: sessionID,
                    bindings: [binding],
                    startupContext: context
                )
                _ = try await materializer.commit(preparation)
            }

            let git = try XCTUnwrap(MCPToolWorkCountDiagnostics.debugSnapshots().git.last)
            XCTAssertEqual(git.commandCount, 0, git.commands.joined(separator: "\n"))
            let instrumentation = WorktreeStartupInstrumentation.snapshot()
            XCTAssertEqual(instrumentation.routeCounts, [.fullCrawl: 1])
            XCTAssertEqual(
                instrumentation.events.map(\.correlationID),
                Array(repeating: context.correlationID, count: instrumentation.events.count)
            )
            XCTAssertEqual(instrumentation.events.map(\.phase), [.rootLoadStarted, .rootReady])
            XCTAssertTrue(instrumentation.events.allSatisfy { !$0.observationEnabled && !$0.servingEnabled })

            await materializer.release(sessionID: sessionID)
            await store.unloadRoot(id: logicalRecord.id)
        }

        func testShadowCountersAreBoundedAndPathFree() {
            WorktreeStartupInstrumentation.resetForTesting()
            WorktreeStartupInstrumentation.recordInventoryComparison(matched: true)
            WorktreeStartupInstrumentation.recordInventoryComparison(matched: false)
            WorktreeStartupInstrumentation.recordProjectedSearchComparison(
                matched: true,
                baseEntryCount: 90,
                overlayEntryCount: 3,
                tombstoneCount: 2
            )
            WorktreeStartupInstrumentation.recordProjectedSearchComparison(
                matched: false,
                baseEntryCount: 89,
                overlayEntryCount: 4,
                tombstoneCount: 3
            )

            let snapshot = WorktreeStartupInstrumentation.snapshot()
            let counters = snapshot.shadow
            XCTAssertEqual(counters.inventoryComparisons, 2)
            XCTAssertEqual(counters.inventoryMatches, 1)
            XCTAssertEqual(counters.inventoryMismatches, 1)
            XCTAssertEqual(counters.projectedSearchComparisons, 2)
            XCTAssertEqual(counters.projectedSearchMatches, 1)
            XCTAssertEqual(counters.projectedSearchMismatches, 1)
            XCTAssertEqual(counters.latestBaseEntryCount, 89)
            XCTAssertEqual(counters.latestOverlayEntryCount, 4)
            XCTAssertEqual(counters.latestTombstoneCount, 3)
            XCTAssertEqual(snapshot.fallbackCounts[.projectedSearchMismatch], 1)
        }

        func testSeedCountersAreBoundedPathFreeAndCountFallbackOnce() {
            WorktreeStartupInstrumentation.resetForTesting()
            WorktreeStartupInstrumentation.recordSeedReceiptJournalCut(present: true)
            WorktreeStartupInstrumentation.recordSeedReceiptJournalCut(present: false)
            WorktreeStartupInstrumentation.recordSeedReplay(
                acceptedPayloadCount: Int.max,
                acceptedEventCount: 7,
                initializationWatermarkDelta: 5,
                serviceSequenceDelta: 4,
                changedPathCount: 3
            )
            WorktreeStartupInstrumentation.recordSeedMetadataRevalidation(used: false)
            WorktreeStartupInstrumentation.recordSeedMetadataRevalidation(used: true)
            WorktreeStartupInstrumentation.recordSeedProjectedPreparation(
                baseEntryCount: 90,
                overlayEntryCount: 3,
                tombstoneCount: 2
            )
            WorktreeStartupInstrumentation.recordSeedFullCrawlFallback()

            let seed = WorktreeStartupInstrumentation.snapshot().seed
            XCTAssertEqual(seed.receiptJournalCutPresent, 1)
            XCTAssertEqual(seed.receiptJournalCutAbsent, 1)
            XCTAssertEqual(seed.acceptedReplayPayloadCount, 1_000_000)
            XCTAssertEqual(seed.acceptedReplayEventCount, 7)
            XCTAssertEqual(seed.latestInitializationWatermarkDelta, 5)
            XCTAssertEqual(seed.latestServiceSequenceDelta, 4)
            XCTAssertEqual(seed.latestReplayChangedPathCount, 3)
            XCTAssertEqual(seed.metadataRevalidationChecks, 2)
            XCTAssertEqual(seed.metadataRevalidationUses, 1)
            XCTAssertEqual(seed.latestProjectedBaseEntryCount, 90)
            XCTAssertEqual(seed.latestProjectedOverlayEntryCount, 3)
            XCTAssertEqual(seed.latestProjectedTombstoneCount, 2)
            XCTAssertEqual(seed.fullCrawlFallbackCount, 1)
        }
    }
#endif
