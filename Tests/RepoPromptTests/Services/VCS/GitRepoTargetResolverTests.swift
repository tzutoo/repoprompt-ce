@testable import RepoPrompt
import XCTest

final class GitRepoTargetResolverTests: XCTestCase {
    func testResolvesSupportedRepositorySelectorSyntax() async throws {
        let fixture = ResolverFixture()
        let scenarios = [
            ("current worktree", ["@wt"], [fixture.mainRepo], fixture.linkedRepo, [fixture.linkedRepo.rootPath]),
            ("main from linked worktree", ["@main"], [fixture.linkedRepo], fixture.linkedRepo, [fixture.mainRepo.rootPath]),
            ("main branch", ["@main:feature/demo"], [fixture.mainRepo], fixture.mainRepo, [fixture.linkedRepo.rootPath]),
            ("worktree ID", ["@id:\(fixture.linkedWorktree.worktreeID)"], [fixture.mainRepo], fixture.mainRepo, [fixture.linkedRepo.rootPath]),
            ("explicit branch", ["@branch:feature/demo"], [fixture.mainRepo], fixture.mainRepo, [fixture.linkedRepo.rootPath]),
            ("bare branch", ["feature/demo"], [fixture.mainRepo], fixture.mainRepo, [fixture.linkedRepo.rootPath]),
            ("worktree name", ["repo-feature"], [fixture.mainRepo], fixture.mainRepo, [fixture.linkedRepo.rootPath]),
            ("absolute path", [fixture.linkedRepo.rootPath], [fixture.mainRepo], fixture.mainRepo, [fixture.linkedRepo.rootPath])
        ]

        for scenario in scenarios {
            let repos = try await fixture.resolver.resolveRepoRoots(
                explicitRootTokens: scenario.1,
                allRepos: scenario.2,
                visibleRoots: fixture.visibleRoots,
                defaultRepo: scenario.3
            )

            XCTAssertEqual(repos.map(\.rootPath), scenario.4, scenario.0)
        }
    }

    func testRejectsLegacyWorktreeBranchSpecifier() async throws {
        let fixture = ResolverFixture()

        do {
            _ = try await fixture.resolver.resolveRepoRoots(
                explicitRootTokens: ["@wt:feature/demo"],
                allRepos: [fixture.mainRepo],
                visibleRoots: fixture.visibleRoots,
                defaultRepo: fixture.mainRepo
            )
            XCTFail("Expected @wt:<branch> to be rejected")
        } catch let error as GitRepoTargetResolverError {
            XCTAssertTrue(error.message.contains("@wt:feature/demo"))
            XCTAssertTrue(error.message.contains("@main:feature/demo"))
        }
    }

    func testDeduplicatesReposByResolvedPath() async throws {
        let fixture = ResolverFixture()
        let repos = try await fixture.resolver.resolveRepoRoots(
            explicitRootTokens: ["@main", fixture.mainRepo.rootPath],
            allRepos: [fixture.mainRepo],
            visibleRoots: fixture.visibleRoots,
            defaultRepo: fixture.linkedRepo
        )

        XCTAssertEqual(repos.map(\.rootPath), [fixture.mainRepo.rootPath])
    }

    func testExplicitBaseBranchSpecifierDoesNotSearchOtherRepos() async throws {
        let fixture = MultiRepoResolverFixture()

        do {
            _ = try await fixture.resolver.resolveRepoRoots(
                explicitRootTokens: ["repo-a@branch:feature/demo"],
                allRepos: [fixture.repoA.mainRepo, fixture.repoB.mainRepo],
                visibleRoots: fixture.visibleRoots,
                defaultRepo: fixture.repoA.mainRepo
            )
            XCTFail("Expected explicit repo-a branch selector not to resolve repo-b's worktree")
        } catch let error as GitRepoTargetResolverError {
            XCTAssertTrue(error.message.contains("No worktree found for branch 'feature/demo'"))
        }

        let global = try await fixture.resolver.resolveRepoRoots(
            explicitRootTokens: ["@branch:feature/demo"],
            allRepos: [fixture.repoA.mainRepo, fixture.repoB.mainRepo],
            visibleRoots: fixture.visibleRoots,
            defaultRepo: fixture.repoA.mainRepo
        )
        XCTAssertEqual(global.map(\.rootPath), [fixture.repoB.linkedRepo.rootPath])
    }

