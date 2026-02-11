# Settings Sidebar Navigation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Redesign the settings window from a single scrollable form to a sidebar-navigation layout with four sections: General, Transcription, Hotkey, About.

**Architecture:** Replace the monolithic `SettingsView` with a `NavigationSplitView`-based layout. The sidebar lists sections using a `SettingsSection` enum. Each section gets its own SwiftUI view extracted from the current form content. SF Symbols for sidebar icons.

**Tech Stack:** SwiftUI NavigationSplitView (macOS 13+), SF Symbols, existing ModelConfig/KeychainHelper infrastructure.

---

## Task 1: Create Section Views

**Files:**
- Create: `Sources/LiuyuLib/Settings/GeneralSettingsView.swift`
- Create: `Sources/LiuyuLib/Settings/TranscriptionSettingsView.swift`
- Create: `Sources/LiuyuLib/Settings/HotkeySettingsView.swift`
- Create: `Sources/LiuyuLib/Settings/AboutSettingsView.swift`

**Step 1: Create GeneralSettingsView**

This is the bulk of the current `SettingsView` — models list, model details, and save button — moved into its own view.

```swift
// Sources/LiuyuLib/Settings/GeneralSettingsView.swift
import SwiftUI

struct GeneralSettingsView: View {
    @State private var configs: [ModelConfig] = []
    @State private var selectedConfigId: UUID?
    @State private var editingApiKey: String = ""
    @State private var hasExistingKey: Bool = false
    @State private var saveMessage: String?

    private let store = ModelConfigStore()

    var body: some View {
        Form {
            modelsSection
            detailsSection
            saveSection
        }
        .formStyle(.grouped)
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
```

**Step 2: Create TranscriptionSettingsView**

```swift
// Sources/LiuyuLib/Settings/TranscriptionSettingsView.swift
import SwiftUI

struct TranscriptionSettingsView: View {
    @AppStorage("language") private var language = "auto"

    var body: some View {
        Form {
            Section("Transcription") {
                Picker("Language", selection: $language) {
                    Text("Auto-detect").tag("auto")
                    Text("English").tag("en")
                    Text("Chinese (Simplified)").tag("zh")
                }
            }
        }
        .formStyle(.grouped)
    }
}
```

**Step 3: Create HotkeySettingsView**

```swift
// Sources/LiuyuLib/Settings/HotkeySettingsView.swift
import SwiftUI

struct HotkeySettingsView: View {
    @AppStorage("hotkeyPreset") private var hotkeyPreset = HotkeyPreset.rightOption.rawValue

    var body: some View {
        Form {
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
        .formStyle(.grouped)
    }
}
```

**Step 4: Create AboutSettingsView**

```swift
// Sources/LiuyuLib/Settings/AboutSettingsView.swift
import SwiftUI

struct AboutSettingsView: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Liuyu")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Version 0.1.0")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section {
                LabeledContent("Built with", value: "Swift & SwiftUI")
                LabeledContent("License", value: "MIT")
            }
        }
        .formStyle(.grouped)
    }
}
```

**Step 5: Verify it compiles**

Run: `swift build 2>&1`
Expected: BUILD SUCCEEDED (new files are additive, existing SettingsView still compiles)

**Step 6: Commit**

```bash
git add Sources/LiuyuLib/Settings/GeneralSettingsView.swift Sources/LiuyuLib/Settings/TranscriptionSettingsView.swift Sources/LiuyuLib/Settings/HotkeySettingsView.swift Sources/LiuyuLib/Settings/AboutSettingsView.swift
git commit -m "feat: add individual settings section views for sidebar navigation"
```

---

## Task 2: Replace SettingsView with Sidebar Navigation

**Files:**
- Modify: `Sources/LiuyuLib/Settings/SettingsView.swift`

**Step 1: Rewrite SettingsView with NavigationSplitView**

Replace the entire contents of `SettingsView.swift` with:

```swift
// Sources/LiuyuLib/Settings/SettingsView.swift
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case transcription = "Transcription"
    case hotkey = "Hotkey"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gear"
        case .transcription: return "text.bubble"
        case .hotkey: return "keyboard"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @State private var selectedSection: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(180)
            .safeAreaInset(edge: .bottom) {
                Text("Liuyu v0.1.0")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 8)
            }
        } detail: {
            switch selectedSection {
            case .general:
                GeneralSettingsView()
            case .transcription:
                TranscriptionSettingsView()
            case .hotkey:
                HotkeySettingsView()
            case .about:
                AboutSettingsView()
            }
        }
    }
}
```

**Step 2: Verify it compiles**

Run: `swift build 2>&1`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/LiuyuLib/Settings/SettingsView.swift
git commit -m "feat: replace single-form settings with sidebar navigation layout"
```

---

## Task 3: Update Window Size and Verify

**Files:**
- Modify: `Sources/LiuyuLib/Settings/SettingsWindowController.swift`

**Step 1: Update window dimensions**

In `SettingsWindowController.swift`, change the window size to accommodate the sidebar:

Change:
```swift
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
```
To:
```swift
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 500),
```

Change:
```swift
        window.minSize = NSSize(width: 480, height: 500)
```
To:
```swift
        window.minSize = NSSize(width: 600, height: 400)
```

**Step 2: Verify it compiles**

Run: `swift build 2>&1`
Expected: BUILD SUCCEEDED

**Step 3: Run all tests**

Run: `swift test 2>&1`
Expected: All tests pass (no test changes needed — settings views are UI-only)

**Step 4: Build the app bundle for manual verification**

Run: `bash scripts/bundle.sh 2>&1`
Expected: "App bundle created at build/Liuyu.app"

**Step 5: Commit**

```bash
git add Sources/LiuyuLib/Settings/SettingsWindowController.swift
git commit -m "feat: update settings window size for sidebar layout"
```

---

## Summary

| Task | What | Verification |
|------|------|-------------|
| 1 | Create 4 section views (General, Transcription, Hotkey, About) | Compiles |
| 2 | Replace SettingsView with NavigationSplitView + sidebar | Compiles |
| 3 | Update window size in SettingsWindowController | Compiles + all tests pass + bundle builds |
