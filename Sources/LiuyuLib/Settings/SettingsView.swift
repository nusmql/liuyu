// Sources/LiuyuLib/Settings/SettingsView.swift
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case transcription = "Transcription"
    case hotkey = "Hotkey"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gear"
        case .transcription: return "text.bubble"
        case .hotkey: return "keyboard"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @State private var selectedSection: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(180)
            .safeAreaInset(edge: .bottom) {
                Text("Liuyu v0.1.0")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 8)
            }
        } detail: {
            switch selectedSection {
            case .general:
                GeneralSettingsView()
            case .transcription:
                TranscriptionSettingsView()
            case .hotkey:
                HotkeySettingsView()
            case .about:
                AboutSettingsView()
            }
        }
    }
}
