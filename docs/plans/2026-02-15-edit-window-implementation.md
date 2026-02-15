# Edit Window & Provider Settings Redesign Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a mouse-driven Edit window with voice-to-text and LLM-powered voice-to-edit, backed by a redesigned provider/model settings architecture.

**Architecture:** Replace the flat `ModelConfig` list with a two-level provider + feature-assignment system. Add `LLMService` for chat completions. Build a standalone `EditView` with inline mic button and waveform. The Edit window is fully independent from the existing hotkey/floating-panel flow.

**Tech Stack:** Swift 6.0, SwiftUI, AppKit, URLSession, existing KeychainHelper, LucideIcons

---

## Task 1: New Data Models

**Files:**
- Modify: `Sources/LiuyuLib/Settings/ModelConfig.swift`
- Create: `Tests/LiuyuTests/ProviderConfigTests.swift`

**Step 1: Add new data types to ModelConfig.swift**

Add the following types at the end of `ModelConfig.swift` (keep all existing types — they're needed for migration):

```swift
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
```

**Step 2: Write tests for new types**

```swift
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
}
```

**Step 3: Run tests**

Run: `swift test --filter ProviderConfigTests 2>&1`
Expected: All 4 tests PASS

**Step 4: Verify full build**

Run: `swift build 2>&1`
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add Sources/LiuyuLib/Settings/ModelConfig.swift Tests/LiuyuTests/ProviderConfigTests.swift
git commit -m "feat: add ProviderConfig, ModelAssignment, and FeatureConfig data models"
```

---

## Task 2: Update ProviderDefinition Catalog

**Files:**
- Modify: `Sources/LiuyuLib/Settings/ModelConfig.swift`
- Modify: `Tests/LiuyuTests/ModelConfigTests.swift`

**Step 1: Replace ProviderDefinition with expanded version**

In `ModelConfig.swift`, replace the existing `ProviderDefinition` struct and its `catalog`:

```swift
public struct ProviderDefinition: Sendable {
    public let type: ProviderType
    public let sttEndpoint: String
    public let llmEndpoint: String
    public let sttModels: [String]
    public let llmModels: [String]
    public let sttApiFormat: ApiFormat

    /// Old single endpoint accessor for backward compatibility during migration.
    public var endpoint: String { sttEndpoint }
    /// Old single models accessor for backward compatibility during migration.
    public var models: [String] { sttModels }
    /// Old single apiFormat accessor for backward compatibility during migration.
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
```

**Step 2: Update tests in ModelConfigTests.swift**

Replace the provider catalog tests with updated ones:

Replace `testOpenAIProvider` with:
```swift
    func testOpenAIProvider() {
        let def = ProviderDefinition.catalog[.openai]!
        XCTAssertEqual(def.sttEndpoint, "https://api.openai.com/v1/audio/transcriptions")
        XCTAssertEqual(def.llmEndpoint, "https://api.openai.com/v1/chat/completions")
        XCTAssertTrue(def.sttModels.contains("whisper-1"))
        XCTAssertTrue(def.llmModels.contains("gpt-4o-mini"))
        XCTAssertEqual(def.sttApiFormat, .whisperMultipart)
    }
```

Replace `testGLMProvider` with:
```swift
    func testGLMProvider() {
        let def = ProviderDefinition.catalog[.glm]!
        XCTAssertTrue(def.sttEndpoint.contains("bigmodel.cn"))
        XCTAssertTrue(def.sttModels.contains("glm-asr-2512"))
        XCTAssertTrue(def.llmModels.contains("glm-4-flash"))
        XCTAssertEqual(def.sttApiFormat, .whisperMultipart)
    }
```

Replace `testAlibabaProvider` with:
```swift
    func testAlibabaProvider() {
        let def = ProviderDefinition.catalog[.alibaba]!
        XCTAssertTrue(def.sttEndpoint.contains("dashscope"))
        XCTAssertTrue(def.sttModels.contains("qwen3-asr-flash"))
        XCTAssertTrue(def.llmModels.contains("qwen-turbo"))
        XCTAssertEqual(def.sttApiFormat, .chatCompletionsAudio)
    }
```

**Step 3: Run tests**

Run: `swift test --filter ModelConfigTests 2>&1`
Expected: All tests PASS (backward-compat properties keep existing code working)

**Step 4: Verify full build**

Run: `swift build 2>&1`
Expected: BUILD SUCCEEDED (existing code uses `.endpoint`, `.models`, `.apiFormat` which still work via backward-compat accessors)

**Step 5: Commit**

```bash
git add Sources/LiuyuLib/Settings/ModelConfig.swift Tests/LiuyuTests/ModelConfigTests.swift
git commit -m "feat: expand ProviderDefinition catalog with LLM endpoints and models"
```

---

## Task 3: ProviderConfigStore & Migration

**Files:**
- Modify: `Sources/LiuyuLib/Settings/ModelConfig.swift`
- Modify: `Tests/LiuyuTests/ProviderConfigTests.swift`

**Step 1: Add ProviderConfigStore to ModelConfig.swift**

Add below the existing `ModelConfigStore` class:

```swift
// MARK: - New Provider-Level Storage

public final class ProviderConfigStore: Sendable {
    private static let providersKey = "providerConfigs"
    private static let featureKey = "featureConfig"
    private static let migrationDoneKey = "providerMigrationDone"
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

    // MARK: - Resolution Helpers

    /// Resolve a model assignment to the API parameters needed for a request.
    public func resolveSTT(_ assignment: ModelAssignment) -> (apiKey: String, endpoint: String, model: String, apiFormat: ApiFormat)? {
        let providers = loadProviders()
        guard let provider = providers.first(where: { $0.id == assignment.providerID }),
              let apiKey = apiKey(for: provider), !apiKey.isEmpty else {
            return nil
        }
        let def = ProviderDefinition.catalog[provider.provider]
        let endpoint = provider.baseURL.map { base in
            // Use base URL + STT path suffix from catalog
            let sttPath = def?.sttEndpoint.replacingOccurrences(
                of: "https://[^/]+".asRegexPattern, with: "", options: .regularExpression
            ) ?? ""
            return base + sttPath
        } ?? def?.sttEndpoint ?? ""
        let apiFormat = def?.sttApiFormat ?? .whisperMultipart
        return (apiKey, endpoint, assignment.modelId, apiFormat)
    }

    /// Resolve a model assignment to LLM API parameters.
    public func resolveLLM(_ assignment: ModelAssignment) -> (apiKey: String, endpoint: String, model: String)? {
        let providers = loadProviders()
        guard let provider = providers.first(where: { $0.id == assignment.providerID }),
              let apiKey = apiKey(for: provider), !apiKey.isEmpty else {
            return nil
        }
        let def = ProviderDefinition.catalog[provider.provider]
        let endpoint = provider.baseURL.map { base in
            let llmPath = def?.llmEndpoint.replacingOccurrences(
                of: "https://[^/]+".asRegexPattern, with: "", options: .regularExpression
            ) ?? ""
            return base + llmPath
        } ?? def?.llmEndpoint ?? ""
        return (apiKey, endpoint, assignment.modelId)
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

        // Group old configs by provider, create one ProviderConfig per provider
        var providerMap: [ProviderType: ProviderConfig] = [:]
        var providers: [ProviderConfig] = []

        for old in oldConfigs {
            if providerMap[old.provider] == nil {
                let pc = ProviderConfig(provider: old.provider)
                providerMap[old.provider] = pc
                providers.append(pc)

                // Copy API key from old config to new provider
                if let key = oldStore.apiKey(for: old), !key.isEmpty {
                    try? saveApiKey(key, for: pc)
                }
            }
        }

        saveProviders(providers)

        // Set up feature config: use the old active config as STT primary
        if let active = oldConfigs.first(where: { $0.isActive }),
           let pc = providerMap[active.provider] {
            let feature = FeatureConfig(
                sttPrimary: ModelAssignment(providerID: pc.id, modelId: active.modelId)
            )
            saveFeatureConfig(feature)
        }

        UserDefaults.standard.set(true, forKey: Self.migrationDoneKey)
    }
}

private extension String {
    var asRegexPattern: String { self }
}
```

Actually, the URL resolution with regex is too complex. Let me simplify — just use the catalog endpoint directly, with base URL override replacing the entire endpoint:

Replace the `resolveSTT` and `resolveLLM` methods with simpler versions. Let me revise this.

**Step 1 (revised): Add ProviderConfigStore to ModelConfig.swift**

Add below the existing `ModelConfigStore` class:

```swift
// MARK: - New Provider-Level Storage

public final class ProviderConfigStore: Sendable {
    private static let providersKey = "providerConfigs"
    private static let featureKey = "featureConfig"
    private static let migrationDoneKey = "providerMigrationDone"
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

    /// Find the ProviderConfig for a given assignment.
    public func provider(for assignment: ModelAssignment) -> ProviderConfig? {
        loadProviders().first(where: { $0.id == assignment.providerID })
    }

    /// Resolve STT params: (apiKey, endpoint, modelId, apiFormat).
    public func resolveSTT(_ assignment: ModelAssignment) -> (apiKey: String, endpoint: String, model: String, apiFormat: ApiFormat)? {
        guard let pc = provider(for: assignment),
              let key = apiKey(for: pc), !key.isEmpty else { return nil }
        let def = ProviderDefinition.catalog[pc.provider]
        let endpoint = pc.baseURL ?? def?.sttEndpoint ?? ""
        let format = def?.sttApiFormat ?? .whisperMultipart
        return (key, endpoint, assignment.modelId, format)
    }

    /// Resolve LLM params: (apiKey, endpoint, modelId).
    public func resolveLLM(_ assignment: ModelAssignment) -> (apiKey: String, endpoint: String, model: String)? {
        guard let pc = provider(for: assignment),
              let key = apiKey(for: pc), !key.isEmpty else { return nil }
        let def = ProviderDefinition.catalog[pc.provider]
        let endpoint = pc.baseURL ?? def?.llmEndpoint ?? ""
        return (key, endpoint, assignment.modelId)
    }

    // MARK: - Migration

    /// Migrate from old ModelConfig list to new ProviderConfig + FeatureConfig.
    public func migrateIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.migrationDoneKey) else { return }

        let oldStore = ModelConfigStore()
        let oldConfigs = oldStore.loadConfigs()
        guard !oldConfigs.isEmpty else {
            UserDefaults.standard.set(true, forKey: Self.migrationDoneKey)
            return
        }

        // Group old configs by provider type → one ProviderConfig per unique provider
        var providerMap: [ProviderType: ProviderConfig] = [:]
        var providers: [ProviderConfig] = []

        for old in oldConfigs {
            if providerMap[old.provider] == nil {
                let pc = ProviderConfig(provider: old.provider)
                providerMap[old.provider] = pc
                providers.append(pc)

                // Copy API key from old config to new provider
                if let key = oldStore.apiKey(for: old), !key.isEmpty {
                    try? saveApiKey(key, for: pc)
                }
            }
        }

        saveProviders(providers)

        // Use old active config as STT primary
        if let active = oldConfigs.first(where: { $0.isActive }),
           let pc = providerMap[active.provider] {
            let feature = FeatureConfig(
                sttPrimary: ModelAssignment(providerID: pc.id, modelId: active.modelId)
            )
            saveFeatureConfig(feature)
        }

        UserDefaults.standard.set(true, forKey: Self.migrationDoneKey)
    }
}
```

**Step 2: Add tests to ProviderConfigTests.swift**

Append these tests:

```swift
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
        // No API key saved

        let assignment = ModelAssignment(providerID: pc.id, modelId: "whisper-1")
        XCTAssertNil(store.resolveSTT(assignment))
        cleanDefaults()
    }

    func testMigration() {
        cleanDefaults()
        UserDefaults.standard.removeObject(forKey: "modelConfigs")

        // Set up old-style configs
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

        // Run migration
        let newStore = ProviderConfigStore()
        newStore.migrateIfNeeded()

        // Verify providers
        let providers = newStore.loadProviders()
        XCTAssertEqual(providers.count, 1)
        XCTAssertEqual(providers[0].provider, .groq)

        // Verify API key migrated
        let key = newStore.apiKey(for: providers[0])
        XCTAssertEqual(key, "gsk-test-key")

        // Verify feature config
        let feature = newStore.loadFeatureConfig()
        XCTAssertNotNil(feature.sttPrimary)
        XCTAssertEqual(feature.sttPrimary?.modelId, "whisper-large-v3")
        XCTAssertEqual(feature.sttPrimary?.providerID, providers[0].id)
        XCTAssertNil(feature.llmPrimary)

        // Clean up
        try? newStore.deleteApiKey(for: providers[0])
        try? oldStore.deleteApiKey(for: oldConfig)
        UserDefaults.standard.removeObject(forKey: "modelConfigs")
        cleanDefaults()
    }
