// Tests/LiuyuTests/ProviderConfigTests.swift
import XCTest
@testable import LiuyuLib

final class ProviderConfigTests: XCTestCase {

    func testProviderConfigCodableRoundtrip() throws {
        let config = ProviderConfig(provider: .openai, baseURL: "https://custom.endpoint.com")
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: data)

        XCTAssertEqual(config.id, decoded.id)
        XCTAssertEqual(config.provider, decoded.provider)
        XCTAssertEqual(config.baseURL, decoded.baseURL)
    }

    func testProviderConfigKeychainKey() {
        let config = ProviderConfig(provider: .groq)
        XCTAssertTrue(config.keychainKey.hasPrefix("provider-"))
        XCTAssertTrue(config.keychainKey.contains(config.id.uuidString))
    }

    func testModelAssignmentCodableRoundtrip() throws {
        let providerID = UUID()
        let assignment = ModelAssignment(providerID: providerID, modelId: "whisper-1")
        let data = try JSONEncoder().encode(assignment)
        let decoded = try JSONDecoder().decode(ModelAssignment.self, from: data)

        XCTAssertEqual(assignment.providerID, decoded.providerID)
        XCTAssertEqual(assignment.modelId, decoded.modelId)
    }

    func testFeatureConfigCodableRoundtrip() throws {
        let pid = UUID()
        let config = FeatureConfig(
            sttPrimary: ModelAssignment(providerID: pid, modelId: "whisper-1"),
            llmPrimary: ModelAssignment(providerID: pid, modelId: "gpt-4o-mini")
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(FeatureConfig.self, from: data)

        XCTAssertEqual(decoded.sttPrimary?.modelId, "whisper-1")
        XCTAssertEqual(decoded.llmPrimary?.modelId, "gpt-4o-mini")
        XCTAssertNil(decoded.sttFallback)
        XCTAssertNil(decoded.llmFallback)
    }

    // MARK: - ProviderConfigStore

    private func cleanDefaults() {
        UserDefaults.standard.removeObject(forKey: "providerConfigs")
        UserDefaults.standard.removeObject(forKey: "featureConfig")
        UserDefaults.standard.removeObject(forKey: "providerMigrationDone")
    }

    func testSaveAndLoadProviders() {
        cleanDefaults()
        let store = ProviderConfigStore()
        let providers = [
            ProviderConfig(provider: .openai),
            ProviderConfig(provider: .groq)
        ]
        store.saveProviders(providers)
        let loaded = store.loadProviders()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].provider, .openai)
        XCTAssertEqual(loaded[1].provider, .groq)
        cleanDefaults()
    }

    func testSaveAndLoadFeatureConfig() {
        cleanDefaults()
        let store = ProviderConfigStore()
        let pid = UUID()
        let feature = FeatureConfig(
            sttPrimary: ModelAssignment(providerID: pid, modelId: "whisper-1"),
            llmPrimary: ModelAssignment(providerID: pid, modelId: "gpt-4o-mini")
        )
        store.saveFeatureConfig(feature)
        let loaded = store.loadFeatureConfig()
        XCTAssertEqual(loaded.sttPrimary?.modelId, "whisper-1")
        XCTAssertEqual(loaded.llmPrimary?.modelId, "gpt-4o-mini")
        XCTAssertNil(loaded.sttFallback)
        cleanDefaults()
    }

    func testResolveSTT() {
        cleanDefaults()
        let store = ProviderConfigStore()
        let pc = ProviderConfig(provider: .openai)
        store.saveProviders([pc])
        try? store.saveApiKey("sk-test", for: pc)

        let assignment = ModelAssignment(providerID: pc.id, modelId: "whisper-1")
        let result = store.resolveSTT(assignment)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.apiKey, "sk-test")
        XCTAssertEqual(result?.model, "whisper-1")
        XCTAssertTrue(result?.endpoint.contains("transcriptions") ?? false)
        XCTAssertEqual(result?.apiFormat, .whisperMultipart)

        try? store.deleteApiKey(for: pc)
        cleanDefaults()
    }

    func testResolveLLM() {
        cleanDefaults()
        let store = ProviderConfigStore()
        let pc = ProviderConfig(provider: .openai)
        store.saveProviders([pc])
        try? store.saveApiKey("sk-test", for: pc)

        let assignment = ModelAssignment(providerID: pc.id, modelId: "gpt-4o-mini")
        let result = store.resolveLLM(assignment)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.apiKey, "sk-test")
        XCTAssertEqual(result?.model, "gpt-4o-mini")
        XCTAssertTrue(result?.endpoint.contains("chat/completions") ?? false)

        try? store.deleteApiKey(for: pc)
        cleanDefaults()
    }

    func testResolveReturnsNilWithoutApiKey() {
        cleanDefaults()
        let store = ProviderConfigStore()
        let pc = ProviderConfig(provider: .openai)
        store.saveProviders([pc])

        let assignment = ModelAssignment(providerID: pc.id, modelId: "whisper-1")
        XCTAssertNil(store.resolveSTT(assignment))
        cleanDefaults()
    }

    func testMigration() {
        cleanDefaults()
        UserDefaults.standard.removeObject(forKey: "modelConfigs")

        let oldStore = ModelConfigStore()
        let oldConfig = ModelConfig(
            provider: .groq,
            modelId: "whisper-large-v3",
            endpoint: "https://api.groq.com/openai/v1/audio/transcriptions",
            apiFormat: .whisperMultipart,
            isActive: true
        )
        oldStore.saveConfigs([oldConfig])
        try? oldStore.saveApiKey("gsk-test-key", for: oldConfig)

        let newStore = ProviderConfigStore()
        newStore.migrateIfNeeded()

        let providers = newStore.loadProviders()
        XCTAssertEqual(providers.count, 1)
        XCTAssertEqual(providers[0].provider, .groq)

        let key = newStore.apiKey(for: providers[0])
        XCTAssertEqual(key, "gsk-test-key")

        let feature = newStore.loadFeatureConfig()
        XCTAssertNotNil(feature.sttPrimary)
        XCTAssertEqual(feature.sttPrimary?.modelId, "whisper-large-v3")
        XCTAssertEqual(feature.sttPrimary?.providerID, providers[0].id)
        XCTAssertNil(feature.llmPrimary)

        try? newStore.deleteApiKey(for: providers[0])
        try? oldStore.deleteApiKey(for: oldConfig)
        UserDefaults.standard.removeObject(forKey: "modelConfigs")
        cleanDefaults()
    }
}
