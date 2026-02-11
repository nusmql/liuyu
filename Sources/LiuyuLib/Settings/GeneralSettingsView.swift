import SwiftUI
import AVFoundation

struct GeneralSettingsView: View {
    @State private var accessibilityGranted = HotkeyManager.isAccessibilityGranted
    @State private var microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

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
                            HotkeyManager.requestAccessibilityPermission()
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
                            Task {
                                microphoneGranted = await RecordingController.requestMicrophonePermission()
                            }
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
        .onAppear {
            accessibilityGranted = HotkeyManager.isAccessibilityGranted
            microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }
}