```

**Step 3: Run tests**

Run: `swift test --filter ProviderConfigTests 2>&1`
Expected: All tests PASS

**Step 4: Verify full build**

Run: `swift build 2>&1`
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add Sources/LiuyuLib/Settings/ModelConfig.swift Tests/LiuyuTests/ProviderConfigTests.swift
git commit -m "feat: add ProviderConfigStore with storage, resolution helpers, and migration"
```

---

## Task 4: LLMService

**Files:**
- Create: `Sources/LiuyuLib/LLM/LLMService.swift`
- Create: `Tests/LiuyuTests/LLMServiceTests.swift`

**Step 1: Write failing tests**

```swift
// Tests/LiuyuTests/LLMServiceTests.swift
import XCTest
import Foundation
@testable import LiuyuLib

// Reuse MockURLProtocol from TranscriptionServiceTests — if not accessible,
// define it here. Check if it's already in scope; if not, copy the class.

final class LLMServiceTests: XCTestCase {

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testSuccessfulChat() async throws {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            let json = """
            {"choices":[{"message":{"content":"Edited text here."}}]}
            """
            return (response, json.data(using: .utf8)!)
        }

        let service = LLMService(
            apiKey: "sk-test",
            endpoint: "https://api.openai.com/v1/chat/completions",
            model: "gpt-4o-mini",
            session: makeSession()
        )

        let result = try await service.chat(system: "You are helpful.", user: "Fix this text.")
        XCTAssertEqual(result, "Edited text here.")
    }

    func testInvalidApiKey() async throws {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401,
                httpVersion: nil, headerFields: nil
            )!
            return (response, #"{"error":{"message":"Invalid key"}}"#.data(using: .utf8)!)
        }

        let service = LLMService(
            apiKey: "sk-bad",
            endpoint: "https://api.openai.com/v1/chat/completions",
            model: "gpt-4o-mini",
            session: makeSession()
        )

        do {
            _ = try await service.chat(system: "test", user: "test")
            XCTFail("Expected error")
        } catch let error as LLMError {
            if case .apiKeyInvalid = error {} else {
                XCTFail("Expected apiKeyInvalid, got \(error)")
            }
        }
    }

    func testRequestFormat() async throws {
        var capturedRequest: URLRequest?

        MockURLProtocol.handler = { request in
            capturedRequest = request
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, #"{"choices":[{"message":{"content":"ok"}}]}"#.data(using: .utf8)!)
        }

        let service = LLMService(
            apiKey: "sk-verify",
            endpoint: "https://api.openai.com/v1/chat/completions",
            model: "gpt-4o-mini",
            session: makeSession()
        )

        _ = try await service.chat(system: "sys", user: "usr")

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-verify")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gpt-4o-mini")
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"], "system")
        XCTAssertEqual(messages[0]["content"], "sys")
        XCTAssertEqual(messages[1]["role"], "user")
        XCTAssertEqual(messages[1]["content"], "usr")
    }

    func testEmptyResponse() async throws {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, #"{"choices":[{"message":{"content":""}}]}"#.data(using: .utf8)!)
        }

        let service = LLMService(
            apiKey: "sk-test",
            endpoint: "https://api.openai.com/v1/chat/completions",
            model: "gpt-4o-mini",
            session: makeSession()
        )

        do {
            _ = try await service.chat(system: "test", user: "test")
            XCTFail("Expected error")
        } catch let error as LLMError {
            if case .emptyResponse = error {} else {
                XCTFail("Expected emptyResponse, got \(error)")
            }
        }
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter LLMServiceTests 2>&1`
Expected: FAIL — `LLMService` not found

