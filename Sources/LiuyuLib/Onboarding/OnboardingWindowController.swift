// Sources/LiuyuLib/Onboarding/OnboardingWindowController.swift
import AppKit
import SwiftUI

@MainActor
class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    var isWindowVisible: Bool {
        window?.isVisible ?? false
    }

    var onComplete: (() -> Void)?
    var onWindowClose: (() -> Void)?

    func show() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to LiuYu"
        window.center()
        window.contentView = NSHostingView(
            rootView: OnboardingView(onComplete: { [weak self] in
                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                self?.close()
                self?.onComplete?()
            })
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
}
