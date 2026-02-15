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