**Step 3: Check if MockURLProtocol is accessible**

Read `Tests/LiuyuTests/TranscriptionServiceTests.swift` to see if `MockURLProtocol` is defined there. If so, it should be accessible within the same test target. If the tests fail because `MockURLProtocol` is not found, create a shared `Tests/LiuyuTests/MockURLProtocol.swift` file and move the class there.

**Step 4: Implement LLMService**

```swift
// Sources/LiuyuLib/LLM/LLMService.swift
import Foundation

public enum LLMError: Error, LocalizedError, Sendable {
    case apiKeyInvalid
    case rateLimited
    case serverError(Int, String)
    case networkError(String)
    case decodingFailed
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .apiKeyInvalid: return "Invalid API key. Check Settings."
        case .rateLimited: return "Rate limited. Try again in a moment."
        case .serverError(let code, let msg): return "API error (\(code)): \(msg)"
        case .networkError(let msg): return "Network error: \(msg)"
        case .decodingFailed: return "Failed to decode API response."
        case .emptyResponse: return "LLM returned an empty response."
        }
    }
}

public final class LLMService: Sendable {
    public let apiKey: String
    public let endpoint: String
    public let model: String
    private let session: URLSession

    public init(
        apiKey: String,
        endpoint: String,
        model: String,
        session: URLSession? = nil
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.model = model
        self.session = session ?? {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            return URLSession(configuration: config)
        }()
    }

    public func chat(system: String, user: String, retryCount: Int = 0) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]

        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if retryCount < 1 {
                return try await chat(system: system, user: user, retryCount: retryCount + 1)
            }
            throw LLMError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.decodingFailed
        }

        switch httpResponse.statusCode {
        case 200:
            return try parseResponse(data)
        case 401:
            throw LLMError.apiKeyInvalid
        case 429:
            if retryCount < 1 {
                try await Task.sleep(for: .seconds(2))
                return try await chat(system: system, user: user, retryCount: retryCount + 1)
            }
            throw LLMError.rateLimited
        default:
            let message = parseErrorMessage(data) ?? "Unknown error"
            throw LLMError.serverError(httpResponse.statusCode, message)
        }
    }

    private func parseResponse(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.decodingFailed
        }
        if content.isEmpty {
            throw LLMError.emptyResponse
        }
        return content
    }

    private func parseErrorMessage(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return nil
        }
        return message
    }
}
```

