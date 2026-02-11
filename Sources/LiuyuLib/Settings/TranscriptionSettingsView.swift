// Sources/LiuyuLib/Settings/TranscriptionSettingsView.swift
import SwiftUI

struct TranscriptionSettingsView: View {
    @AppStorage("language") private var language = "auto"

    var body: some View {
        Form {
            Section("Transcription") {
                Picker("Language", selection: $language) {
                    Text("Auto-detect").tag("auto")
                    Text("English").tag("en")
                    Text("Chinese (Simplified)").tag("zh")
                }
            }
        }
        .formStyle(.grouped)
    }
}
