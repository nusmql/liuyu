// Sources/LiuyuLib/Hotkey/HotkeyManager.swift
import Foundation
import Combine
import CoreGraphics
import AppKit
import Carbon

public enum HotkeyEvent {
    case keyDown
    case keyUp
}

public enum HotkeyPreset: String, CaseIterable, Sendable {
    case optionKey = "Option Key"
    case rightOption = "Right Option"
    case rightCommand = "Right Command"

    public var modifierFlag: CGEventFlags {
        switch self {
        case .optionKey, .rightOption: return .maskAlternate
        case .rightCommand: return .maskCommand
        }
    }

    /// If set, only this specific keycode triggers the hotkey (for left/right distinction).
    public var specificKeycode: Int64? {
        switch self {
        case .optionKey: return nil
        case .rightOption: return 0x3D   // Right Option
        case .rightCommand: return 0x36  // Right Command
        }
    }

    public static func from(rawValue: String) -> HotkeyPreset {
        HotkeyPreset(rawValue: rawValue) ?? .rightOption
    }
}

public class HotkeyManager {
    public let events = PassthroughSubject<HotkeyEvent, Never>()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerUPP: EventHandlerUPP?
    private var isKeyDown = false
    private var eventHandlerInstalled = false

    public var shortcut: RecordedShortcut = .default {
        didSet {
            // Restart hotkey registration with new shortcut immediately
            stop()
            try? start()
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
        guard Self.isAccessibilityGranted else {
            throw HotkeyError.accessibilityNotGranted
        }

        // For modifier-only shortcuts, fall back to CGEventTap
        if shortcut.isModifierOnly {
            try startEventTap()
        } else {
            try startGlobalHotKey()
        }
    }

    public func stop() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        // Note: Event handlers are not removed per-type in Carbon
        // They persist until the app terminates
        eventHandlerInstalled = false

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

            switch eventKind {
            case UInt32(kEventHotKeyPressed):
                manager.events.send(.keyDown)
            case UInt32(kEventHotKeyReleased):
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

    // MARK: - Event Tap (for modifier-only shortcuts)

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private func startEventTap() throws {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

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
        let flags = event.flags
        let targetFlags = shortcut.flags
        let modifierMatch = flags.intersection(targetFlags) == targetFlags

        if modifierMatch && !isKeyDown {
            isKeyDown = true
            events.send(.keyDown)
            return nil
        } else if !modifierMatch && isKeyDown {
            isKeyDown = false
            events.send(.keyUp)
            return nil
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
