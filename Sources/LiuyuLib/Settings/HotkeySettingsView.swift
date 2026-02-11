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
