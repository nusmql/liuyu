import XCTest
@testable import LiuyuLib

final class ModelConfigTests: XCTestCase {

    // MARK: - ModelConfig Codable

    func testModelConfigRoundtrip() throws {
        let config = ModelConfig(
            provider: .groq,
            modelId: "whisper-large-v3",
            endpoint: "https://api.groq.com/openai/v1/audio/transcriptions",
            apiFormat: .whisperMultipart,
            isActive: true
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ModelConfig.self, from: data)

        XCTAssertEqual(config.id, decoded.id)
        XCTAssertEqual(config.provider, decoded.provider)
        XCTAssertEqual(config.modelId, decoded.modelId)
        XCTAssertEqual(config.endpoint, decoded.endpoint)
        XCTAssertEqual(config.apiFormat, decoded.apiFormat)
        XCTAssertEqual(config.isActive, decoded.isActive)
    }

    func testModelConfigKeychainKey() {
        let config = ModelConfig(
            provider: .openai,
            modelId: "whisper-1",
            endpoint: "https://api.openai.com/v1/audio/transcriptions"
        )
        XCTAssertTrue(config.keychainKey.hasPrefix("model-config-"))
        XCTAssertTrue(config.keychainKey.contains(config.id.uuidString))
    }

    // MARK: - ModelConfigStore

    func testSaveAndLoadConfigs() {
        let store = ModelConfigStore()
        let key = "modelConfigs"

        // Clean up first
        UserDefaults.standard.removeObject(forKey: key)

        let configs = [
            ModelConfig(provider: .openai, modelId: "whisper-1",
                        endpoint: "https://api.openai.com/v1/audio/transcriptions", isActive: true),
            ModelConfig(provider: .glm, modelId: "glm-asr-2512",
                        endpoint: "https://open.bigmodel.cn/api/paas/v4/audio/transcriptions")
        ]

        store.saveConfigs(configs)
        let loaded = store.loadConfigs()

        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].provider, .openai)
        XCTAssertEqual(loaded[1].provider, .glm)

        // Clean up
        UserDefaults.standard.removeObject(forKey: key)
    }

    func testActiveConfig() {
        let store = ModelConfigStore()
        let key = "modelConfigs"
        UserDefaults.standard.removeObject(forKey: key)

        let configs = [
            ModelConfig(provider: .openai, modelId: "whisper-1",
                        endpoint: "https://api.openai.com/v1/audio/transcriptions", isActive: false),
            ModelConfig(provider: .groq, modelId: "whisper-large-v3",
                        endpoint: "https://api.groq.com/openai/v1/audio/transcriptions", isActive: true)
        ]

        store.saveConfigs(configs)

        let active = store.activeConfig()
        XCTAssertNotNil(active)
        XCTAssertEqual(active?.provider, .groq)

        UserDefaults.standard.removeObject(forKey: key)
    }

    func testActiveConfigReturnsNilWhenEmpty() {
        let store = ModelConfigStore()
        UserDefaults.standard.removeObject(forKey: "modelConfigs")

        XCTAssertNil(store.activeConfig())
    }

    // MARK: - Provider Catalog

    func testCatalogHasExpectedProviders() {
        XCTAssertNotNil(ProviderDefinition.catalog[.openai])
        XCTAssertNotNil(ProviderDefinition.catalog[.groq])
        XCTAssertNotNil(ProviderDefinition.catalog[.glm])
        XCTAssertNotNil(ProviderDefinition.catalog[.deepseek])
        XCTAssertNotNil(ProviderDefinition.catalog[.alibaba])
        XCTAssertNotNil(ProviderDefinition.catalog[.custom])
    }

    func testOpenAIProvider() {
        let def = ProviderDefinition.catalog[.openai]!
        XCTAssertEqual(def.sttEndpoint, "https://api.openai.com/v1/audio/transcriptions")
        XCTAssertEqual(def.llmEndpoint, "https://api.openai.com/v1/chat/completions")
        XCTAssertTrue(def.sttModels.contains("whisper-1"))
        XCTAssertTrue(def.llmModels.contains("gpt-4o-mini"))
        XCTAssertEqual(def.sttApiFormat, .whisperMultipart)
    }

    func testGLMProvider() {
        let def = ProviderDefinition.catalog[.glm]!
        XCTAssertTrue(def.sttEndpoint.contains("bigmodel.cn"))
        XCTAssertTrue(def.sttModels.contains("glm-asr-2512"))
        XCTAssertTrue(def.llmModels.contains("glm-4-flash"))
        XCTAssertEqual(def.sttApiFormat, .whisperMultipart)
    }

    func testDeepSeekProvider() {
        let def = ProviderDefinition.catalog[.deepseek]!
        XCTAssertEqual(def.llmEndpoint, "https://api.deepseek.com/chat/completions")
        XCTAssertTrue(def.sttModels.isEmpty)
        XCTAssertTrue(def.llmModels.contains("deepseek-v4-flash"))
        XCTAssertTrue(def.llmModels.contains("deepseek-v4-pro"))
    }

    func testAlibabaProvider() {
        let def = ProviderDefinition.catalog[.alibaba]!
        XCTAssertTrue(def.sttEndpoint.contains("dashscope"))
        XCTAssertTrue(def.sttModels.contains("qwen3-asr-flash"))
        XCTAssertTrue(def.llmModels.contains("qwen-turbo"))
        XCTAssertEqual(def.sttApiFormat, .chatCompletionsAudio)
    }

}
