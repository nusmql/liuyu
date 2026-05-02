import Foundation

// MARK: - Provider Catalog

public enum ProviderType: String, Codable, CaseIterable, Identifiable, Sendable {
    case openai = "OpenAI"
    case groq = "Groq"
    case glm = "GLM (Zhipu)"
    case deepseek = "DeepSeek"
    case alibaba = "Alibaba (Qwen)"
    case custom = "Custom"

    public var id: String { rawValue }
}

/// How the provider expects audio transcription requests.
public enum ApiFormat: String, Codable, Sendable {
    /// OpenAI Whisper-style: multipart/form-data with file, model, language fields.
    case whisperMultipart
    /// Chat completions with base64 audio content (e.g. Alibaba Qwen ASR).
    case chatCompletionsAudio
    /// Alibaba Cloud real-time speech recognition (WebSocket streaming)
    case alibabaRealtime
    /// Tencent Cloud real-time speech recognition (WebSocket streaming)
    case tencentRealtime
}

public struct ProviderDefinition: Sendable {
    public let type: ProviderType
    public let sttEndpoint: String
    public let llmEndpoint: String
    public let sttModels: [String]
    public let llmModels: [String]
    public let sttApiFormat: ApiFormat
    public let apiKeyURL: String?

    // Backward-compat computed properties
    public var endpoint: String { sttEndpoint }
    public var models: [String] { sttModels }
    public var apiFormat: ApiFormat { sttApiFormat }

    public static let catalog: [ProviderType: ProviderDefinition] = [
        .openai: ProviderDefinition(
            type: .openai,
            sttEndpoint: "https://api.openai.com/v1/audio/transcriptions",
            llmEndpoint: "https://api.openai.com/v1/chat/completions",
            sttModels: ["whisper-1"],
            llmModels: ["gpt-4o-mini", "gpt-4o"],
            sttApiFormat: .whisperMultipart,
            apiKeyURL: "https://platform.openai.com/api-keys"
        ),
        .groq: ProviderDefinition(
            type: .groq,
            sttEndpoint: "https://api.groq.com/openai/v1/audio/transcriptions",
            llmEndpoint: "https://api.groq.com/openai/v1/chat/completions",
            sttModels: [
                "whisper-large-v3",
                "whisper-large-v3-turbo",
                "distil-whisper-large-v3-en"
            ],
            llmModels: ["llama-3.3-70b-versatile"],
            sttApiFormat: .whisperMultipart,
            apiKeyURL: "https://console.groq.com/keys"
        ),
        .glm: ProviderDefinition(
            type: .glm,
            sttEndpoint: "https://open.bigmodel.cn/api/paas/v4/audio/transcriptions",
            llmEndpoint: "https://open.bigmodel.cn/api/paas/v4/chat/completions",
            sttModels: ["glm-asr-2512"],
            llmModels: ["glm-4-flash"],
            sttApiFormat: .whisperMultipart,
            apiKeyURL: "https://open.bigmodel.cn/usercenter/apikeys"
        ),
        .deepseek: ProviderDefinition(
            type: .deepseek,
            sttEndpoint: "",
            llmEndpoint: "https://api.deepseek.com/chat/completions",
            sttModels: [],
            llmModels: ["deepseek-v4-flash", "deepseek-v4-pro"],
            sttApiFormat: .whisperMultipart,
            apiKeyURL: "https://platform.deepseek.com/api_keys"
        ),
        .alibaba: ProviderDefinition(
            type: .alibaba,
            sttEndpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
            llmEndpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
            sttModels: [
                "qwen3-asr-flash",                   // REST API
                "fun-asr-realtime",                  // WebSocket Real-time (DashScope)
                "fun-asr-realtime-2025-11-07",       // WebSocket Real-time (Latest)
            ],
            llmModels: ["qwen-turbo"],
            sttApiFormat: .chatCompletionsAudio,
            apiKeyURL: "https://dashscope.console.aliyun.com/apiKey"
        ),
        .custom: ProviderDefinition(
            type: .custom,
            sttEndpoint: "",
            llmEndpoint: "",
            sttModels: [],
            llmModels: [],
            sttApiFormat: .whisperMultipart,
            apiKeyURL: nil
        )
    ]
}

// MARK: - User Configuration

public struct ModelConfig: Codable, Identifiable, Equatable {
    public var id: UUID
    public var provider: ProviderType
    public var modelId: String
    public var endpoint: String
    public var apiFormat: ApiFormat
    public var isActive: Bool

    public var keychainKey: String {
        "model-config-\(id.uuidString)"
    }

    public init(
        id: UUID = UUID(),
        provider: ProviderType,
        modelId: String,
        endpoint: String,
        apiFormat: ApiFormat = .whisperMultipart,
        isActive: Bool = false
    ) {
        self.id = id
        self.provider = provider
        self.modelId = modelId
        self.endpoint = endpoint
        self.apiFormat = apiFormat
        self.isActive = isActive
    }
}

// MARK: - Storage

