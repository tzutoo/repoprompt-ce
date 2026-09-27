// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RepoPromptAgentProviders",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "RepoPromptClaudeCompatibleProvider",
            targets: ["RepoPromptClaudeCompatibleProvider"]
        ),
        .library(
            name: "RepoPromptPiProvider",
            targets: ["RepoPromptPiProvider"]
        )
    ],
    targets: [
        .target(
            name: "RepoPromptClaudeCompatibleProvider",
            path: "Sources/RepoPromptClaudeCompatibleProvider",
            swiftSettings: [.define("DEBUG", .when(configuration: .debug))]
        ),
        .testTarget(
            name: "RepoPromptClaudeCompatibleProviderTests",
            dependencies: ["RepoPromptClaudeCompatibleProvider"],
            path: "Tests/RepoPromptClaudeCompatibleProviderTests"
        ),
        .target(
            name: "RepoPromptPiProvider",
            path: "Sources/RepoPromptPiProvider",
            swiftSettings: [.define("DEBUG", .when(configuration: .debug))]
        ),
        .testTarget(
            name: "RepoPromptPiProviderTests",
            dependencies: ["RepoPromptPiProvider"],
            path: "Tests/RepoPromptPiProviderTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
