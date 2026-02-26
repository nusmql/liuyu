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
            do {
                try store.saveApiKey(editingApiKey, for: provider)
                hasExistingKey = true
                editingApiKey = ""
                Logger.info("API Key saved successfully for \(provider.provider.rawValue)", category: .settings)
            } catch {
                Logger.error("Failed to save API Key: \(error)", category: .settings)
                saveMessage = "Save failed"
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
}
