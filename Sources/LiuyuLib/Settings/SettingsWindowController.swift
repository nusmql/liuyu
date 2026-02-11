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
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "General"
        window.minSize = NSSize(width: 650, height: 500)
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

    public func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        false
    }
}
