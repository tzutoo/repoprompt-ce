import Foundation
import RepoPromptSecureStorage
import RepoPromptSettingsCore
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class OpenCodeConnectedHintValidationTests: XCTestCase {
    private struct RefreshClient: OpenCodeACPModelDiscoveryClient {
        let failure: any Error

        func discoverModels(workspacePath _: String?, modelRaw _: String?) async throws -> OpenCodeACPModelDiscoveryResult? {
            throw failure
        }
    }

    func testCachedValidationClearsConnectedHintWhenExecutableIsMissing() async {
        let previous = UserDefaults.standard.object(forKey: Self.connectedHintKey)
        UserDefaults.standard.set(true, forKey: Self.connectedHintKey)
        defer { restoreConnectedHint(previous) }

        let service = OpenCodeACPModelPollingService(
            client: RefreshClient(failure: OpenCodeACPLaunchResolutionError.exactPathNotFound("opencode"))
        )
        let viewModel = makeViewModel(openCodeService: service)
        defer { viewModel.prepareForWindowClose() }
        viewModel.isOpenCodeConnected = true
        viewModel.refreshDirectCLIProviderConnectionState()

        await viewModel.validateCachedContextBuilderProvidersIfNeeded()

        XCTAssertFalse(viewModel.isOpenCodeConnected)
        XCTAssertFalse(viewModel.directConnectedCLIProviders.contains(.openCode))
        XCTAssertEqual(viewModel.openCodeError, OpenCodeCLIAvailability.missingExecutableUserMessage)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: Self.connectedHintKey))
        XCTAssertFalse(viewModel.contextBuilderRestorationAvailabilityContext.openCodeAvailable)
        await service.shutdown()
    }

    func testCachedValidationKeepsConnectedHintWhenDiscoveryFailsForOtherReasons() async {
        let previous = UserDefaults.standard.object(forKey: Self.connectedHintKey)
        UserDefaults.standard.set(true, forKey: Self.connectedHintKey)
        defer { restoreConnectedHint(previous) }

        let service = OpenCodeACPModelPollingService(
            client: RefreshClient(failure: AIProviderError.invalidConfiguration(detail: "offline"))
        )
        let viewModel = makeViewModel(openCodeService: service)
        defer { viewModel.prepareForWindowClose() }
        viewModel.isOpenCodeConnected = true
        viewModel.refreshDirectCLIProviderConnectionState()

        await viewModel.validateCachedContextBuilderProvidersIfNeeded()

        XCTAssertTrue(viewModel.isOpenCodeConnected)
        XCTAssertTrue(viewModel.directConnectedCLIProviders.contains(.openCode))
        XCTAssertNil(viewModel.openCodeError)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: Self.connectedHintKey))
        XCTAssertFalse(viewModel.contextBuilderRestorationAvailabilityContext.openCodeAvailable)
        XCTAssertTrue(viewModel.agentModeAvailabilityContext.openCodeAvailable)
        await service.shutdown()
    }

    private func makeViewModel(openCodeService: OpenCodeACPModelPollingService) -> APISettingsViewModel {
        let keyManager = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        return APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false,
            openCodeModelPollingService: openCodeService
        )
    }

    private static let connectedHintKey = "OpenCodeCLIConnected"

    private func restoreConnectedHint(_ previous: Any?) {
        if let previous {
            UserDefaults.standard.set(previous, forKey: Self.connectedHintKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.connectedHintKey)
        }
    }
}