**Step 5: Run tests**

Run: `swift test --filter LLMServiceTests 2>&1`
Expected: All 4 tests PASS. If `MockURLProtocol` not found, move it to a shared file first.

**Step 6: Commit**

```bash
git add Sources/LiuyuLib/LLM/LLMService.swift Tests/LiuyuTests/LLMServiceTests.swift
git commit -m "feat: add LLMService for OpenAI-compatible chat completions with tests"
```

---

## Task 5: Update AppDelegate to Use New ProviderConfigStore

**Files:**
- Modify: `Sources/LiuyuLib/App/AppDelegate.swift`

This task replaces the old `ModelConfigStore` usage with `ProviderConfigStore` in the existing hotkey → transcription flow.

**Step 1: Update AppDelegate**

In `AppDelegate.swift`, make these changes:

1. Replace the `configStore` property:

Change:
```swift
    private let configStore = ModelConfigStore()
```
To:
```swift
    private let providerStore = ProviderConfigStore()
```

2. Update `applicationDidFinishLaunching`:

Change:
```swift
        configStore.migrateIfNeeded()
```
To:
```swift
        providerStore.migrateIfNeeded()
```

Change:
```swift
        if configStore.activeConfig() == nil {
```
To:
```swift
        if providerStore.loadFeatureConfig().sttPrimary == nil {
```

3. Replace the `transcribe` method:

```swift
    private func transcribe(audioURL: URL) async {
        let feature = providerStore.loadFeatureConfig()

        guard let sttAssignment = feature.sttPrimary else {
            panelController.viewModel.showResult("No STT model configured. Open Settings.")
            panelController.resize(width: 400, height: 120)
            settingsController.show()
            return
        }

        // Try primary, then fallback
        if let text = await tryTranscribe(assignment: sttAssignment, audioURL: audioURL) {
            panelController.viewModel.showResult(text)
            panelController.resize(width: 400, height: 120)
            return
        }

        if let fallback = feature.sttFallback,
           let text = await tryTranscribe(assignment: fallback, audioURL: audioURL) {
            panelController.viewModel.showResult(text)
            panelController.resize(width: 400, height: 120)
            return
        }

        panelController.viewModel.showResult("Transcription failed. Check Settings.")
        panelController.resize(width: 400, height: 120)
    }

    private func tryTranscribe(assignment: ModelAssignment, audioURL: URL) async -> String? {
        guard let params = providerStore.resolveSTT(assignment) else { return nil }

        let language = UserDefaults.standard.string(forKey: "language") ?? "auto"
        let service = TranscriptionService(
            apiKey: params.apiKey,
            endpoint: params.endpoint,
            model: params.model,
            language: language == "auto" ? nil : language,
            apiFormat: params.apiFormat
        )

        return try? await service.transcribe(audioFileURL: audioURL)
    }
```

**Step 2: Verify it compiles**

Run: `swift build 2>&1`
Expected: BUILD SUCCEEDED

**Step 3: Run all tests**

Run: `swift test 2>&1`
Expected: All tests PASS

**Step 4: Commit**

```bash
git add Sources/LiuyuLib/App/AppDelegate.swift
git commit -m "refactor: switch AppDelegate to ProviderConfigStore for STT resolution"
```

---

## Task 6: Settings — Providers View

**Files:**
- Modify: `Sources/LiuyuLib/Settings/ModelsSettingsView.swift` (rename content to providers)

Repurpose `ModelsSettingsView.swift` into a provider management view. We keep the filename but replace all content.

**Step 1: Rewrite ModelsSettingsView as ProvidersSettingsView**

Replace the entire contents of `Sources/LiuyuLib/Settings/ModelsSettingsView.swift`:

```swift
// Sources/LiuyuLib/Settings/ModelsSettingsView.swift
import SwiftUI

struct ProvidersSettingsView: View {
    @State private var providers: [ProviderConfig] = []
    @State private var selectedProviderID: UUID?
    @State private var editingApiKey: String = ""
    @State private var hasExistingKey: Bool = false
    @State private var saveMessage: String?

    private let store = ProviderConfigStore()

    var body: some View {
        Form {
            providersSection
            detailsSection
            saveSection
        }
        .formStyle(.grouped)
        .onAppear { loadAll() }
    }

    // MARK: - Providers List

    private var providersSection: some View {
        Section("Providers") {
            if providers.isEmpty {
                Text("No providers configured. Add one below.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.provider.rawValue)
                                .fontWeight(.medium)
                            if let url = provider.baseURL {
                                Text(url)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { selectProvider(provider) }

                        Spacer()

                        if store.apiKey(for: provider) != nil {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }

                        Button(role: .destructive) {
                            deleteProvider(at: index)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                }
            }

            Button("Add Provider") {
                addNewProvider()
            }
        }
    }

    // MARK: - Details

    @ViewBuilder
    private var detailsSection: some View {
        if let selectedId = selectedProviderID,
           let index = providers.firstIndex(where: { $0.id == selectedId }) {
            Section("Provider Details") {
                Picker("Provider", selection: $providers[index].provider) {
                    ForEach(ProviderType.allCases) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }

                SecureField("API Key", text: $editingApiKey,
                            prompt: Text(hasExistingKey ? "Key saved \u{2713}" : "Enter API key"))

                TextField("Custom Base URL (optional)", text: Binding(
                    get: { providers[index].baseURL ?? "" },
                    set: { providers[index].baseURL = $0.isEmpty ? nil : $0 }
                ))
                .font(.system(.body, design: .monospaced))

                if providers[index].baseURL == nil {
                    let def = ProviderDefinition.catalog[providers[index].provider]
                    if let stt = def?.sttEndpoint, !stt.isEmpty {
                        Text("Default STT: \(stt)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let llm = def?.llmEndpoint, !llm.isEmpty {
                        Text("Default LLM: \(llm)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Save

    private var saveSection: some View {
        HStack {
            Spacer()
            if let saveMessage {
                Text(saveMessage)
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Button("Save") {
                saveAll()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Actions

    private func loadAll() {
        providers = store.loadProviders()
        if let first = providers.first {
            selectProvider(first)
        }
    }

    private func selectProvider(_ provider: ProviderConfig) {
        selectedProviderID = provider.id
        editingApiKey = ""
        hasExistingKey = store.apiKey(for: provider) != nil
    }

    private func addNewProvider() {
        let provider = ProviderConfig(provider: .openai)
        providers.append(provider)
        selectProvider(provider)
    }

    private func deleteProvider(at index: Int) {
        let provider = providers[index]
        try? store.deleteApiKey(for: provider)
        providers.remove(at: index)

        if selectedProviderID == provider.id {
            selectedProviderID = providers.first?.id
            if let first = providers.first {
                selectProvider(first)
            }
        }
    }

    private func saveAll() {
        if let selectedId = selectedProviderID,
           let provider = providers.first(where: { $0.id == selectedId }),
           !editingApiKey.isEmpty {
            try? store.saveApiKey(editingApiKey, for: provider)
            hasExistingKey = true
            editingApiKey = ""
        }

        store.saveProviders(providers)

        saveMessage = "Saved"
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            saveMessage = nil
        }
    }
}
```

**Step 2: Verify it compiles**

Run: `swift build 2>&1`
Expected: BUILD SUCCEEDED (SettingsView still references `ModelsSettingsView()` — we need to update that in Task 8)

Actually, since we renamed the struct to `ProvidersSettingsView`, the build will fail because `SettingsView.swift` still references `ModelsSettingsView()`. We need to handle this. Two options: keep the struct name as `ModelsSettingsView` for now (confusing) or update the reference immediately. Let's update the reference immediately.

**Step 2 (revised): Also update SettingsView.swift**

In `SettingsView.swift`, change the detail branch for `.models`:

Change:
```swift
                case .models:
                    ModelsSettingsView()
```
To:
```swift
                case .models:
                    ProvidersSettingsView()
```

Also update the `SettingsSection` enum — rename `.models` to `.providers`:

Change:
```swift
    case models = "Models"
```
To:
```swift
    case providers = "Providers"
```

And update the icon:
```swift
        case .providers: return "server.rack"
```

And the detail branch:
```swift
                case .providers:
                    ProvidersSettingsView()
```

**Step 3: Verify it compiles**

Run: `swift build 2>&1`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add Sources/LiuyuLib/Settings/ModelsSettingsView.swift Sources/LiuyuLib/Settings/SettingsView.swift
git commit -m "feat: replace Models settings with Providers settings (provider-level API keys)"
```

---

## Task 7: Settings — Feature Model Assignment View

**Files:**
- Create: `Sources/LiuyuLib/Settings/FeatureModelsSettingsView.swift`
- Modify: `Sources/LiuyuLib/Settings/SettingsView.swift`

**Step 1: Create FeatureModelsSettingsView**

```swift
// Sources/LiuyuLib/Settings/FeatureModelsSettingsView.swift
import SwiftUI

struct FeatureModelsSettingsView: View {
    @State private var featureConfig = FeatureConfig()
    @State private var providers: [ProviderConfig] = []
    @State private var saveMessage: String?

    private let store = ProviderConfigStore()