    func testMainSpecifierDoesNotListUnrelatedRepos() async throws {
        let fixture = MultiRepoResolverFixture(repoBListShouldThrow: true)
        let repos = try await fixture.resolver.resolveRepoRoots(
            explicitRootTokens: ["repo-a@main"],
            allRepos: [fixture.repoA.mainRepo, fixture.repoB.mainRepo],
            visibleRoots: fixture.visibleRoots,
            defaultRepo: fixture.repoA.mainRepo
        )

        XCTAssertEqual(repos.map(\.rootPath), [fixture.repoA.mainRepo.rootPath])
    }

    func testDuplicateWorktreeIDsAcrossReposRemainAmbiguous() async throws {
        let fixture = MultiRepoResolverFixture(duplicateLinkedWorktreeID: true)

        do {
            _ = try await fixture.resolver.resolveRepoRoots(
                explicitRootTokens: ["@id:wt_duplicate"],
                allRepos: [fixture.repoA.mainRepo, fixture.repoB.mainRepo],
                visibleRoots: fixture.visibleRoots,
                defaultRepo: fixture.repoA.mainRepo
            )
            XCTFail("Expected duplicate cross-repo worktree IDs to be ambiguous")
        } catch let error as GitRepoTargetResolverError {
            XCTAssertTrue(error.message.contains("Ambiguous worktree selector"))
        }
    }
}

private struct MultiRepoResolverFixture {
    let repoA: RepoFixtureData
    let repoB: RepoFixtureData
    let visibleRoots: [WorkspaceRootRef]
    let resolver: GitRepoTargetResolver

    init(repoBListShouldThrow: Bool = false, duplicateLinkedWorktreeID: Bool = false) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitRepoTargetResolverMultiRepoTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repoA = RepoFixtureData(root: root, name: "repo-a", linkedBranch: "topic/a", linkedWorktreeID: duplicateLinkedWorktreeID ? "wt_duplicate" : "wt_a")
        let repoB = RepoFixtureData(root: root, name: "repo-b", linkedBranch: "feature/demo", linkedWorktreeID: duplicateLinkedWorktreeID ? "wt_duplicate" : "wt_b")
        let visibleRoots = [
            WorkspaceRootRef(id: UUID(), name: "repo-a", fullPath: repoA.mainRepo.rootPath),
            WorkspaceRootRef(id: UUID(), name: "repo-b", fullPath: repoB.mainRepo.rootPath)
        ]

        let repos = [
            repoA.mainRepo.rootPath: repoA.mainRepo,
            repoA.linkedRepo.rootPath: repoA.linkedRepo,
            repoB.mainRepo.rootPath: repoB.mainRepo,
            repoB.linkedRepo.rootPath: repoB.linkedRepo
        ]
        let worktrees = [
            repoA.mainRepo.rootPath: repoA.worktrees,
            repoA.linkedRepo.rootPath: repoA.worktrees,
            repoB.mainRepo.rootPath: repoB.worktrees,
            repoB.linkedRepo.rootPath: repoB.worktrees
        ]
        let repoBMainPath = repoB.mainRepo.rootPath
        let repoBLinkedPath = repoB.linkedRepo.rootPath

        let resolver = GitRepoTargetResolver(dependencies: .init(
            resolveRepo: { url in
                let standardized = (url.path as NSString).standardizingPath
                for repo in repos.values where standardized == repo.rootPath || standardized.hasPrefix(repo.rootPath + "/") {
                    return repo
                }
                return nil
            },
            listWorktrees: { repo in
                if repoBListShouldThrow, repo.rootPath == repoBMainPath || repo.rootPath == repoBLinkedPath {
                    throw VCSError.parseError(message: "repo-b should not have been listed")
                }
                return worktrees[repo.rootPath] ?? []
            }
        ))

        self.repoA = repoA
        self.repoB = repoB
        self.visibleRoots = visibleRoots
        self.resolver = resolver
    }
}

private struct RepoFixtureData {
    let mainRepo: GitRepoDescriptor
    let linkedRepo: GitRepoDescriptor
    let worktrees: [GitWorktreeDescriptor]

