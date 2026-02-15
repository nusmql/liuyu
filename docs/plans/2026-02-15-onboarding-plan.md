# Onboarding Flow Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a 3-step onboarding wizard that guides first-time users through permissions and provider setup.

**Architecture:** Dedicated `OnboardingWindowController` + `OnboardingView` (SwiftUI). AppDelegate checks a `hasCompletedOnboarding` UserDefaults flag on launch and shows onboarding instead of settings on first run. The wizard saves provider config and feature assignments automatically.

**Tech Stack:** SwiftUI, AppKit (NSWindow), AVFoundation (mic permission), ApplicationServices (accessibility)

---

### Task 1: Add API Key Page URLs to ProviderDefinition

**Files:**
- Modify: `Sources/LiuyuLib/Settings/ModelConfig.swift`

**Step 1: Add `apiKeyURL` to ProviderDefinition**

In `Sources/LiuyuLib/Settings/ModelConfig.swift`, add a new property to `ProviderDefinition` and populate it in the catalog:

```swift
public struct ProviderDefinition: Sendable {
    public let type: ProviderType
    public let sttEndpoint: String
    public let llmEndpoint: String
    public let sttModels: [String]
    public let llmModels: [String]
    public let sttApiFormat: ApiFormat
    public let apiKeyURL: String?  // <-- ADD THIS

    // ... keep existing computed properties ...

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
        .alibaba: ProviderDefinition(
            type: .alibaba,
            sttEndpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
            llmEndpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
            sttModels: ["qwen3-asr-flash"],
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
```

**Step 2: Build to verify**

Run: `swift build`
Expected: Build succeeds with no errors.

**Step 3: Commit**

```bash
git add Sources/LiuyuLib/Settings/ModelConfig.swift
git commit -m "feat: add API key page URLs to ProviderDefinition catalog"
```

---

### Task 2: Create OnboardingView (SwiftUI)

**Files:**
- Create: `Sources/LiuyuLib/Onboarding/OnboardingView.swift`

**Step 1: Create the onboarding directory**

```bash
mkdir -p Sources/LiuyuLib/Onboarding
```

**Step 2: Create OnboardingView.swift**

Create `Sources/LiuyuLib/Onboarding/OnboardingView.swift` with the complete onboarding wizard:

```swift
// Sources/LiuyuLib/Onboarding/OnboardingView.swift
import SwiftUI
import AVFoundation

struct OnboardingView: View {
    @State private var currentStep = 0
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Step indicator
            stepIndicator
                .padding(.top, 20)
                .padding(.bottom, 10)

            Divider()

            // Step content
            Group {
                switch currentStep {
                case 0: PermissionsStepView()
                case 1: ProviderStepView()
                case 2: DoneStepView()
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Navigation buttons
            navigationBar
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(index <= currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
    }

    private var navigationBar: some View {
        HStack {
            if currentStep > 0 && currentStep < 2 {
                Button("Back") {
                    withAnimation { currentStep -= 1 }
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            if currentStep < 2 {
                Button("Next") {
                    withAnimation { currentStep += 1 }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Get Started") {
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Step 1: Permissions

private struct PermissionsStepView: View {
    @State private var micGranted = false
    @State private var accessibilityGranted = false

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 24) {
            Text("Permissions")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 16) {
                // Microphone
                HStack(spacing: 12) {
                    Image(systemName: "mic.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Microphone Access")
                            .fontWeight(.medium)
                        Text("Required to record your voice")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if micGranted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Grant") {
                            Task {
                                let granted = await RecordingController.requestMicrophonePermission()
                                await MainActor.run { micGranted = granted }
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                // Accessibility
                HStack(spacing: 12) {
                    Image(systemName: "keyboard.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility Access")
                            .fontWeight(.medium)
                        Text("Required for the global hotkey")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if accessibilityGranted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Grant") {
                            HotkeyManager.requestAccessibilityPermission()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .padding(.horizontal, 40)

            if !micGranted {
                Text("Recording won't work without microphone access.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 20)
        .onAppear { refreshPermissions() }
        .onReceive(timer) { _ in refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private func refreshPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
}

// MARK: - Step 2: Provider + API Key

private struct ProviderStepView: View {
    // Only show non-custom providers for onboarding
    private let availableProviders: [ProviderType] = [.openai, .groq, .glm, .alibaba]

    @State private var selectedProvider: ProviderType = .openai
    @State private var apiKey: String = ""

    private let store = ProviderConfigStore()

    var body: some View {
        VStack(spacing: 24) {
            Text("Choose a Provider")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 16) {
                Picker("Provider", selection: $selectedProvider) {
                    ForEach(availableProviders, id: \.self) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }
                .pickerStyle(.segmented)

                SecureField("Paste your API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                if let def = ProviderDefinition.catalog[selectedProvider],
                   let url = def.apiKeyURL {
                    Link("Get API Key →", destination: URL(string: url)!)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 40)

            if !apiKey.isEmpty {
                Text("Provider will be saved when you continue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 20)
        .onChange(of: selectedProvider) { _ in
            // Clear key when switching providers
            apiKey = ""
        }
        .onDisappear {
            // Save when leaving this step (navigating to Done)
            guard !apiKey.isEmpty else { return }
            saveProvider()
        }
    }

    private func saveProvider() {
        let pc = ProviderConfig(provider: selectedProvider)
        store.saveProviders([pc])
        try? store.saveApiKey(apiKey, for: pc)

        // Auto-assign STT + LLM primary models
        let def = ProviderDefinition.catalog[selectedProvider]
        var feature = store.loadFeatureConfig()
        if let sttModel = def?.sttModels.first {
            feature.sttPrimary = ModelAssignment(providerID: pc.id, modelId: sttModel)
        }
        if let llmModel = def?.llmModels.first {
            feature.llmPrimary = ModelAssignment(providerID: pc.id, modelId: llmModel)
        }
        store.saveFeatureConfig(feature)
    }
}

// MARK: - Step 3: Done

private struct DoneStepView: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("You're all set!")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text("Hold **Right Option** to record and transcribe anywhere")
                } icon: {
                    Image(systemName: "option")
                        .frame(width: 20)
                }

                Label {
                    Text("Or click **Open** in the menu bar to use the Edit window")
                } icon: {
                    Image(systemName: "menubar.arrow.up.rectangle")
                        .frame(width: 20)
                }
            }
            .font(.body)
            .padding(.horizontal, 40)
        }
        .padding(.vertical, 20)
    }
}
```

