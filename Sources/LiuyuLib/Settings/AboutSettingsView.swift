// Sources/LiuyuLib/Settings/AboutSettingsView.swift
import SwiftUI

struct AboutSettingsView: View {
    private var appIcon: NSImage? {
        // Try multiple possible locations for the app icon
        let possiblePaths: [URL] = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/AppIcon.icns"),
            Bundle.main.resourceURL?.appendingPathComponent("AppIcon.icns"),
            URL(fileURLWithPath: "/Users/lei/dev/src/github/liuyu/Sources/LiuyuLib/Resources/AppIcon.icns"),
        ].compactMap { $0 }

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path.path) {
                return NSImage(contentsOf: path)
            }
        }
        return nil
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    // Use app icon if available, fallback to system icon
                    if let icon = appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 64, height: 64)
                    } else {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                    }
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
