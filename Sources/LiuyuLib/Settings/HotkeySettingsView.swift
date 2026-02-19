// Sources/LiuyuLib/Settings/HotkeySettingsView.swift
import SwiftUI

struct HotkeySettingsView: View {
    @State private var shortcut: RecordedShortcut? = RecordedShortcut.loadFromDefaults()
    @State private var conflictWarning: String? = nil

    var body: some View {
        Form {
            Section("Voice Input Activation") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Activation Shortcut")
                        .font(.headline)

                    Text("Press and hold this shortcut to start recording voice. Release to transcribe.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        ShortcutRecorderView(shortcut: $shortcut)
                            .frame(height: 36)
                            .onChange(of: shortcut) { newValue in
                                checkConflicts(for: newValue)
                            }

                        if let warning = conflictWarning {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle")
                                Text(warning)
                            }
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400)
    }

    private func checkConflicts(for shortcut: RecordedShortcut?) {
        guard let shortcut = shortcut else {
            conflictWarning = nil
            return
        }

        let flags = shortcut.flags
        let modifiers = flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])

        // Check for common system shortcuts
        let commonSystemShortcuts: [CGEventFlags] = [
            [.maskCommand, .maskShift, .maskAlternate],
            [.maskCommand, .maskControl],
            [.maskCommand, .maskShift, .maskControl],
        ]

        if commonSystemShortcuts.contains(where: { $0 == modifiers }) {
            conflictWarning = "May conflict with system shortcuts"
        } else {
            conflictWarning = nil
        }
    }
}
