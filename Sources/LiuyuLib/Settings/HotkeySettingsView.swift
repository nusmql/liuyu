// Sources/LiuyuLib/Settings/HotkeySettingsView.swift
import SwiftUI

struct HotkeySettingsView: View {
    @State private var shortcut: RecordedShortcut? = RecordedShortcut.loadFromDefaults()
    @State private var conflictWarning: String? = nil

    // Edit window shortcuts
    @State private var editVoiceEditShortcut: RecordedShortcut? = RecordedShortcut.loadEditRecordShortcut()
    @State private var editVoiceEditConflictWarning: String? = nil
    @State private var clearRequiresDoubleTap: Bool = UserDefaults.standard.bool(forKey: "editClearDoubleTap")
    @State private var silenceTimeout: SilenceTimeoutOption = SilenceTimeoutOption.loadFromDefaults()
    @State private var useClickMode: Bool = UserDefaults.standard.bool(forKey: "hotkeyUseClickMode")

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
                                // Do NOT manually post .hotkeyShortcutChanged or .hotkeyRecordingDidBegin here.
                                // ShortcutRecorder already posts .hotkeyRecordingDidBegin.
                                // And setting self.shortcut = nil triggers .onChange which posts .hotkeyShortcutChanged.
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

                    // Voice Edit Shortcut Row
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Voice Edit")
                                .font(.system(size: 13))

                            Text("Hold in Edit window to edit text")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 140, alignment: .leading)

                        Spacer()

                        HStack(spacing: 8) {
                            if let warning = editVoiceEditConflictWarning {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                                    .font(.caption)
                                    .help(warning)
                            }

                            ShortcutRecorderView(shortcut: $editVoiceEditShortcut, onBeginRecording: {
                                self.editVoiceEditShortcut = nil
                            })
                                .frame(width: 140, height: 28)
                                .onChange(of: editVoiceEditShortcut) { newValue in
                                    checkEditVoiceEditConflicts(for: newValue)
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

                    Divider()
                        .padding(.leading, 140)

                    // Silence Timeout Row
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Silence Timeout")
                                .font(.system(size: 13))

                            Text("Auto-stop when silent")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 140, alignment: .leading)

                        Spacer()

                        Picker("", selection: $silenceTimeout) {
                            ForEach(SilenceTimeoutOption.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 140)
                        .onChange(of: silenceTimeout) { newValue in
                            UserDefaults.standard.set(newValue.rawValue, forKey: "silenceTimeout")
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
        conflictWarning = systemConflictWarning(for: shortcut)
    }

    private func checkEditVoiceEditConflicts(for shortcut: RecordedShortcut?) {
        editVoiceEditConflictWarning = systemConflictWarning(for: shortcut)
    }

    private func systemConflictWarning(for shortcut: RecordedShortcut?) -> String? {
        guard let shortcut = shortcut else { return nil }

        let modifiers = shortcut.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])

        let commonSystemShortcuts: [CGEventFlags] = [
            [.maskCommand, .maskShift, .maskAlternate],
            [.maskCommand, .maskControl],
            [.maskCommand, .maskShift, .maskControl],
        ]

        return commonSystemShortcuts.contains(where: { $0 == modifiers }) ? "May conflict with system shortcuts" : nil
    }
}

// MARK: - Silence Timeout Options

enum SilenceTimeoutOption: Int, CaseIterable, Identifiable {
    case threeSeconds = 3
    case fiveSeconds = 5
    case tenSeconds = 10
    case disabled = 0   // 0 means disabled

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .threeSeconds: return "3s"
        case .fiveSeconds: return "5s"
        case .tenSeconds: return "10s"
        case .disabled: return "Off"
        }
    }

    var duration: TimeInterval {
        TimeInterval(rawValue)
    }

    static func loadFromDefaults() -> SilenceTimeoutOption {
        let savedValue = UserDefaults.standard.integer(forKey: "silenceTimeout")
        return SilenceTimeoutOption(rawValue: savedValue) ?? .fiveSeconds
    }
}
