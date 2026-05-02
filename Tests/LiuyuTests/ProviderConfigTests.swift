// Tests/LiuyuTests/ProviderConfigTests.swift
import XCTest
@testable import LiuyuLib

final class ProviderConfigTests: XCTestCase {

    func testProviderConfigCodableRoundtrip() throws {
        let config = ProviderConfig(
            provider: .openai,
            baseURL: "https://custom.endpoint.com",
            sttMode: .rest
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: data)

        XCTAssertEqual(config.id, decoded.id)
        XCTAssertEqual(config.provider, decoded.provider)
        XCTAssertEqual(config.baseURL, decoded.baseURL)
        XCTAssertEqual(config.sttMode, decoded.sttMode)
    }

    func testProviderConfigDecodesLegacyPayloadWithoutSTTMode() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "provider": "GLM (Zhipu)",
          "baseURL": "https://example.com"
        }
        """

        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.provider, .glm)
        XCTAssertEqual(decoded.baseURL, "https://example.com")
        XCTAssertEqual(decoded.sttMode, .automatic)
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
        UserDefaults.standard.removeObject(forKey: "deepseekDefaultLLMMigrationDone")
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

    func testResolveGLMStreamingModeUsesRealtimeFormat() {
        cleanDefaults()
        let store = ProviderConfigStore()
        let pc = ProviderConfig(provider: .glm, sttMode: .streaming)
        store.saveProviders([pc])
        try? store.saveApiKey("glm-test", for: pc)

        let result = store.resolveSTT(ModelAssignment(providerID: pc.id, modelId: "glm-asr-2512"))

        XCTAssertEqual(result?.apiFormat, .glmRealtime)
        XCTAssertEqual(result?.model, "glm-realtime-flash")
        XCTAssertTrue(result?.endpoint.contains("/realtime") ?? false)

        try? store.deleteApiKey(for: pc)
        cleanDefaults()
    }

    func testResolveGLMStreamingModePreservesRealtimeModelSelection() {
        cleanDefaults()
        let store = ProviderConfigStore()
        let pc = ProviderConfig(provider: .glm, sttMode: .streaming)
        store.saveProviders([pc])
        try? store.saveApiKey("glm-test", for: pc)

        let result = store.resolveSTT(ModelAssignment(providerID: pc.id, modelId: "glm-realtime-air"))

        XCTAssertEqual(result?.apiFormat, .glmRealtime)
        XCTAssertEqual(result?.model, "glm-realtime-air")

        try? store.deleteApiKey(for: pc)
        cleanDefaults()
    }

    func testResolveGLMRestModeDoesNotUseRealtimeModel() {
        cleanDefaults()
        let store = ProviderConfigStore()
        let pc = ProviderConfig(provider: .glm, sttMode: .rest)
        store.saveProviders([pc])
        try? store.saveApiKey("glm-test", for: pc)

        let result = store.resolveSTT(ModelAssignment(providerID: pc.id, modelId: "glm-realtime-flash"))

        XCTAssertEqual(result?.apiFormat, .whisperMultipart)
        XCTAssertEqual(result?.model, "glm-asr-2512")

        try? store.deleteApiKey(for: pc)
        cleanDefaults()
    }

    func testResolveAlibabaStreamingModeUsesRealtimeFormatAndModel() {
        cleanDefaults()
        let store = ProviderConfigStore()
        let pc = ProviderConfig(provider: .alibaba, sttMode: .streaming)
        store.saveProviders([pc])
        try? store.saveApiKey("dashscope-test", for: pc)

        let result = store.resolveSTT(ModelAssignment(providerID: pc.id, modelId: "qwen3-asr-flash"))

        XCTAssertEqual(result?.apiFormat, .alibabaRealtime)
        XCTAssertEqual(result?.model, "fun-asr-realtime")

        try? store.deleteApiKey(for: pc)
        cleanDefaults()
    }

    func testResolveAlibabaRestModeDoesNotUseRealtimeModel() {
        cleanDefaults()
        let store = ProviderConfigStore()
        let pc = ProviderConfig(provider: .alibaba, sttMode: .rest)
        store.saveProviders([pc])
        try? store.saveApiKey("dashscope-test", for: pc)

        let result = store.resolveSTT(ModelAssignment(providerID: pc.id, modelId: "fun-asr-realtime"))

        XCTAssertEqual(result?.apiFormat, .chatCompletionsAudio)
        XCTAssertEqual(result?.model, "qwen3-asr-flash")

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

    func testEnsureDefaultLLMUsesDeepSeekWhenMissing() {
        cleanDefaults()
        let store = ProviderConfigStore()

        store.ensurePreferredDefaultLLMIfNeeded()

        let providers = store.loadProviders()
        let deepSeek = providers.first(where: { $0.provider == .deepseek })
        XCTAssertNotNil(deepSeek)

        let feature = store.loadFeatureConfig()
        XCTAssertEqual(feature.llmPrimary?.providerID, deepSeek?.id)
        XCTAssertEqual(feature.llmPrimary?.modelId, "deepseek-v4-flash")
        cleanDefaults()
    }

    func testEnsureDefaultLLMReplacesLegacyGLMFlashDefaultOnce() {
        cleanDefaults()
        let store = ProviderConfigStore()
        let glm = ProviderConfig(provider: .glm)
        store.saveProviders([glm])
        store.saveFeatureConfig(FeatureConfig(
            llmPrimary: ModelAssignment(providerID: glm.id, modelId: "glm-4-flash")
        ))

        store.ensurePreferredDefaultLLMIfNeeded()

        let providers = store.loadProviders()
        XCTAssertTrue(providers.contains { $0.provider == .glm })
        let deepSeek = providers.first(where: { $0.provider == .deepseek })
        XCTAssertNotNil(deepSeek)

        let feature = store.loadFeatureConfig()
        XCTAssertEqual(feature.llmPrimary?.providerID, deepSeek?.id)
        XCTAssertEqual(feature.llmPrimary?.modelId, "deepseek-v4-flash")

        store.saveFeatureConfig(FeatureConfig(
            llmPrimary: ModelAssignment(providerID: glm.id, modelId: "glm-4-flash")
        ))
        store.ensurePreferredDefaultLLMIfNeeded()
        XCTAssertEqual(store.loadFeatureConfig().llmPrimary?.providerID, glm.id)
        cleanDefaults()
    }
}