**Step 3: Build to verify**

Run: `swift build`
Expected: Build succeeds.

**Step 4: Commit**

```bash
git add Sources/LiuyuLib/Onboarding/OnboardingView.swift
git commit -m "feat: add OnboardingView with 3-step wizard (permissions, provider, done)"
```

---

### Task 3: Create OnboardingWindowController

**Files:**
- Create: `Sources/LiuyuLib/Onboarding/OnboardingWindowController.swift`

**Step 1: Create OnboardingWindowController.swift**

Create `Sources/LiuyuLib/Onboarding/OnboardingWindowController.swift`:

```swift
// Sources/LiuyuLib/Onboarding/OnboardingWindowController.swift
import AppKit
import SwiftUI

@MainActor
class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    var isWindowVisible: Bool {
        window?.isVisible ?? false
    }

    var onComplete: (() -> Void)?
    var onWindowClose: (() -> Void)?

    func show() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to LiuYu"
        window.center()
        window.contentView = NSHostingView(
            rootView: OnboardingView(onComplete: { [weak self] in
                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                self?.close()
                self?.onComplete?()
            })
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
        onWindowClose?()
    }
}
```

**Step 2: Build to verify**

Run: `swift build`
Expected: Build succeeds.

**Step 3: Commit**

```bash
git add Sources/LiuyuLib/Onboarding/OnboardingWindowController.swift
git commit -m "feat: add OnboardingWindowController with completion callback"
```

---

### Task 4: Wire Onboarding into AppDelegate

**Files:**
- Modify: `Sources/LiuyuLib/App/AppDelegate.swift`

**Step 1: Add onboarding controller property**

After the existing controller declarations (around line 12), add:

```swift
private let onboardingController = OnboardingWindowController()
```

**Step 2: Replace first-launch logic in applicationDidFinishLaunching**

Replace the existing first-launch check (the `if providerStore.loadFeatureConfig().sttPrimary == nil` block) with onboarding logic. Also wire `onboardingController.onWindowClose` into the activation policy:

```swift
        settingsController.onWindowClose = updatePolicy
        editController.onWindowClose = updatePolicy
        onboardingController.onWindowClose = updatePolicy

        // First launch: show onboarding wizard
        if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            onboardingController.onComplete = { [weak self] in
                self?.updateActivationPolicy()
            }
            onboardingController.show()
        }
```

Remove the old block:
```swift
        // First launch: open settings if no active model configured
        if providerStore.loadFeatureConfig().sttPrimary == nil {
            settingsController.show()
        }
```

**Step 3: Build and verify**

Run: `swift build`
Expected: Build succeeds.

**Step 4: Test manually**

To test onboarding, reset the flag:
```bash
defaults delete com.liuyu.app hasCompletedOnboarding
```

Then run: `open build/Liuyu.app`
Expected: Onboarding window appears instead of settings.

**Step 5: Commit**

```bash
git add Sources/LiuyuLib/App/AppDelegate.swift
git commit -m "feat: show onboarding wizard on first launch"
```

---

### Task 5: Build, Bundle, and Manual Test

**Step 1: Build release and bundle**

```bash
swift build -c release && \
rm -rf build/Liuyu.app && \
mkdir -p build/Liuyu.app/Contents/MacOS build/Liuyu.app/Contents/Resources && \
cp .build/release/Liuyu build/Liuyu.app/Contents/MacOS/ && \
cp Sources/LiuyuLib/Resources/Info.plist build/Liuyu.app/Contents/ && \
codesign --force --sign "Liuyu Dev" --entitlements Sources/LiuyuLib/Resources/Liuyu.entitlements --identifier com.liuyu.app build/Liuyu.app
```

**Step 2: Reset onboarding flag and test**

```bash
defaults delete com.liuyu.app hasCompletedOnboarding
open build/Liuyu.app
```

**Step 3: Walk through all 3 steps**

- Step 1: Grant mic + accessibility permissions
- Step 2: Select a provider, paste API key, click Next
- Step 3: Click "Get Started"
- Verify: onboarding closes, status bar icon active, try recording

**Step 4: Verify onboarding doesn't reappear**

Close and reopen the app. Onboarding should NOT appear again.

**Step 5: Commit any fixes, then final commit**

```bash
git add -A
git commit -m "feat: complete onboarding flow — permissions, provider setup, done screen"
```
