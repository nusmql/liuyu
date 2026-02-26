// Sources/LiuyuLib/Hotkey/HotkeyManager.swift
import AppKit
import Carbon
import Combine
import CoreGraphics

public enum HotkeyEvent {
    case keyDown
    case keyUp
}

public class HotkeyManager {
    public let events = PassthroughSubject<HotkeyEvent, Never>()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerUPP: EventHandlerUPP?
    private var isKeyDown = false
    private var eventHandlerInstalled = false

    /// Returns true if currently using EventTap (for modifier-only or Fn+key shortcuts)
    public var isUsingEventTap: Bool {
        eventTap != nil
    }

    /// Set to true during recording to prevent keyDown re-triggering
    public var isRecording = false

    public var shortcut: RecordedShortcut = .default {
        didSet {
            Logger.debug("Shortcut didSet: \(shortcut.displayString)", category: .hotkey)
            // Restart hotkey registration with new shortcut immediately
            stop()
            // Only start if shortcut is valid
            if shortcut.isValid {
                try? start()
            }
        }
    }

    public init() {}

    /// Check if accessibility permission is granted.
    public static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt user for accessibility permission (shows system dialog). Returns true if already granted.
    @discardableResult
    public static func requestAccessibilityPermission(prompt: Bool = true) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public func start() throws {
        Logger.debug("start() called, shortcut: \(shortcut.displayString)", category: .hotkey)
        guard Self.isAccessibilityGranted else {
            Logger.error("ERROR: Accessibility not granted", category: .hotkey)
            throw HotkeyError.accessibilityNotGranted
        }

        // For modifier-only or Fn+key shortcuts, use CGEventTap
        // (Carbon RegisterEventHotKey doesn't support Fn key)
        if shortcut.isModifierOnly || shortcut.includesFnKey {
            Logger.info("Using EventTap for shortcut", category: .hotkey)
            try startEventTap()
        } else {
            Logger.info("Using Global HotKey for key combination", category: .hotkey)
            try startGlobalHotKey()
        }
    }

    public func stop() {
        Logger.debug("stop() called", category: .hotkey)
        if let hotKeyRef = hotKeyRef {
            Logger.debug("Unregistering hotkey", category: .hotkey)
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        // Disable and clean up EventTap
        if let tap = eventTap {
            Logger.debug("Disabling EventTap", category: .hotkey)
            CGEvent.tapEnable(tap: tap, enable: false)
            self.eventTap = nil
        }
        if let source = runLoopSource {
            Logger.debug("Removing runloop source", category: .hotkey)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            self.runLoopSource = nil
        }

        // Note: Event handlers are not removed per-type in Carbon
        // They persist until the app terminates
        eventHandlerInstalled = false

        isKeyDown = false
        isRecording = false
        Logger.debug("stop() complete", category: .hotkey)
    }

    /// Reset key state without stopping the hotkey manager.
    /// Called when recording is stopped by silence timeout to prevent duplicate keyUp events.
    public func resetKeyState() {
        Logger.debug("Resetting key state", category: .hotkey)
        isKeyDown = false
    }

    // MARK: - Global HotKey (for key combinations)

    private func startGlobalHotKey() throws {
        // Install event handler for hotkey events
        let hotKeyPressedSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let hotKeyReleasedSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))

        eventHandlerUPP = { (handlerCallRef, event, userData) -> OSStatus in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

            let eventKind = GetEventKind(event)
            Logger.debug("Event received: \(eventKind)", category: .hotkey)

            switch eventKind {
            case UInt32(kEventHotKeyPressed):
                Logger.debug("Hotkey PRESSED", category: .hotkey)
                manager.events.send(.keyDown)
            case UInt32(kEventHotKeyReleased):
                Logger.debug("Hotkey RELEASED", category: .hotkey)
                manager.events.send(.keyUp)
            default:
                break
            }

            return noErr
        }

