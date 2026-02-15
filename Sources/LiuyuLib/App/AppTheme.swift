import AppKit

@MainActor
enum AppTheme {
    static func apply(_ theme: String) {
        switch theme {
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default:
            NSApp.appearance = nil // follow system
        }
    }

    static func applyFromDefaults() {
        let theme = UserDefaults.standard.string(forKey: "appTheme") ?? "system"
        apply(theme)
    }
}
