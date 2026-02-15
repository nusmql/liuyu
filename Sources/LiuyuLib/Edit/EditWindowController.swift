// Sources/LiuyuLib/Edit/EditWindowController.swift
import AppKit
import SwiftUI

@MainActor
class EditWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var previousApp: NSRunningApplication?

    func show() {
        // Save the previously focused app before showing our window
        previousApp = NSWorkspace.shared.frontmostApplication

        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Liuyu Edit"
        window.minSize = NSSize(width: 400, height: 300)
        window.center()
        window.contentView = NSHostingView(
            rootView: EditView(
                previousApp: previousApp,
                onClose: { [weak self] in self?.close() }
            )
        )
        window.isReleasedWhenClosed = false
        window.delegate = self

        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        false
    }
}