public final class ModelConfigStore: Sendable {
    private static let storageKey = "modelConfigs"
    private let keychain = KeychainHelper()

    public init() {}

    public func loadConfigs() -> [ModelConfig] {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let configs = try? JSONDecoder().decode([ModelConfig].self, from: data) else {
            return []
        }
        return configs
    }

    public func saveConfigs(_ configs: [ModelConfig]) {
        if let data = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    public func activeConfig() -> ModelConfig? {
        loadConfigs().first(where: { $0.isActive })
    }

    public func apiKey(for config: ModelConfig) -> String? {
        try? keychain.read(key: config.keychainKey)
    }

    public func saveApiKey(_ key: String, for config: ModelConfig) throws {
        try keychain.save(key: config.keychainKey, value: key)
    }

    public func deleteApiKey(for config: ModelConfig) throws {
        try keychain.delete(key: config.keychainKey)
    }

    /// Migrate from old single-key settings to new multi-config format.
    public func migrateIfNeeded() {
        guard loadConfigs().isEmpty else { return }

        guard let existingKey = try? keychain.read(key: "openai-api-key"),
              !existingKey.isEmpty else {
            return
        }

        let endpoint = UserDefaults.standard.string(forKey: "endpoint")
            ?? "https://api.openai.com/v1/audio/transcriptions"

        let provider: ProviderType
        let modelId: String
        if endpoint.contains("groq.com") {
            provider = .groq
            modelId = "whisper-large-v3"
        } else if endpoint.contains("openai.com") {
            provider = .openai
            modelId = "whisper-1"
        } else if endpoint.contains("bigmodel.cn") {
            provider = .glm
            modelId = "glm-asr-2512"
        } else if endpoint.contains("aliyuncs.com") {
            provider = .alibaba
            modelId = "qwen3-asr-flash"
        } else {
            provider = .custom
            modelId = "whisper-1"
        }

        let apiFormat = ProviderDefinition.catalog[provider]?.apiFormat ?? .whisperMultipart

        let config = ModelConfig(
            provider: provider,
            modelId: modelId,
            endpoint: endpoint,
            apiFormat: apiFormat,
            isActive: true
        )

        saveConfigs([config])
        try? keychain.save(key: config.keychainKey, value: existingKey)
    }
}

// MARK: - New Provider-Level Storage

public final class ProviderConfigStore: Sendable {
    private static let providersKey = "providerConfigs"
    private static let featureKey = "featureConfig"
    private static let migrationDoneKey = "providerMigrationDone"
    private static let deepSeekDefaultLLMMigrationDoneKey = "deepseekDefaultLLMMigrationDone"
    private let keychain = KeychainHelper()

    public init() {}

    // MARK: - Providers

    public func loadProviders() -> [ProviderConfig] {
        guard let data = UserDefaults.standard.data(forKey: Self.providersKey),
              let configs = try? JSONDecoder().decode([ProviderConfig].self, from: data) else {
            return []
        }
        return configs
    }

    public func saveProviders(_ configs: [ProviderConfig]) {
        if let data = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(data, forKey: Self.providersKey)
        }
    }

    public func apiKey(for provider: ProviderConfig) -> String? {
        try? keychain.read(key: provider.keychainKey)
    }

    public func saveApiKey(_ key: String, for provider: ProviderConfig) throws {
        try keychain.save(key: provider.keychainKey, value: key)
    }

    public func deleteApiKey(for provider: ProviderConfig) throws {
        try keychain.delete(key: provider.keychainKey)
    }

    // MARK: - Feature Config

    public func loadFeatureConfig() -> FeatureConfig {
        guard let data = UserDefaults.standard.data(forKey: Self.featureKey),
              let config = try? JSONDecoder().decode(FeatureConfig.self, from: data) else {
            return FeatureConfig()
        }
        return config
    }

