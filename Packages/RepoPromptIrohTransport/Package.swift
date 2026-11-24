// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RepoPromptIrohTransport",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "RepoPromptIrohTransport", targets: ["RepoPromptIrohTransport"]),
    ],
    targets: [
        // Always resolves against the gitignored local artifact, never SwiftPM's
        // binary-artifact downloader: that downloader can stall indefinitely on the
        // pinned release asset. Scripts/fetch-xcframework.sh populates this path with
        // curl + SHA-256 verification before every build/test/packaging entrypoint.
        // A file-existence fallback to the upstream url/checksum is deliberately not
        // used: SwiftPM caches evaluated manifests by content hash, so a manifest that
        // re-evaluates differently based on files on disk can keep serving a stale
        // remote-URL verdict after the artifact has been fetched.
        .binaryTarget(
            name: "IrohTransportFFI",
            path: "Artifacts/IrohTransportFFI.xcframework"
        ),
        .target(
            name: "RepoPromptIrohTransport",
            dependencies: ["IrohTransportFFI"],
            path: "Sources/RepoPromptIrohTransport",
            linkerSettings: [
                .linkedFramework("CoreWLAN", .when(platforms: [.macOS])),
                .linkedFramework("Network"),
                .linkedFramework("SystemConfiguration")
            ]
        ),
        .testTarget(
            name: "RepoPromptIrohTransportTests",
            dependencies: ["RepoPromptIrohTransport"],
            path: "Tests/RepoPromptIrohTransportTests"
        ),
    ]
)
