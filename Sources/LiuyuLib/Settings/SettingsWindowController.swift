import AppKit
import SwiftUI

@MainActor
public class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    public override init() { super.init() }

    public func show() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Liuyu Settings"
        window.minSize = NSSize(width: 480, height: 500)
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView())
        window.isReleasedWhenClosed = false
        window.delegate = self

        // Show in Cmd+Tab while settings is open
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    public func windowWillClose(_ notification: Notification) {
        // Return to menu bar-only mode when settings closes
        NSApp.setActivationPolicy(.accessory)
    }
}
