// Sources/LiuyuLib/Hotkey/HotkeyManager.swift
import Foundation
import Combine
import CoreGraphics
import AppKit

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

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isKeyDown = false

    public var shortcut: RecordedShortcut = .default {
        didSet {
            // Restart tap with new shortcut immediately
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
        // Use the string literal directly to avoid Swift 6 concurrency error
        // with the global `kAXTrustedCheckOptionPrompt` variable.
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public func start() throws {
        guard Self.isAccessibilityGranted else {
            throw HotkeyError.accessibilityNotGranted
        }

        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, _, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEvent(event)
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

    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isKeyDown = false
    }

    private func handleEvent(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let flags = event.flags

        // Check if our configured modifiers are present
        let targetFlags = shortcut.flags
        let modifierMatch = flags.intersection(targetFlags) == targetFlags

        if modifierMatch && !isKeyDown {
            isKeyDown = true
            events.send(.keyDown)
            return nil // suppress the event
        } else if !modifierMatch && isKeyDown {
            isKeyDown = false
            events.send(.keyUp)
            return nil // suppress the event
        }

        return Unmanaged.passUnretained(event)
    }
}

public enum HotkeyError: Error, LocalizedError {
    case accessibilityNotGranted
    case tapCreationFailed

    public var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            return "Accessibility permission required. Grant access in System Settings > Privacy & Security > Accessibility."
        case .tapCreationFailed:
            return "Failed to create event tap. Restart the app and try again."
        }
    }
}
