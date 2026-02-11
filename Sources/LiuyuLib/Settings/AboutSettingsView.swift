// Sources/LiuyuLib/Settings/AboutSettingsView.swift
import SwiftUI

struct AboutSettingsView: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Liuyu")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Version 0.1.0")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section {
                LabeledContent("Built with", value: "Swift & SwiftUI")
                LabeledContent("License", value: "MIT")
            }
        }
        .formStyle(.grouped)
    }
}
