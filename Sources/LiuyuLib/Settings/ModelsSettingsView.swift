// Sources/LiuyuLib/Settings/ModelsSettingsView.swift
import SwiftUI

struct ProvidersSettingsView: View {
    private enum IFlytekCredentialMode: String, CaseIterable, Identifiable {
        case hmac = "API Key"
        case oauth2 = "OAuth2"

        var id: String { rawValue }
    }

    private enum CredentialInputError: LocalizedError {
        case incompleteIFlytekHMAC
        case incompleteIFlytekOAuth2

        var errorDescription: String? {
            switch self {
            case .incompleteIFlytekHMAC:
                return "Fill APPID, APIKey, and APISecret"
            case .incompleteIFlytekOAuth2:
                return "Fill APPID and OAuth2 token"
            }
        }
    }

    @State private var providers: [ProviderConfig] = []
    @State private var selectedProviderID: UUID?
    @State private var editingApiKey: String = ""
    @State private var iflytekCredentialMode: IFlytekCredentialMode = .hmac
    @State private var iflytekAppID: String = ""
    @State private var iflytekAPIKey: String = ""
    @State private var iflytekAPISecret: String = ""
    @State private var iflytekOAuthToken: String = ""
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

                Picker("STT Mode", selection: $providers[index].sttMode) {
                    ForEach(sttModeOptions(for: providers[index].provider)) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                credentialFields(for: providers[index])

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

    @ViewBuilder
    private func credentialFields(for provider: ProviderConfig) -> some View {
        if provider.provider == .iflytek {
            Picker("Auth", selection: $iflytekCredentialMode) {
                ForEach(IFlytekCredentialMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            SecureField("APPID", text: $iflytekAppID,
                        prompt: Text(hasExistingKey ? "Saved" : "APPID"))
                .textContentType(.username)

            switch iflytekCredentialMode {
            case .hmac:
                SecureField("APIKey", text: $iflytekAPIKey,
                            prompt: Text(hasExistingKey ? "Saved" : "APIKey"))
                SecureField("APISecret", text: $iflytekAPISecret,
                            prompt: Text(hasExistingKey ? "Saved" : "APISecret"))
            case .oauth2:
                SecureField("Access Token", text: $iflytekOAuthToken,
                            prompt: Text(hasExistingKey ? "Saved" : "OAuth2 token"))
            }
        } else {
            SecureField("API Key", text: $editingApiKey,
                        prompt: Text(apiKeyPrompt(for: provider)))
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
        clearCredentialInputs()
        hasExistingKey = store.apiKey(for: provider) != nil
    }

    private func addNewProvider() {
        let provider = ProviderConfig(provider: .openai)
        providers.append(provider)
        selectProvider(provider)
    }

    private func sttModeOptions(for provider: ProviderType) -> [STTTransportMode] {
        switch provider {
        case .glm, .alibaba:
            return [.automatic, .rest, .streaming]
        case .iflytek:
            return [.automatic, .streaming]
        default:
            return [.automatic, .rest]
        }
    }

    private func apiKeyPrompt(for provider: ProviderConfig) -> String {
        if hasExistingKey {
            return "Key saved \u{2713}"
        }
        if provider.provider == .iflytek {
            return "Enter iFLYTEK credentials"
        }
        return "Enter API key"
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
           let provider = providers.first(where: { $0.id == selectedId }) {
            do {
                if let credential = try credentialValueToSave(for: provider) {
                    try store.saveApiKey(credential, for: provider)
                    hasExistingKey = true
                    clearCredentialInputs()
                    Logger.info("API Key saved successfully for \(provider.provider.rawValue)", category: .settings)
                }
            } catch {
                Logger.error("Failed to save API Key: \(error)", category: .settings)
                saveMessage = error.localizedDescription
                return
            }
        }

        store.saveProviders(providers)

        saveMessage = "Saved"
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            saveMessage = nil
        }
    }

    private func credentialValueToSave(for provider: ProviderConfig) throws -> String? {
        if provider.provider == .iflytek {
            let appID = iflytekAppID.trimmingCharacters(in: .whitespacesAndNewlines)
            let apiKey = iflytekAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let apiSecret = iflytekAPISecret.trimmingCharacters(in: .whitespacesAndNewlines)
            let oauthToken = iflytekOAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)

            switch iflytekCredentialMode {
            case .hmac:
                guard !appID.isEmpty || !apiKey.isEmpty || !apiSecret.isEmpty else { return nil }
                guard !appID.isEmpty, !apiKey.isEmpty, !apiSecret.isEmpty else {
                    throw CredentialInputError.incompleteIFlytekHMAC
                }
                return "\(appID)|\(apiKey)|\(apiSecret)"
            case .oauth2:
                guard !appID.isEmpty || !oauthToken.isEmpty else { return nil }
                guard !appID.isEmpty, !oauthToken.isEmpty else {
                    throw CredentialInputError.incompleteIFlytekOAuth2
                }
                return "oauth2|\(appID)|\(oauthToken)"
            }
        }

        let key = editingApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    private func clearCredentialInputs() {
        editingApiKey = ""
        iflytekAppID = ""
        iflytekAPIKey = ""
        iflytekAPISecret = ""
        iflytekOAuthToken = ""
    }
}
