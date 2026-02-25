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
                                await MainActor.run {
                                    micGranted = granted
                                    // Re-activate app after permission dialog closes
                                    NSApp.activate(ignoringOtherApps: true)
                                }
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
                            // Re-activate app after opening System Settings
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                NSApp.activate(ignoringOtherApps: true)
                            }
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
            apiKey = ""
        }
        .onDisappear {
            guard !apiKey.isEmpty else { return }
            saveProvider()
        }
    }

    private func saveProvider() {
        let pc = ProviderConfig(provider: selectedProvider)
        store.saveProviders([pc])
        try? store.saveApiKey(apiKey, for: pc)

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
