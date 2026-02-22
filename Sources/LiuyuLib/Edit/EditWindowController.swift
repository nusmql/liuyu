// Sources/LiuyuLib/Edit/EditWindowController.swift
import AppKit
import SwiftUI

@MainActor
class EditWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var editViewModel: EditViewModel?

    /// The app the user was working in before opening the Edit window.
    private var previousApp: NSRunningApplication?
    /// The mouse position (screen coords) when the Edit window was opened.
    private var previousMouseLocation: NSPoint?

    var isWindowVisible: Bool {
        window?.isVisible ?? false
    }

    /// Returns true if the edit window has text content
    var hasText: Bool {
        editViewModel?.hasText ?? false
    }

    /// Called when any managed window closes, to decide activation policy.
    var onWindowClose: (() -> Void)?
    
    /// Called when the window is shown.
    var onWindowShow: (() -> Void)?

    func show() {
        showWithText("") { _ in }
    }

    func showWithText(_ text: String, onInsert: @escaping (String) -> Void) {
        // If window already visible, just update the text and bring to front
        if let window, window.isVisible {
            Logger.debug("showWithText: window already visible, updating text", category: .ui)
            // Clear previous text before setting new text
            editViewModel?.clear()
            editViewModel?.text = text
            Logger.debug("showWithText: text set to '\(text.prefix(20))...', hasText=\(editViewModel?.hasText ?? false)", category: .ui)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            // Delay to ensure the view is updated, then focus the text field
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.focusTextField(in: window)
            }
            return
        }

        // Capture context before showing our window
        let liuyuBundleID = Bundle.main.bundleIdentifier
        let frontApp = NSWorkspace.shared.frontmostApplication
        if frontApp?.bundleIdentifier != liuyuBundleID {
            previousApp = frontApp
        }
        previousMouseLocation = NSEvent.mouseLocation

        let isNew = (window == nil)
        let window = self.window ?? NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LiuYu"
        window.minSize = NSSize(width: 400, height: 200)
        if isNew { window.center() }

        // Always set fresh content so previous text doesn't linger
        let capturedApp = previousApp
        let capturedMouse = previousMouseLocation
        let viewModel = EditViewModel()
        viewModel.text = text
        self.editViewModel = viewModel
        window.contentView = NSHostingView(
            rootView: EditView(
                viewModel: viewModel,
                onInsert: { [weak self] text in
                    self?.performInsert(text: text, app: capturedApp, mouseLocation: capturedMouse)
                    onInsert(text)
                },
                onClose: { [weak self] in self?.close() }
            )
        )
        window.isReleasedWhenClosed = false
        window.delegate = self

        // NSApp.setActivationPolicy(.regular) // Removed to keep dock icon hidden
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onWindowShow?()

        self.window = window
    }

    func close() {
        window?.close()
    }

    /// Applies a voice instruction to modify the current text using LLM.
    /// This is called when the Edit window is already open and user uses the global shortcut.
    func applyInstruction(_ instruction: String) {
        guard let viewModel = editViewModel else { return }
        Task {
            await viewModel.applyInstruction(instruction)
        }
    }

    /// Clears the current text in the edit window.
    func clear() {
        editViewModel?.clear()
    }

    func windowWillClose(_ notification: Notification) {
        onWindowClose?()
    }

    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        false
    }

    // MARK: - Focus

    /// Recursively finds the NSTextView in the view hierarchy and makes it first responder
    private func focusTextField(in window: NSWindow) {
        guard let contentView = window.contentView else { return }

        if let textView = findTextView(in: contentView) {
            Logger.debug("EditWindowController: Focusing NSTextView", category: .ui)
            window.makeFirstResponder(textView)
        }
    }

    /// Recursively searches for NSTextView in the view hierarchy
    private func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView {
            return textView
        }

        for subview in view.subviews {
            if let textView = findTextView(in: subview) {
                return textView
            }
        }

        return nil
    }

    // MARK: - Insert

    private func performInsert(text: String, app: NSRunningApplication?, mouseLocation: NSPoint?) {
        // Copy text to clipboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        // Activate the previous app
        app?.activate()

        Task {
            try? await Task.sleep(nanoseconds: 150_000_000) // 0.15s for app activation

            // Click at the saved mouse position to restore cursor focus
            if let screenPoint = mouseLocation {
                Self.clickAt(screenPoint: screenPoint)
                try? await Task.sleep(nanoseconds: 50_000_000) // 0.05s for click to register
            }

            Self.simulatePaste()
        }
    }

    /// Click at a screen position (NSEvent coordinates: origin bottom-left).
    private static func clickAt(screenPoint: NSPoint) {
        // Convert from NSEvent coords (bottom-left origin) to CGEvent coords (top-left origin)
        guard let mainScreen = NSScreen.main else { return }
        let cgPoint = CGPoint(x: screenPoint.x, y: mainScreen.frame.height - screenPoint.y)

        let source = CGEventSource(stateID: .combinedSessionState)
        let mouseDown = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                mouseCursorPosition: cgPoint, mouseButton: .left)
        let mouseUp = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                              mouseCursorPosition: cgPoint, mouseButton: .left)
        mouseDown?.post(tap: .cghidEventTap)
        mouseUp?.post(tap: .cghidEventTap)
    }

    private static func simulatePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