    var body: some View {
        Form {
            Section("Speech-to-Text") {
                modelPicker(
                    label: "Primary",
                    selection: $featureConfig.sttPrimary,
                    modelType: .stt
                )
                modelPicker(
                    label: "Fallback",
                    selection: $featureConfig.sttFallback,
                    modelType: .stt
                )
            }

            Section("LLM (Voice Edit)") {
                modelPicker(
                    label: "Primary",
                    selection: $featureConfig.llmPrimary,
                    modelType: .llm
                )
                modelPicker(
                    label: "Fallback",
                    selection: $featureConfig.llmFallback,
                    modelType: .llm
                )
            }

            HStack {
                Spacer()
                if let saveMessage {
                    Text(saveMessage)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Button("Save") {
                    save()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .onAppear { load() }
    }

    private enum ModelType {
        case stt, llm
    }

    @ViewBuilder
    private func modelPicker(label: String, selection: Binding<ModelAssignment?>, modelType: ModelType) -> some View {
        let options = buildOptions(for: modelType)

        if options.isEmpty {
            LabeledContent(label, value: "No providers configured")
                .foregroundStyle(.secondary)
        } else {
            Picker(label, selection: Binding(
                get: { selection.wrappedValue.map { optionKey($0) } ?? "none" },
                set: { newValue in
                    if newValue == "none" {
                        selection.wrappedValue = nil
                    } else {
                        selection.wrappedValue = parseOptionKey(newValue)
                    }
                }
            )) {
                Text("None").tag("none")
                ForEach(options, id: \.key) { option in
                    Text(option.label).tag(option.key)
                }
            }
        }
    }

    private struct PickerOption {
        let key: String     // "providerID|modelId"
        let label: String   // "OpenAI / whisper-1"
    }

    private func buildOptions(for type: ModelType) -> [PickerOption] {
        var options: [PickerOption] = []
        for provider in providers {
            let def = ProviderDefinition.catalog[provider.provider]
            let models: [String]
            switch type {
            case .stt: models = def?.sttModels ?? []
            case .llm: models = def?.llmModels ?? []
            }
            for model in models {
                let key = "\(provider.id.uuidString)|\(model)"
                let label = "\(provider.provider.rawValue) / \(model)"
                options.append(PickerOption(key: key, label: label))
            }
            // For custom provider, allow free-form — show one entry
            if provider.provider == .custom && models.isEmpty {
                let key = "\(provider.id.uuidString)|custom"
                let label = "\(provider.provider.rawValue) / (custom)"
                options.append(PickerOption(key: key, label: label))
            }
        }
        return options
    }

    private func optionKey(_ assignment: ModelAssignment) -> String {
        "\(assignment.providerID.uuidString)|\(assignment.modelId)"
    }

    private func parseOptionKey(_ key: String) -> ModelAssignment? {
        let parts = key.split(separator: "|", maxSplits: 1)
        guard parts.count == 2,
              let uuid = UUID(uuidString: String(parts[0])) else { return nil }
        return ModelAssignment(providerID: uuid, modelId: String(parts[1]))
    }

    private func load() {
        providers = store.loadProviders()
        featureConfig = store.loadFeatureConfig()
    }

    private func save() {
        store.saveFeatureConfig(featureConfig)
        saveMessage = "Saved"
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            saveMessage = nil
        }
    }
}
```

**Step 2: Add "Models" section back to SettingsView sidebar**

In `SettingsView.swift`, add a `.models` case back to the enum (after `.providers`):

Update the `SettingsSection` enum to:
```swift
enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case providers = "Providers"
    case models = "Models"
    case transcription = "Transcription"
    case hotkey = "Hotkey"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gear"
        case .providers: return "server.rack"
        case .models: return "cpu"
        case .transcription: return "text.bubble"
        case .hotkey: return "keyboard"
        case .about: return "info.circle"
        }
    }
}
```

And add the detail branch:
```swift
                case .models:
                    FeatureModelsSettingsView()
```

**Step 3: Verify it compiles**

Run: `swift build 2>&1`
Expected: BUILD SUCCEEDED

**Step 4: Run all tests**

Run: `swift test 2>&1`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add Sources/LiuyuLib/Settings/FeatureModelsSettingsView.swift Sources/LiuyuLib/Settings/SettingsView.swift
git commit -m "feat: add feature model assignment settings (STT/LLM primary + fallback)"
```

---

## Task 8: EditViewModel

**Files:**
- Create: `Sources/LiuyuLib/Edit/EditViewModel.swift`

**Step 1: Implement EditViewModel**