    init(root: URL, name: String, linkedBranch: String, linkedWorktreeID: String) {
        let mainURL = root.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        let linkedURL = root.appendingPathComponent("\(name)-linked", isDirectory: true).standardizedFileURL
        mainRepo = GitRepoDescriptor(rootURL: mainURL)
        linkedRepo = GitRepoDescriptor(rootURL: linkedURL)
        let repository = GitWorktreeRepositoryIdentity(
            repositoryID: "gitrepo_\(name)",
            repoKey: "\(name)-fixture",
            displayName: name,
            commonGitDir: mainURL.appendingPathComponent(".git", isDirectory: true).path,
            mainWorktreeRoot: mainURL.path
        )
        worktrees = [
            GitWorktreeDescriptor(
                worktreeID: "wt_main_\(name)",
                repository: repository,
                path: mainURL.path,
                gitDir: mainURL.appendingPathComponent(".git", isDirectory: true).path,
                name: name,
                branch: "main",
                head: "1111111111111111111111111111111111111111",
                isMain: true,
                isCurrent: false,
                isDetached: false,
                isLocked: false,
                lockReason: nil,
                isPrunable: false,
                prunableReason: nil
            ),
            GitWorktreeDescriptor(
                worktreeID: linkedWorktreeID,
                repository: repository,
                path: linkedURL.path,
                gitDir: mainURL.appendingPathComponent(".git/worktrees/\(name)-linked", isDirectory: true).path,
                name: "\(name)-linked",
                branch: linkedBranch,
                head: "2222222222222222222222222222222222222222",
                isMain: false,
                isCurrent: false,
                isDetached: false,
                isLocked: false,
                lockReason: nil,
                isPrunable: false,
                prunableReason: nil
            )
        ]
    }
}

private struct ResolverFixture {
    let root: URL
    let mainRepo: GitRepoDescriptor
    let linkedRepo: GitRepoDescriptor
    let repository: GitWorktreeRepositoryIdentity
    let mainWorktree: GitWorktreeDescriptor
    let linkedWorktree: GitWorktreeDescriptor
    let visibleRoots: [WorkspaceRootRef]
    let resolver: GitRepoTargetResolver

    init() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitRepoTargetResolverTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let mainURL = root.appendingPathComponent("repo", isDirectory: true).standardizedFileURL
        let linkedURL = root.appendingPathComponent("repo-feature", isDirectory: true).standardizedFileURL
        let mainRepo = GitRepoDescriptor(rootURL: mainURL)
        let linkedRepo = GitRepoDescriptor(rootURL: linkedURL)
        let repository = GitWorktreeRepositoryIdentity(
            repositoryID: "gitrepo_fixture",
            repoKey: "repo-fixture",
            displayName: "repo",
            commonGitDir: mainURL.appendingPathComponent(".git", isDirectory: true).path,
            mainWorktreeRoot: mainURL.path
        )
        let mainWorktree = GitWorktreeDescriptor(
            worktreeID: "wt_main",
            repository: repository,
            path: mainURL.path,
            gitDir: mainURL.appendingPathComponent(".git", isDirectory: true).path,
            name: "repo",
            branch: "main",
            head: "1111111111111111111111111111111111111111",
            isMain: true,
            isCurrent: false,
            isDetached: false,
            isLocked: false,
            lockReason: nil,
            isPrunable: false,
            prunableReason: nil
        )
        let linkedWorktree = GitWorktreeDescriptor(
            worktreeID: "wt_feature",
            repository: repository,
            path: linkedURL.path,
            gitDir: mainURL.appendingPathComponent(".git/worktrees/repo-feature", isDirectory: true).path,
            name: "repo-feature",
            branch: "feature/demo",
            head: "2222222222222222222222222222222222222222",
            isMain: false,
            isCurrent: false,
            isDetached: false,
            isLocked: false,
            lockReason: nil,
            isPrunable: false,
            prunableReason: nil
        )
        let visibleRoots = [
            WorkspaceRootRef(id: UUID(), name: "repo", fullPath: mainURL.path)
        ]

        let descriptorsByPath = [
            mainRepo.rootPath: mainRepo,
            linkedRepo.rootPath: linkedRepo
        ]
        let worktrees = [mainRepo.rootPath: [mainWorktree, linkedWorktree], linkedRepo.rootPath: [mainWorktree, linkedWorktree]]
        let resolver = GitRepoTargetResolver(dependencies: .init(
            resolveRepo: { url in
                let standardized = (url.path as NSString).standardizingPath
                if standardized == mainRepo.rootPath || standardized.hasPrefix(mainRepo.rootPath + "/") {
                    return mainRepo
                }
                if standardized == linkedRepo.rootPath || standardized.hasPrefix(linkedRepo.rootPath + "/") {
                    return linkedRepo
                }
                return descriptorsByPath[standardized]
            },
            listWorktrees: { repo in
                worktrees[repo.rootPath] ?? []
            }
        ))

        self.root = root
        self.mainRepo = mainRepo
        self.linkedRepo = linkedRepo
        self.repository = repository
        self.mainWorktree = mainWorktree
        self.linkedWorktree = linkedWorktree
        self.visibleRoots = visibleRoots
        self.resolver = resolver
    }
}
