@testable import RepoPromptApp
import XCTest

final class CustomProviderPickerModelsTests: XCTestCase {
    func testPickerModelsIncludeDefaultWhenNothingIsEnabled() throws {
        let config = try CustomProviderConfiguration(
            url: "https://example.test",
            defaultModel: "qwen38-27b-exl3-4bpw-262k",
            headers: [:],
            name: "Custom",
            enabledModels: []
        )

        XCTAssertEqual(config.pickerModels().map(\.rawValue), [
            "custom_provider_qwen38-27b-exl3-4bpw-262k"
        ])
        XCTAssertEqual(config.pickerModels().map(\.displayName), [
            "Custom/qwen38-27b-exl3-4bpw-262k"
        ])
    }

    func testPickerModelsPreferUserModelAndDeduplicateDefault() throws {
        let config = try CustomProviderConfiguration(
            url: "https://example.test",
            defaultModel: "default-model",
            headers: [:],
            name: "Custom",
            enabledModels: ["enabled-a", "enabled-b"],
            userPreferredModel: "preferred-model"
        )

        XCTAssertEqual(
            Set(config.pickerModels().map(\.rawValue)),
            Set([
                "custom_provider_enabled-a",
                "custom_provider_enabled-b",
                "custom_provider_user_preferred-model",
                "custom_provider_default-model"
            ])
        )
    }

    func testPickerModelsDoNotDuplicatePreferredWhenItIsAlsoDefault() throws {
        let config = try CustomProviderConfiguration(
            url: "https://example.test",
            defaultModel: "same-model",
            headers: [:],
            name: "Custom",
            enabledModels: [],
            userPreferredModel: "same-model"
        )

        XCTAssertEqual(config.pickerModels().map(\.rawValue), [
            "custom_provider_user_same-model"
        ])
    }

    func testValidationSeedsDefaultModelWhenNothingIsEnabled() {
        let seeded = CustomProviderConfiguration.enabledModelsAfterValidation(
            previouslyEnabled: [],
            fetchedModels: ["alpha", "beta"],
            userPreferredModel: "",
            defaultModel: "alpha"
        )
        XCTAssertEqual(seeded, ["alpha"])
    }

    func testValidationKeepsPreferredModelOutOfEnabledSet() {
        let retained = CustomProviderConfiguration.enabledModelsAfterValidation(
            previouslyEnabled: ["alpha", "preferred"],
            fetchedModels: ["alpha", "preferred", "beta"],
            userPreferredModel: "preferred",
            defaultModel: "alpha"
        )
        XCTAssertEqual(retained, ["alpha"])
    }

    func testValidationDropsStaleEnabledModelsNotInFetchedCatalog() {
        let retained = CustomProviderConfiguration.enabledModelsAfterValidation(
            previouslyEnabled: ["stale", "alpha"],
            fetchedModels: ["alpha", "beta"],
            userPreferredModel: "",
            defaultModel: "beta"
        )
        XCTAssertEqual(retained, ["alpha"])
    }
}
