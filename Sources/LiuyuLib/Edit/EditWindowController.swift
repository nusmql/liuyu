// Sources/LiuyuLib/Edit/EditWindowController.swift
import AppKit
import SwiftUI

@MainActor
class EditWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    var isWindowVisible: Bool {
        window?.isVisible ?? false
    }

    /// Called when any managed window closes, to decide activation policy.
    var onWindowClose: (() -> Void)?

    func show() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LiuYu"
        window.minSize = NSSize(width: 400, height: 150)
        window.center()
        window.contentView = NSHostingView(
            rootView: EditView(onClose: { [weak self] in self?.close() })
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
        onWindowClose?()
    }

    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        false
    }
}
