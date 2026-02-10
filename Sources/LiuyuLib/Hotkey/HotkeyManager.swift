// Sources/LiuyuLib/Hotkey/HotkeyManager.swift
import Foundation
import Combine
import CoreGraphics
import AppKit

public enum HotkeyEvent {
    case keyDown
    case keyUp
}

public class HotkeyManager {
    public let events = PassthroughSubject<HotkeyEvent, Never>()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isKeyDown = false

    /// The modifier flag to listen for. Default: right Option key.
    public var modifierFlag: CGEventFlags = .maskAlternate

    public init() {}

    /// Check if accessibility permission is granted.
    public static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt user for accessibility permission. Returns true if already granted.
    @discardableResult
    public static func requestAccessibilityPermission() -> Bool {
        // Use the string literal directly to avoid Swift 6 concurrency error
        // with the global `kAXTrustedCheckOptionPrompt` variable.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public func start() throws {
        guard Self.isAccessibilityGranted else {
            Self.requestAccessibilityPermission()
            throw HotkeyError.accessibilityNotGranted
        }

        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, _, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
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

        if flags.contains(modifierFlag) && !isKeyDown {
            isKeyDown = true
            events.send(.keyDown)
            return nil // suppress the event
        } else if !flags.contains(modifierFlag) && isKeyDown {
            isKeyDown = false
            events.send(.keyUp)
            return nil // suppress the event
        }

        return Unmanaged.passRetained(event)
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
