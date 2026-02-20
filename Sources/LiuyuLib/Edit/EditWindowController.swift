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

    func show() {
        showWithText("") { _ in }
    }

    func showWithText(_ text: String, onInsert: @escaping (String) -> Void) {
        // If window already visible, just update the text and bring to front
        if let window, window.isVisible {
            editViewModel?.text = text
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
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
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LiuYu"
        window.minSize = NSSize(width: 400, height: 150)
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

        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

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

    func windowWillClose(_ notification: Notification) {
        onWindowClose?()
    }

    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        false
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
