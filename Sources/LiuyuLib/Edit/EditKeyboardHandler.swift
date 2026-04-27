import SwiftUI

/// A view modifier that handles keyboard shortcuts in the Edit view.
struct EditViewKeyboardHandler: ViewModifier {
    let hasText: Bool
    let editState: EditState
    let onEscape: () -> Void
    let onCopy: () -> Void
    let onStartRecording: () -> Void
    let onStopRecording: () -> Void

    @State private var keyMonitor: Any?
    @State private var isRecordingViaShortcut = false
    @State private var lastEscapePressTime: Date?

    private var voiceEditShortcut: RecordedShortcut { .loadEditRecordShortcut() }
    private var clearRequiresDoubleTap: Bool { UserDefaults.standard.bool(forKey: "editClearDoubleTap") }

    func body(content: Content) -> some View {
        content
            .onAppear {
                isRecordingViaShortcut = false
                installMonitor()
            }
            .onDisappear {
                removeMonitor()
            }
    }

    private func installMonitor() {
        removeMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { event in
            handle(event)
        }
    }

    private func removeMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyDown && event.keyCode == 53 {
            return handleEscapeKey() ? nil : event
        }

        if event.type == .keyDown && event.keyCode == 8 && event.modifierFlags.contains(.command) && hasText {
            onCopy()
            return nil
        }

        let shortcut = voiceEditShortcut
        if shortcut.isModifierOnly {
            return handleModifierOnlyVoiceEdit(event, shortcut: shortcut)
        }

        return handleKeyComboVoiceEdit(event, shortcut: shortcut)
    }

    /// Handles Escape key press, considering double-tap setting.
    /// Returns true if the key should be consumed, false otherwise.
    private func handleEscapeKey() -> Bool {
        let now = Date()
        defer { lastEscapePressTime = now }

        if clearRequiresDoubleTap {
            if let lastPress = lastEscapePressTime, now.timeIntervalSince(lastPress) < 0.3 {
                onEscape()
                return true
            }
            return true
        }

        onEscape()
        return true
    }

    private func handleModifierOnlyVoiceEdit(_ event: NSEvent, shortcut: RecordedShortcut) -> NSEvent? {
        guard event.type == .flagsChanged else { return event }

        let matches = ShortcutMatcher.matches(
            eventFlags: event.modifierFlags,
            keyCode: nil,
            shortcut: shortcut
        )

        if matches && !isRecordingViaShortcut {
            if case .idle = editState {
                isRecordingViaShortcut = true
                onStartRecording()
            }
            return nil
        }

        if !matches && isRecordingViaShortcut {
            isRecordingViaShortcut = false
            onStopRecording()
            return nil
        }

        return event
    }

    private func handleKeyComboVoiceEdit(_ event: NSEvent, shortcut: RecordedShortcut) -> NSEvent? {
        let eventKeyCode = UInt16(event.keyCode)

        if event.type == .keyDown,
           ShortcutMatcher.matches(eventFlags: event.modifierFlags, keyCode: eventKeyCode, shortcut: shortcut),
           !isRecordingViaShortcut {
            if case .idle = editState {
                isRecordingViaShortcut = true
                onStartRecording()
            }
            return nil
        }

        if event.type == .keyUp && isRecordingViaShortcut && eventKeyCode == shortcut.keyCode {
            isRecordingViaShortcut = false
            onStopRecording()
            return nil
        }

        return event
    }
}
