import Foundation
@testable import RepoPromptApp
import XCTest

final class PiModelRegistryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PiModelRegistry.shared.clear()
    }

    override func tearDown() {
        PiModelRegistry.shared.clear()
        super.tearDown()
    }

    private func record(
        _ id: String,
        name: String = "",
        provider: String = "zai",
        reasoning: Bool = false,
        contextWindow: Int = 128_000
    ) -> PiModelRegistry.ModelRecord {
        PiModelRegistry.ModelRecord(id: id, name: name, provider: provider, reasoning: reasoning, contextWindow: contextWindow)
    }

    func testUpdateDedupesSortsAndReportsChanges() {
        XCTAssertTrue(PiModelRegistry.shared.update(records: [
            record("glm-5.3", name: "GLM 5.3", provider: "zai", contextWindow: 200_000),
            record("GLM-5.3", name: "duplicate", provider: "zai"),
            record("qwen3-235b", name: "Qwen3 235B", provider: "openrouter", contextWindow: 262_144)
        ]))
        // Same content again: no change.
        XCTAssertFalse(PiModelRegistry.shared.update(records: [
            record("qwen3-235b", name: "Qwen3 235B", provider: "openrouter", contextWindow: 262_144),
            record("glm-5.3", name: "GLM 5.3", provider: "zai", contextWindow: 200_000)
        ]))
        // Provider-major, id-minor ordering: openrouter sorts before zai.
        XCTAssertEqual(PiModelRegistry.shared.resolvedRecords().map(\.id), ["qwen3-235b", "glm-5.3"])
    }

    func testResolvedOptionsPlaceDefaultFirst() throws {
        PiModelRegistry.shared.update(records: [
            record("glm-5.3", name: "GLM 5.3", provider: "zai", reasoning: true, contextWindow: 200_000)
        ])
        let options = try XCTUnwrap(PiModelRegistry.shared.resolvedOptions())
        XCTAssertEqual(options.count, 2)
        XCTAssertTrue(options[0].isPlaceholderDefault)
        XCTAssertEqual(options[0].rawValue, AgentModel.defaultModel.rawValue)
        XCTAssertEqual(options[1].rawValue, "zai/glm-5.3")
        XCTAssertEqual(options[1].displayName, "GLM 5.3")
        XCTAssertEqual(options[1].description, "zai")
    }

    func testResolvedOptionsNilWhenEmpty() {
        XCTAssertNil(PiModelRegistry.shared.resolvedOptions())
    }

    func testContainsIsCaseInsensitiveAndContextWindowLookup() {
        PiModelRegistry.shared.update(records: [
            record("glm-5.3", contextWindow: 200_000)
        ])
        XCTAssertTrue(PiModelRegistry.shared.contains(rawModel: "GLM-5.3"))
        XCTAssertTrue(PiModelRegistry.shared.contains(rawModel: "zai/GLM-5.3"))
        XCTAssertFalse(PiModelRegistry.shared.contains(rawModel: "other"))
        XCTAssertEqual(PiModelRegistry.shared.contextWindow(forRaw: "GLM-5.3"), 200_000)
        XCTAssertNil(PiModelRegistry.shared.contextWindow(forRaw: "missing"))
    }

    func testCatalogUsesDiscoveredOptionsAndValidates() {
        PiModelRegistry.shared.update(records: [
            record("glm-5.3", name: "GLM 5.3", provider: "zai")
        ])
        let availability = AgentModelCatalog.AvailabilityContext(piAvailable: true)
        let options = AgentModelCatalog.options(for: .piAgent, availability: availability)
        XCTAssertEqual(options.count, 2)
        XCTAssertEqual(options.last?.rawValue, "zai/glm-5.3")

        XCTAssertTrue(AgentModelCatalog.isValid(rawModel: AgentModel.defaultModel.rawValue, for: .piAgent, availability: availability))
        XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "glm-5.3", for: .piAgent, availability: availability))
        XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "zai/glm-5.3", for: .piAgent, availability: availability))
        XCTAssertFalse(AgentModelCatalog.isValid(rawModel: "not-a-pi-model", for: .piAgent, availability: availability))
        // Unavailable provider blocks everything.
        XCTAssertFalse(AgentModelCatalog.isValid(rawModel: "glm-5.3", for: .piAgent, availability: .none))
    }

    func testCatalogFallsBackToDefaultOnlyWithoutDiscovery() {
        let options = AgentModelCatalog.options(
            for: .piAgent,
            availability: AgentModelCatalog.AvailabilityContext(piAvailable: true)
        )
        XCTAssertEqual(options.count, 1)
        XCTAssertTrue(options[0].isPlaceholderDefault)
    }

    func testDedupeKeepsSameIdFromDifferentProviders() {
        XCTAssertTrue(PiModelRegistry.shared.update(records: [
            record("grok", name: "Grok", provider: "local"),
            record("grok", name: "Grok", provider: "xai")
        ]))
        XCTAssertEqual(
            PiModelRegistry.shared.resolvedRecords().map(\.catalogRawValue),
            ["local/grok", "xai/grok"]
        )
        XCTAssertEqual(PiModelRegistry.shared.record(matchingRaw: "grok")?.provider, "local")
        XCTAssertEqual(PiModelRegistry.shared.record(matchingRaw: "local/grok")?.provider, "local")
    }

    func testModelAcceptsImagesUsesInputTypes() {
        XCTAssertTrue(PiModelRegistry.shared.modelAcceptsImages(rawModel: AgentModel.defaultModel.rawValue))
        PiModelRegistry.shared.update(records: [
            PiModelRegistry.ModelRecord(
                id: "text-only",
                name: "Text",
                provider: "zai",
                reasoning: false,
                contextWindow: 128_000,
                inputTypes: ["text"]
            ),
            PiModelRegistry.ModelRecord(
                id: "vision",
                name: "Vision",
                provider: "zai",
                reasoning: false,
                contextWindow: 128_000,
                inputTypes: ["text", "image"]
            )
        ])
        XCTAssertFalse(PiModelRegistry.shared.modelAcceptsImages(rawModel: "text-only"))
        XCTAssertTrue(PiModelRegistry.shared.modelAcceptsImages(rawModel: "vision"))
        XCTAssertTrue(PiModelRegistry.shared.modelAcceptsImages(rawModel: "unknown-model"))
    }
}
