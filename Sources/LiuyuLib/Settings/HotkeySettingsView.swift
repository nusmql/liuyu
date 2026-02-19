// Sources/LiuyuLib/Settings/HotkeySettingsView.swift
import SwiftUI

struct HotkeySettingsView: View {
    @State private var shortcut: RecordedShortcut? = RecordedShortcut.loadFromDefaults()
    @State private var conflictWarning: String? = nil

    // Edit window shortcuts
    @State private var editRecordShortcut: EditWindowShortcut = .loadEditRecordShortcut()
    @State private var clearRequiresDoubleTap: Bool = UserDefaults.standard.bool(forKey: "editClearDoubleTap")

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
                        ShortcutRecorderView(shortcut: $shortcut, onBeginRecording: {
                            // Clear the old shortcut first to prevent it from activating during recording
                            self.shortcut = nil
                            // Save nil to defaults and notify to disable the old hotkey
                            UserDefaults.standard.removeObject(forKey: "recordedShortcut")
                            NotificationCenter.default.post(name: .hotkeyShortcutChanged, object: nil)
                            // Then notify that recording has begun
                            NotificationCenter.default.post(name: .hotkeyRecordingDidBegin, object: nil)
                        })
                            .frame(height: 36)
                            .onChange(of: shortcut) { newValue in
                                checkConflicts(for: newValue)
                                newValue?.saveToDefaults()
                                NotificationCenter.default.post(name: .hotkeyShortcutChanged, object: newValue)
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

            Section("Edit Window Shortcuts") {
                VStack(alignment: .leading, spacing: 16) {
                    // Voice Record Shortcut
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Voice Record Shortcut")
                            .font(.headline)

                        Text("Hold this shortcut in the Edit window to record voice for editing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Picker("Record Shortcut", selection: $editRecordShortcut) {
                            ForEach(EditWindowShortcut.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: editRecordShortcut) { newValue in
                            newValue.saveToDefaults()
                        }
                    }

                    Divider()

                    // Clear Shortcut
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Clear Shortcut")
                            .font(.headline)

                        Text("Press Escape to clear text in Edit window.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Toggle("Require double-press to clear", isOn: $clearRequiresDoubleTap)
                            .onChange(of: clearRequiresDoubleTap) { newValue in
                                UserDefaults.standard.set(newValue, forKey: "editClearDoubleTap")
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