```swift
// Sources/LiuyuLib/Edit/EditViewModel.swift
import Foundation
import Combine
import AppKit

enum EditState: Equatable {
    case idle
    case recording(audioLevel: Float)
    case transcribing
    case editing  // LLM processing
}

@MainActor
class EditViewModel: ObservableObject {
    @Published var text: String = ""
    @Published var editState: EditState = .idle
    @Published var errorMessage: String?

    private let recordingController = RecordingController()
    private let providerStore = ProviderConfigStore()
    private var cancellables = Set<AnyCancellable>()
    private var recordingStartTime: Date?
    private var currentAudioURL: URL?

    private let minimumRecordingDuration: TimeInterval = 0.3

    var hasText: Bool { !text.isEmpty }

    /// Label for the mic button based on current state.
    var micButtonLabel: String {
        hasText ? "Hold to Edit" : "Hold to Record"
    }

    /// Audio level for waveform (0.0–1.0).
    var audioLevel: Float {
        if case .recording(let level) = editState { return level }
        return 0
    }

    init() {
        recordingController.$audioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                guard let self, case .recording = self.editState else { return }
                self.editState = .recording(audioLevel: level)
            }
            .store(in: &cancellables)
    }

    // MARK: - Recording

    func startRecording() {
        errorMessage = nil
        do {
            try recordingController.start()
            recordingStartTime = Date()
            editState = .recording(audioLevel: 0)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopRecording() {
        let elapsed = Date().timeIntervalSince(recordingStartTime ?? Date())

        if elapsed < minimumRecordingDuration {
            let remaining = minimumRecordingDuration - elapsed
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                self?.finishRecording()
            }
        } else {
            finishRecording()
        }
    }

    private func finishRecording() {
        guard let audioURL = recordingController.stop() else {
            errorMessage = "No audio recorded."
            editState = .idle
            return
        }
        currentAudioURL = audioURL

        if hasText {
            editState = .editing
        } else {
            editState = .transcribing
        }

        Task {
            await processAudio(audioURL: audioURL)
        }
    }

    // MARK: - Processing

    private func processAudio(audioURL: URL) async {
        let feature = providerStore.loadFeatureConfig()

        // Step 1: Transcribe the voice
        guard let transcribedText = await transcribe(audioURL: audioURL, feature: feature) else {
            editState = .idle
            return
        }

        // Step 2: If there's existing text, send to LLM for editing
        if hasText {
            await editWithLLM(instruction: transcribedText, feature: feature)
        } else {
            text = transcribedText
            editState = .idle
        }

        cleanupAudio()
    }

    private func transcribe(audioURL: URL, feature: FeatureConfig) async -> String? {
        guard let stt = feature.sttPrimary else {
            errorMessage = "No STT model configured. Open Settings."
            return nil
        }

        if let result = await tryTranscribe(assignment: stt, audioURL: audioURL) {
            return result
        }

        if let fallback = feature.sttFallback,
           let result = await tryTranscribe(assignment: fallback, audioURL: audioURL) {
            return result
        }

        errorMessage = "Transcription failed. Check Settings."
        return nil
    }

    private func tryTranscribe(assignment: ModelAssignment, audioURL: URL) async -> String? {
        guard let params = providerStore.resolveSTT(assignment) else { return nil }
        let language = UserDefaults.standard.string(forKey: "language") ?? "auto"
        let service = TranscriptionService(
            apiKey: params.apiKey,
            endpoint: params.endpoint,
            model: params.model,
            language: language == "auto" ? nil : language,
            apiFormat: params.apiFormat
        )
        return try? await service.transcribe(audioFileURL: audioURL)
    }

    private func editWithLLM(instruction: String, feature: FeatureConfig) async {
        guard let llm = feature.llmPrimary else {
            // No LLM configured — fall back to appending
            text += (text.isEmpty ? "" : " ") + instruction
            editState = .idle
            errorMessage = "No LLM model configured. Text appended instead."
            return
        }

        if let result = await tryLLMEdit(assignment: llm, instruction: instruction) {
            text = result
            editState = .idle
            return
        }

        if let fallback = feature.llmFallback,
           let result = await tryLLMEdit(assignment: fallback, instruction: instruction) {
            text = result
            editState = .idle
            return
        }

        // All failed — append the instruction as text
        text += (text.isEmpty ? "" : " ") + instruction
        editState = .idle
        errorMessage = "LLM edit failed. Text appended instead."
    }

    private func tryLLMEdit(assignment: ModelAssignment, instruction: String) async -> String? {
        guard let params = providerStore.resolveLLM(assignment) else { return nil }

        let systemPrompt = """
        You are a text editor assistant. The user will give you existing text and a voice instruction.
        Apply the instruction to the text and return ONLY the edited text. Do not add explanations.
        If the instruction is unclear, make your best interpretation and apply it.
        """

        let userMessage = """
        Text:
        \(text)

        Instruction:
        \(instruction)
        """

        let service = LLMService(
            apiKey: params.apiKey,
            endpoint: params.endpoint,
            model: params.model
        )
        return try? await service.chat(system: systemPrompt, user: userMessage)
    }

    // MARK: - Actions

    func clear() {
        text = ""
        errorMessage = nil
        editState = .idle
        cleanupAudio()
    }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func insert(previousApp: NSRunningApplication?) {
        copy()
        previousApp?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            Self.simulatePaste()
        }
    }

    private static func simulatePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    // MARK: - Cleanup

    private func cleanupAudio() {
        if let url = currentAudioURL {
            RecordingController.deleteRecording(at: url)
            currentAudioURL = nil
        }
    }
}
```

**Step 2: Verify it compiles**

Run: `swift build 2>&1`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/LiuyuLib/Edit/EditViewModel.swift
git commit -m "feat: add EditViewModel with record, transcribe, and LLM edit orchestration"
```

---

## Task 9: EditView

**Files:**
- Create: `Sources/LiuyuLib/Edit/EditView.swift`

**Step 1: Implement EditView**

```swift
// Sources/LiuyuLib/Edit/EditView.swift
import SwiftUI
import LucideIcons

struct EditView: View {
    @StateObject private var viewModel = EditViewModel()
    @State private var waveformLevels: [Float] = Array(repeating: 0, count: 7)