        // Register event handler
        let handlerStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            eventHandlerUPP,
            2,
            [hotKeyPressedSpec, hotKeyReleasedSpec],
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )

        guard handlerStatus == noErr else {
            throw HotkeyError.registrationFailed
        }
        eventHandlerInstalled = true

        // Register the hotkey
        let modifierFlags = carbonModifiers(from: shortcut.flags)
        let keyCode = UInt32(shortcut.keyCode)

        let hotKeyID = EventHotKeyID(signature: OSType(fourCharCode("LIUY")), id: 1)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifierFlags,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )

        guard registerStatus == noErr else {
            throw HotkeyError.registrationFailed
        }
    }

    // MARK: - Event Tap (for modifier-only and Fn+key shortcuts)

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private func startEventTap() throws {
        // Monitor flagsChanged for modifier-only shortcuts
        // Monitor keyDown/keyUp for key combinations with Fn
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, _, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEventTapEvent(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw HotkeyError.tapCreationFailed
        }

        self.eventTap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleEventTapEvent(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch event.type {
        case .flagsChanged:
            return handleFlagsChangedEvent(event)
        case .keyDown, .keyUp:
            return handleKeyEvent(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleFlagsChangedEvent(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        // Only handle modifier-only shortcuts here (including Fn-only)
        guard shortcut.isModifierOnly else {
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let targetFlags = shortcut.flags
        let modifierMatch = flags.intersection(targetFlags) == targetFlags

        // Check Fn key if needed
        let fnKeyPressed = flags.contains(.maskSecondaryFn)
        let fnMatch = shortcut.includesFnKey == fnKeyPressed

        let allMatch = modifierMatch && fnMatch

        Logger.debug("Flags changed: allMatch=\(allMatch), isKeyDown=\(isKeyDown), isRecording=\(isRecording), flags=\(flags.rawValue)", category: .hotkey)

        if allMatch && !isKeyDown {
            // Prevent keyDown during recording, but allow keyUp
            guard !isRecording else {
                Logger.debug("Ignoring keyDown during recording", category: .hotkey)
                return Unmanaged.passUnretained(event)
            }
            isKeyDown = true
            Logger.debug("Sending keyDown from flagsChanged", category: .hotkey)
            events.send(.keyDown)
            return nil
        } else if !allMatch && isKeyDown {
            // KEYUP: Always process keyUp, even during recording
            // This ensures recording stops when user releases the shortcut
            Logger.debug("Sending keyUp from flagsChanged", category: .hotkey)
            isKeyDown = false
            events.send(.keyUp)
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleKeyEvent(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        // Don't process new keyDown during recording, but always allow keyUp
        // This ensures the recording stops when user releases the key
        if isRecording && event.type == .keyDown {
            return Unmanaged.passUnretained(event)
        }

        // Don't process modifier-only shortcuts here - they are handled by handleFlagsChangedEvent
        guard !shortcut.isModifierOnly else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // Check if this matches our shortcut
        let targetKeyCode = shortcut.keyCode
        let targetFlags = shortcut.flags

        // Check modifiers match
        let modifierMatch = flags.intersection(targetFlags) == targetFlags

        // Check Fn key if needed (only the actual Fn modifier flag, not F13)
        let fnKeyPressed = flags.contains(.maskSecondaryFn)
        let fnMatch = shortcut.includesFnKey == fnKeyPressed

        let keyMatch = keyCode == targetKeyCode

        if event.type == .keyDown {
            if modifierMatch && keyMatch && fnMatch {
                // Don't re-trigger if already recording (for EventTap-based shortcuts)
                if !isKeyDown {
                    isKeyDown = true
                    events.send(.keyDown)
                }
                return nil
            }
        } else if event.type == .keyUp {
            // On keyUp, only check if the key matches and we were in keyDown state
            // Don't check modifiers - user may have released them before the key
            if keyMatch && isKeyDown {
                isKeyDown = false
                events.send(.keyUp)
                return nil
            }
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Helpers

    private func carbonModifiers(from cgFlags: CGEventFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if cgFlags.contains(.maskCommand) { carbon |= UInt32(cmdKey) }
        if cgFlags.contains(.maskShift) { carbon |= UInt32(shiftKey) }
        if cgFlags.contains(.maskAlternate) { carbon |= UInt32(optionKey) }
        if cgFlags.contains(.maskControl) { carbon |= UInt32(controlKey) }
        return carbon
    }

    private func fourCharCode(_ string: String) -> FourCharCode {
        return string.utf16.reduce(0) { ($0 << 8) + UInt32($1) }
    }
}

public enum HotkeyError: Error, LocalizedError {
    case accessibilityNotGranted
    case tapCreationFailed
    case registrationFailed

    public var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            return "Accessibility permission required. Grant access in System Settings > Privacy & Security > Accessibility."
        case .tapCreationFailed:
            return "Failed to create event tap. Restart the app and try again."
        case .registrationFailed:
            return "Failed to register global hotkey. The shortcut may be in use by another application."
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    public static let hotkeyShortcutChanged = Notification.Name("hotkeyShortcutChanged")
    public static let hotkeyRecordingDidBegin = Notification.Name("hotkeyRecordingDidBegin")
    public static let hotkeyRecordingDidEnd = Notification.Name("hotkeyRecordingDidEnd")
}
