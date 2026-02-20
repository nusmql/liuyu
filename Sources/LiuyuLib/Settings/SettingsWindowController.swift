import AppKit
import SwiftUI

@MainActor
public final class SettingsWindowController: WindowController {
    public init() {
        super.init(
            title: "General",
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 500)
        ) {
            NSHostingView(rootView: SettingsView())
        }
    }
}