    let previousApp: NSRunningApplication?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Content area
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Action bar
            actionBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        ScrollView {
            VStack(spacing: 16) {
                if viewModel.hasText {
                    // Editable text area
                    TextEditor(text: $viewModel.text)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .frame(maxWidth: .infinity, minHeight: 100)
                }

                // Mic button / waveform / processing indicator
                micArea
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private var micArea: some View {
        switch viewModel.editState {
        case .idle:
            micButton

        case .recording:
            waveformView
                .onChange(of: viewModel.audioLevel) { newLevel in
                    waveformLevels.removeFirst()
                    waveformLevels.append(newLevel)
                }

        case .transcribing:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Transcribing...")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)

        case .editing:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Editing...")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }

        // Error message
        if let error = viewModel.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .center)
                .onAppear {
                    Task {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        viewModel.errorMessage = nil
                    }
                }
        }
    }

    private var micButton: some View {
        Image(nsImage: Lucide.mic)
            .resizable()
            .frame(width: 24, height: 24)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .contentShape(Rectangle())
            .overlay {
                Text(viewModel.micButtonLabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .offset(y: 28)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if viewModel.editState == .idle {
                            viewModel.startRecording()
                        }
                    }
                    .onEnded { _ in
                        if case .recording = viewModel.editState {
                            viewModel.stopRecording()
                        }
                    }
            )
    }

    private var waveformView: some View {
        HStack(spacing: 3) {
            ForEach(0..<7, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.red.opacity(0.7))
                    .frame(width: 4, height: CGFloat(8 + waveformLevels[index] * 32))
                    .animation(.easeInOut(duration: 0.08), value: waveformLevels[index])
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 8) {
            Spacer()

            Button(action: { viewModel.clear() }) {
                Label {
                    Text("Clear")
                } icon: {
                    Image(nsImage: Lucide.trash2)
                        .resizable()
                        .frame(width: 12, height: 12)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.hasText)

            Button(action: { viewModel.copy() }) {
                Label {
                    Text("Copy")
                } icon: {
                    Image(nsImage: Lucide.clipboardCopy)
                        .resizable()
                        .frame(width: 12, height: 12)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.hasText)

            Button(action: {
                viewModel.insert(previousApp: previousApp)
                onClose()
            }) {
                Label {
                    Text("Insert")
                } icon: {
                    Image(nsImage: Lucide.cornerDownLeft)
                        .resizable()
                        .frame(width: 12, height: 12)
                }
                .font(.system(size: 12))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!viewModel.hasText)
        }
    }
}
```

**Step 2: Verify it compiles**

Run: `swift build 2>&1`
Expected: BUILD SUCCEEDED. If Lucide icon names cause errors, check the actual property names in the `LucideIcons` package and adjust.

**Step 3: Commit**

```bash
git add Sources/LiuyuLib/Edit/EditView.swift
git commit -m "feat: add EditView with inline mic button, waveform, text editor, and action bar"
```

---

## Task 10: EditWindowController + Menu Item Wiring

**Files:**
- Create: `Sources/LiuyuLib/Edit/EditWindowController.swift`
- Modify: `Sources/LiuyuLib/App/AppDelegate.swift`

**Step 1: Implement EditWindowController**

```swift
// Sources/LiuyuLib/Edit/EditWindowController.swift
import AppKit
import SwiftUI

@MainActor
class EditWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var previousApp: NSRunningApplication?

    func show() {
        // Save the previously focused app before showing our window
        previousApp = NSWorkspace.shared.frontmostApplication

        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Liuyu Edit"
        window.minSize = NSSize(width: 400, height: 300)
        window.center()
        window.contentView = NSHostingView(
            rootView: EditView(
                previousApp: previousApp,
                onClose: { [weak self] in self?.close() }
            )
        )
        window.isReleasedWhenClosed = false
        window.delegate = self

        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        false
    }
}
```

**Step 2: Add Edit menu item to AppDelegate**

In `AppDelegate.swift`:

1. Add the controller property:

After `private let settingsController = SettingsWindowController()`, add:
```swift
    private let editController = EditWindowController()
```

2. Add the menu item in `setupStatusItem()`:

Change the menu setup from:
```swift
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Liuyu", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = menu
```
To:
```swift
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Edit...", action: #selector(openEdit), keyEquivalent: "e"))
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Liuyu", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = menu
```

3. Add the action method:

After `@objc private func openSettings()`, add:
```swift
    @objc private func openEdit() {
        editController.show()
    }
```

**Step 3: Verify it compiles**

Run: `swift build 2>&1`
Expected: BUILD SUCCEEDED

**Step 4: Run all tests**

Run: `swift test 2>&1`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add Sources/LiuyuLib/Edit/EditWindowController.swift Sources/LiuyuLib/App/AppDelegate.swift
git commit -m "feat: add EditWindowController and wire Edit menu item into AppDelegate"
```

---

## Task 11: Integration Test & Polish

**Files:**
- Various (fixes found during testing)

**Step 1: Build the app bundle**

Run: `bash scripts/bundle.sh 2>&1`
Expected: "App bundle created at build/Liuyu.app"

**Step 2: Manual integration test**

Run: `open build/Liuyu.app`

Test checklist:
1. Menu bar shows "Edit..." item
2. Clicking "Edit..." opens the Edit window
3. Empty state shows centered mic icon + "Hold to Record" label
4. Mouse press-and-hold on mic: waveform bars animate
5. Release: "Transcribing..." spinner, then text appears in editor
6. With text present, mic label changes to "Hold to Edit"
7. Hold mic again with text: records, then "Editing..." spinner, then LLM edits text
8. Clear button empties text area, returns to centered mic
9. Copy button copies text to clipboard
10. Insert button pastes into previously focused app, closes window
11. Settings → Providers section works (add provider, set API key)
12. Settings → Models section works (set STT primary/fallback, LLM primary/fallback)
13. Existing hotkey flow still works (Right Option hold → record → transcribe → insert)

**Step 3: Fix any issues found during testing**

Common things to check:
- Lucide icon property names (verify against actual package API)
- Swift 6 concurrency warnings or errors
- `DragGesture` may need tweaking if press detection isn't reliable
- Window activation policy juggling between Edit and Settings windows

**Step 4: Final build verification**

Run: `swift build 2>&1 && swift test 2>&1`
Expected: BUILD SUCCEEDED, all tests PASS

**Step 5: Commit any fixes**

```bash
git add -A
git commit -m "fix: integration polish for edit window and provider settings"
```

---

## Summary

| Task | What | Verification |
|------|------|-------------|
| 1 | New data models (ProviderConfig, FeatureConfig, ModelAssignment) | 4 unit tests |
| 2 | Update ProviderDefinition catalog (LLM endpoints/models) | Updated unit tests |
| 3 | ProviderConfigStore + migration | 6 unit tests |
| 4 | LLMService (chat completions client) | 4 unit tests |
| 5 | Update AppDelegate to use ProviderConfigStore | Compiles + existing tests pass |
| 6 | Providers settings view (replaces Models) | Compiles |
| 7 | Feature model assignment settings view | Compiles + all tests pass |
| 8 | EditViewModel (recording + transcription + LLM orchestration) | Compiles |
| 9 | EditView (SwiftUI with mic button, waveform, text editor) | Compiles |
| 10 | EditWindowController + menu item wiring | Compiles + all tests pass |
| 11 | Integration test + polish | Manual E2E + bundle builds |
