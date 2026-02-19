// Sources/LiuyuLib/Settings/HotkeySettingsView.swift
import SwiftUI

struct HotkeySettingsView: View {
    @State private var shortcut: RecordedShortcut? = RecordedShortcut.loadFromDefaults()
    @State private var conflictWarning: String? = nil

    // Edit window shortcuts
    @State private var editRecordShortcut: RecordedShortcut? = RecordedShortcut.loadEditRecordShortcut()
    @State private var editRecordConflictWarning: String? = nil
    @State private var clearRequiresDoubleTap: Bool = UserDefaults.standard.bool(forKey: "editClearDoubleTap")
    @State private var silenceTimeout: SilenceTimeoutOption = SilenceTimeoutOption.loadFromDefaults()

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