    public func saveFeatureConfig(_ config: FeatureConfig) {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.featureKey)
        }
    }

    // MARK: - Resolution

    public func provider(for assignment: ModelAssignment) -> ProviderConfig? {
        loadProviders().first(where: { $0.id == assignment.providerID })
    }

    /// Resolve STT params: (apiKey, endpoint, modelId, apiFormat).
    public func resolveSTT(_ assignment: ModelAssignment) -> (apiKey: String, endpoint: String, model: String, apiFormat: ApiFormat)? {
        guard let pc = provider(for: assignment) else {
            let providers = loadProviders()
            Logger.error("STT resolve failed: provider \(assignment.providerID) not found. Available: \(providers.map { "\($0.provider.rawValue)=\($0.id)" })", category: .settings)
            return nil
        }
        guard let key = apiKey(for: pc), !key.isEmpty else {
            Logger.error("STT resolve failed: no API key for \(pc.provider.rawValue). Re-enter key in Settings.", category: .settings)
            return nil
        }
        let def = ProviderDefinition.catalog[pc.provider]
        let endpoint = pc.baseURL ?? def?.sttEndpoint ?? ""
        // Determine apiFormat based on model
        let format: ApiFormat
        if assignment.modelId.hasPrefix("fun-asr-realtime") {
            format = .alibabaRealtime // WebSocket streaming
        } else {
            format = def?.sttApiFormat ?? .whisperMultipart
        }
        return (key, endpoint, assignment.modelId, format)
    }

    /// Resolve LLM params: (apiKey, endpoint, modelId).
    public func resolveLLM(_ assignment: ModelAssignment) -> (apiKey: String, endpoint: String, model: String)? {
        guard let pc = provider(for: assignment) else {
            let providers = loadProviders()
            Logger.error("LLM resolve failed: provider \(assignment.providerID) not found. Available: \(providers.map { "\($0.provider.rawValue)=\($0.id)" })", category: .settings)
            return nil
        }
        guard let key = apiKey(for: pc), !key.isEmpty else {
            Logger.error("LLM resolve failed: no API key for \(pc.provider.rawValue). Re-enter key in Settings.", category: .settings)
            return nil
        }
        let def = ProviderDefinition.catalog[pc.provider]
        let endpoint = pc.baseURL ?? def?.llmEndpoint ?? ""
        return (key, endpoint, assignment.modelId)
    }

    // MARK: - Migration

    public func migrateIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.migrationDoneKey) else { return }

        let oldStore = ModelConfigStore()
        let oldConfigs = oldStore.loadConfigs()
        guard !oldConfigs.isEmpty else {
            UserDefaults.standard.set(true, forKey: Self.migrationDoneKey)
            return
        }

        var providerMap: [ProviderType: ProviderConfig] = [:]
        var providers: [ProviderConfig] = []

        for old in oldConfigs {
            if providerMap[old.provider] == nil {
                let pc = ProviderConfig(provider: old.provider)
                providerMap[old.provider] = pc
                providers.append(pc)

                if let key = oldStore.apiKey(for: old), !key.isEmpty {
                    try? saveApiKey(key, for: pc)
                }
            }
        }

        saveProviders(providers)

        if let active = oldConfigs.first(where: { $0.isActive }),
           let pc = providerMap[active.provider] {
            let feature = FeatureConfig(
                sttPrimary: ModelAssignment(providerID: pc.id, modelId: active.modelId)
            )
            saveFeatureConfig(feature)
        }

        UserDefaults.standard.set(true, forKey: Self.migrationDoneKey)
    }

    func ensurePreferredDefaultLLMIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.deepSeekDefaultLLMMigrationDoneKey) else { return }

        var providers = loadProviders()
        var feature = loadFeatureConfig()

        let shouldUseDeepSeek: Bool
        if let llmPrimary = feature.llmPrimary {
            let provider = providers.first(where: { $0.id == llmPrimary.providerID })
            shouldUseDeepSeek = provider?.provider == .glm && llmPrimary.modelId == "glm-4-flash"
        } else {
            shouldUseDeepSeek = true
        }

        guard shouldUseDeepSeek else {
            UserDefaults.standard.set(true, forKey: Self.deepSeekDefaultLLMMigrationDoneKey)
            return
        }

        let deepSeekProvider: ProviderConfig
        if let existing = providers.first(where: { $0.provider == .deepseek }) {
            deepSeekProvider = existing
        } else {
            let provider = ProviderConfig(provider: .deepseek)
            providers.append(provider)
            saveProviders(providers)
            deepSeekProvider = provider
        }

        feature.llmPrimary = ModelAssignment(
            providerID: deepSeekProvider.id,
            modelId: "deepseek-v4-flash"
        )
        saveFeatureConfig(feature)

        UserDefaults.standard.set(true, forKey: Self.deepSeekDefaultLLMMigrationDoneKey)
    }
}

// MARK: - New Provider-Level Configuration

public struct ProviderConfig: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var provider: ProviderType
    public var baseURL: String?  // optional override of catalog default

    public var keychainKey: String { "provider-\(id.uuidString)" }

    public init(id: UUID = UUID(), provider: ProviderType, baseURL: String? = nil) {
        self.id = id
        self.provider = provider
        self.baseURL = baseURL
    }
}

public struct ModelAssignment: Codable, Equatable, Sendable {
    public var providerID: UUID
    public var modelId: String

    public init(providerID: UUID, modelId: String) {
        self.providerID = providerID
        self.modelId = modelId
    }
}

public struct FeatureConfig: Codable, Equatable, Sendable {
    public var sttPrimary: ModelAssignment?
    public var sttFallback: ModelAssignment?
    public var llmPrimary: ModelAssignment?
    public var llmFallback: ModelAssignment?

    public init(
        sttPrimary: ModelAssignment? = nil,
        sttFallback: ModelAssignment? = nil,
        llmPrimary: ModelAssignment? = nil,
        llmFallback: ModelAssignment? = nil
    ) {
        self.sttPrimary = sttPrimary
        self.sttFallback = sttFallback
        self.llmPrimary = llmPrimary
        self.llmFallback = llmFallback
    }
}
