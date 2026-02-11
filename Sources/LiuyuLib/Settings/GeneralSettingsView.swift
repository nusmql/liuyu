import SwiftUI
import AVFoundation

struct GeneralSettingsView: View {
    @State private var accessibilityGranted = false
    @State private var microphoneGranted = false

    var body: some View {
        Form {
            Section("Permissions") {
                HStack {
                    Image(systemName: accessibilityGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(accessibilityGranted ? .green : .red)
                    Text("Accessibility Permissions")
                    Spacer()
                    if !accessibilityGranted {
                        Button("Grant") {
                            NSWorkspace.shared.open(
                                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if !accessibilityGranted {
                    Text("Liuyu needs accessibility access to detect the hotkey.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Image(systemName: microphoneGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(microphoneGranted ? .green : .red)
                    Text("Microphone Permissions")
                    Spacer()
                    if !microphoneGranted {
                        Button("Grant") {
                            NSWorkspace.shared.open(
                                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if !microphoneGranted {
                    Text("Liuyu needs microphone access to record your voice.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private func refreshPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
}
