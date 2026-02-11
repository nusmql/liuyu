import SwiftUI

struct SettingsView: View {
    @State private var configs: [ModelConfig] = []
    @State private var selectedConfigId: UUID?
    @State private var editingApiKey: String = ""
    @State private var hasExistingKey: Bool = false
    @AppStorage("language") private var language = "auto"
    @AppStorage("hotkeyPreset") private var hotkeyPreset = HotkeyPreset.rightOption.rawValue
    @State private var saveMessage: String?

    private let store = ModelConfigStore()

    var body: some View {
        Form {
            modelsSection
            detailsSection
            transcriptionSection
            hotkeySection
            saveSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 500)
        .onAppear { loadAll() }
    }

    // MARK: - Models List

    private var modelsSection: some View {
        Section("Models") {
            if configs.isEmpty {
                Text("No models configured. Add one below.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(configs.enumerated()), id: \.element.id) { index, config in
                    HStack {
                        // Radio button for active selection
                        Image(systemName: config.isActive ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(config.isActive ? .blue : .secondary)
                            .onTapGesture { setActive(index) }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(config.provider.rawValue)
                                .fontWeight(.medium)
                            Text(config.modelId)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { selectConfig(config) }

                        Spacer()

                        Button(role: .destructive) {
                            deleteConfig(at: index)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                }
            }

            Button("Add Model") {
                addNewConfig()
            }
        }
    }

    // MARK: - Selected Model Details

    @ViewBuilder
    private var detailsSection: some View {
        if let selectedId = selectedConfigId,
           let index = configs.firstIndex(where: { $0.id == selectedId }) {
            Section("Model Details") {
                Picker("Provider", selection: $configs[index].provider) {
                    ForEach(ProviderType.allCases) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }
                .onChange(of: configs[index].provider) { newProvider in
                    applyProviderDefaults(at: index, provider: newProvider)
                }

                modelPicker(at: index)

                SecureField("API Key", text: $editingApiKey,
                            prompt: Text(hasExistingKey ? "Key saved \u{2713}" : "Enter API key"))

                TextField("Endpoint URL", text: $configs[index].endpoint)
            }
        }
    }

    @ViewBuilder
    private func modelPicker(at index: Int) -> some View {
        let provider = configs[index].provider
        let models = ProviderDefinition.catalog[provider]?.models ?? []

        if provider == .custom || models.isEmpty {
            TextField("Model ID", text: $configs[index].modelId)
        } else {
            Picker("Model", selection: $configs[index].modelId) {
                ForEach(models, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
        }
    }

    // MARK: - Transcription & Hotkey

    private var transcriptionSection: some View {
        Section("Transcription") {
            Picker("Language", selection: $language) {
                Text("Auto-detect").tag("auto")
                Text("English").tag("en")
                Text("Chinese (Simplified)").tag("zh")
            }
        }
    }

    private var hotkeySection: some View {
        Section("Hotkey") {
            Picker("Activation Key", selection: $hotkeyPreset) {
                ForEach(HotkeyPreset.allCases, id: \.rawValue) { preset in
                    Text(preset.rawValue).tag(preset.rawValue)
                }
            }
            Text("Restart app for hotkey changes to take effect.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        configs = store.loadConfigs()
        if let first = configs.first(where: { $0.isActive }) ?? configs.first {
            selectConfig(first)
        }
    }

    private func selectConfig(_ config: ModelConfig) {
        selectedConfigId = config.id
        editingApiKey = ""
        hasExistingKey = store.apiKey(for: config) != nil
    }

    private func setActive(_ index: Int) {
        for i in configs.indices {
            configs[i].isActive = (i == index)
        }
    }

    private func addNewConfig() {
        let def = ProviderDefinition.catalog[.openai]!
        let config = ModelConfig(
            provider: .openai,
            modelId: def.models.first ?? "whisper-1",
            endpoint: def.endpoint,
            apiFormat: def.apiFormat,
            isActive: configs.isEmpty
        )
        configs.append(config)
        selectConfig(config)
    }

    private func deleteConfig(at index: Int) {
        let config = configs[index]
        try? store.deleteApiKey(for: config)
        let wasActive = config.isActive
        configs.remove(at: index)

        if wasActive, let first = configs.first {
            configs[0].isActive = true
            selectConfig(first)
        } else if configs.isEmpty {
            selectedConfigId = nil
        }

        if selectedConfigId == config.id {
            selectedConfigId = configs.first?.id
        }
    }

    private func applyProviderDefaults(at index: Int, provider: ProviderType) {
        guard let def = ProviderDefinition.catalog[provider] else { return }
        configs[index].endpoint = def.endpoint
        configs[index].apiFormat = def.apiFormat
        if let firstModel = def.models.first {
            configs[index].modelId = firstModel
        } else {
            configs[index].modelId = ""
        }
    }

    private func saveAll() {
        // Save API key for selected config
        if let selectedId = selectedConfigId,
           let config = configs.first(where: { $0.id == selectedId }),
           !editingApiKey.isEmpty {
            try? store.saveApiKey(editingApiKey, for: config)
            hasExistingKey = true
            editingApiKey = ""
        }

        store.saveConfigs(configs)

        saveMessage = "Saved"
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            saveMessage = nil
        }
    }
}
