import Foundation

// MARK: - Provider Catalog

public enum ProviderType: String, Codable, CaseIterable, Identifiable, Sendable {
    case openai = "OpenAI"
    case groq = "Groq"
    case glm = "GLM (Zhipu)"
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
}

public struct ProviderDefinition: Sendable {
    public let type: ProviderType
    public let sttEndpoint: String
    public let llmEndpoint: String
    public let sttModels: [String]
    public let llmModels: [String]
    public let sttApiFormat: ApiFormat

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
            sttApiFormat: .whisperMultipart
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
            sttApiFormat: .whisperMultipart
        ),
        .glm: ProviderDefinition(
            type: .glm,
            sttEndpoint: "https://open.bigmodel.cn/api/paas/v4/audio/transcriptions",
            llmEndpoint: "https://open.bigmodel.cn/api/paas/v4/chat/completions",
            sttModels: ["glm-asr-2512"],
            llmModels: ["glm-4-flash"],
            sttApiFormat: .whisperMultipart
        ),
        .alibaba: ProviderDefinition(
            type: .alibaba,
            sttEndpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
            llmEndpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
            sttModels: ["qwen3-asr-flash"],
            llmModels: ["qwen-turbo"],
            sttApiFormat: .chatCompletionsAudio
        ),
        .custom: ProviderDefinition(
            type: .custom,
            sttEndpoint: "",
            llmEndpoint: "",
            sttModels: [],
            llmModels: [],
            sttApiFormat: .whisperMultipart
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
