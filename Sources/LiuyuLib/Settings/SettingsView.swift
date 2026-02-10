import SwiftUI

struct SettingsView: View {
    @State private var apiKey: String = ""
    @State private var hasExistingKey: Bool = false
    @AppStorage("endpoint") private var endpoint = "https://api.openai.com/v1/audio/transcriptions"
    @AppStorage("language") private var language = "auto"
    @State private var saveMessage: String?

    private let keychain = KeychainHelper()

    var body: some View {
        Form {
            Section("API Configuration") {
                SecureField("API Key", text: $apiKey, prompt: Text(hasExistingKey ? "Key saved \u{2713}" : "sk-..."))

                TextField("Endpoint URL", text: $endpoint)

                Picker("Language", selection: $language) {
                    Text("Auto-detect").tag("auto")
                    Text("English").tag("en")
                    Text("Chinese (Simplified)").tag("zh")
                }
            }

            Section("Hotkey") {
                LabeledContent("Activation Key", value: "Right Option")
                Text("Custom hotkeys coming in a future version.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                if let saveMessage {
                    Text(saveMessage)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Button("Save") {
                    saveApiKey()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 320)
        .onAppear {
            loadApiKey()
        }
    }

    private func loadApiKey() {
        if let key = try? keychain.read(key: "openai-api-key"), !key.isEmpty {
            hasExistingKey = true
        }
    }

    private func saveApiKey() {
        if !apiKey.isEmpty {
            try? keychain.save(key: "openai-api-key", value: apiKey)
            hasExistingKey = true
            apiKey = ""
        }
        saveMessage = "Saved"
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            saveMessage = nil
        }
    }
}
