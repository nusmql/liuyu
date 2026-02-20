// Sources/LiuyuLib/UI/WindowController.swift
import AppKit
import SwiftUI

/// Base window controller that handles common window lifecycle and activation policy.
@MainActor
public class WindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let title: String
    private let contentRect: NSRect
    private let styleMask: NSWindow.StyleMask
    private let makeContentView: () -> NSView

    /// Called when the window closes.
    public var onWindowClose: (() -> Void)?

    /// Returns true if the window is currently visible.
    public var isWindowVisible: Bool {
        window?.isVisible ?? false
    }

    /// Creates a new window controller.
    /// - Parameters:
    ///   - title: The window title.
    ///   - contentRect: The initial window frame.
    ///   - styleMask: Window style options.
    ///   - contentView: Closure that creates the content view.
    public init(
        title: String,
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask = [.titled, .closable],
        contentView: @escaping () -> NSView
    ) {
        self.title = title
        self.contentRect = contentRect
        self.styleMask = styleMask
        self.makeContentView = contentView
        super.init()
    }

    /// Shows the window, creating it if necessary.
    /// If already visible, brings it to front.
    public func show() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = makeContentView()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    /// Closes the window.
    public func close() {
        window?.close()
    }

    public func windowWillClose(_ notification: Notification) {
        onWindowClose?()
    }

    public func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        false
    }
}
