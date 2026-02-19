// Sources/LiuyuLib/Settings/HotkeySettingsView.swift
import SwiftUI

struct HotkeySettingsView: View {
    @State private var shortcut: RecordedShortcut? = RecordedShortcut.loadFromDefaults()
    @State private var conflictWarning: String? = nil

    // Edit window shortcuts
    @State private var editRecordShortcut: RecordedShortcut? = RecordedShortcut.loadEditRecordShortcut()
    @State private var editRecordConflictWarning: String? = nil
    @State private var clearRequiresDoubleTap: Bool = UserDefaults.standard.bool(forKey: "editClearDoubleTap")

    var body: some View {
        Form {
            Section("Shortcuts") {
                VStack(spacing: 0) {
                    // Activation Shortcut Row
                    HStack(spacing: 16) {
                        Text("Activation Shortcut")
                            .font(.system(size: 13))
                            .frame(width: 140, alignment: .leading)

                        Spacer()

                        HStack(spacing: 8) {
                            if let warning = conflictWarning {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                                    .font(.caption)
                                    .help(warning)
                            }

                            ShortcutRecorderView(shortcut: $shortcut, onBeginRecording: {
                                self.shortcut = nil
                                UserDefaults.standard.removeObject(forKey: "recordedShortcut")
                                NotificationCenter.default.post(name: .hotkeyShortcutChanged, object: nil)
                                NotificationCenter.default.post(name: .hotkeyRecordingDidBegin, object: nil)
                            })
                                .frame(width: 140, height: 28)
                                .onChange(of: shortcut) { newValue in
                                    checkConflicts(for: newValue)
                                    newValue?.saveToDefaults()
                                    NotificationCenter.default.post(name: .hotkeyShortcutChanged, object: newValue)
                                }
                        }
                    }
                    .padding(.vertical, 12)

                    Divider()
                        .padding(.leading, 140)

                    // Voice Record Shortcut Row
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Voice Record")
                                .font(.system(size: 13))

                            Text("Hold in Edit window")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 140, alignment: .leading)

                        Spacer()

                        HStack(spacing: 8) {
                            if let warning = editRecordConflictWarning {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                                    .font(.caption)
                                    .help(warning)
                            }

                            ShortcutRecorderView(shortcut: $editRecordShortcut, onBeginRecording: {
                                self.editRecordShortcut = nil
                            })
                                .frame(width: 140, height: 28)
                                .onChange(of: editRecordShortcut) { newValue in
                                    checkEditRecordConflicts(for: newValue)
                                    newValue?.saveEditRecordShortcut()
                                }
                        }
                    }
                    .padding(.vertical, 12)

                    Divider()
                        .padding(.leading, 140)

                    // Clear Shortcut Row
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Clear Text")
                                .font(.system(size: 13))

                            Text(clearRequiresDoubleTap ? "Double-press Escape" : "Press Escape")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 140, alignment: .leading)

                        Spacer()

                        Toggle("", isOn: $clearRequiresDoubleTap)
                            .toggleStyle(.switch)
                            .frame(width: 140, alignment: .trailing)
                            .onChange(of: clearRequiresDoubleTap) { newValue in
                                UserDefaults.standard.set(newValue, forKey: "editClearDoubleTap")
                            }
                    }
                    .padding(.vertical, 12)
                }
                .padding(.horizontal, 16)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 200)
    }

    private func checkConflicts(for shortcut: RecordedShortcut?) {
        guard let shortcut = shortcut else {
            conflictWarning = nil
            return
        }

        let flags = shortcut.flags
        let modifiers = flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])

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

    private func checkEditRecordConflicts(for shortcut: RecordedShortcut?) {
        guard let shortcut = shortcut else {
            editRecordConflictWarning = nil
            return
        }

        let flags = shortcut.flags
        let modifiers = flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])

        let commonSystemShortcuts: [CGEventFlags] = [
            [.maskCommand, .maskShift, .maskAlternate],
            [.maskCommand, .maskControl],
            [.maskCommand, .maskShift, .maskControl],
        ]

        if commonSystemShortcuts.contains(where: { $0 == modifiers }) {
            editRecordConflictWarning = "May conflict with system shortcuts"
        } else {
            editRecordConflictWarning = nil
        }
    }
}
