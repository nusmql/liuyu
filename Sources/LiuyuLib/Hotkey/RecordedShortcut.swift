// Sources/LiuyuLib/Hotkey/RecordedShortcut.swift
import Foundation
import CoreGraphics
import AppKit

/// A recorded shortcut that stores modifier flags, keycode, and fn key state for hotkey activation.
public struct RecordedShortcut: Codable, Equatable, Sendable {
    /// The raw flag value for CGEventFlags.
    public let modifierFlags: CGEventFlags.RawValue
    /// The keycode for the non-modifier key (0 if only modifiers).
    public let keyCode: UInt16
    /// Whether the Fn key is part of the shortcut.
    public let includesFnKey: Bool

    /// Creates a new RecordedShortcut from CGEventFlags, keycode, and fn key state.
    /// - Parameters:
    ///   - flags: The CGEventFlags to store.
    ///   - keyCode: The keycode for the non-modifier key (default 0 for modifier-only).
    ///   - includesFnKey: Whether the Fn key is part of the shortcut.
    public init(flags: CGEventFlags, keyCode: UInt16 = 0, includesFnKey: Bool = false) {
        self.modifierFlags = flags.rawValue
        self.keyCode = keyCode
        self.includesFnKey = includesFnKey
    }

    /// Returns the CGEventFlags computed from the stored raw value.
    public var flags: CGEventFlags {
        CGEventFlags(rawValue: modifierFlags)
    }

    /// Returns true if the shortcut has any modifier flags set or a keycode.
    public var isValid: Bool {
        modifierFlags != 0 || keyCode != 0
    }

    /// Returns true if this is a modifier-only shortcut (no specific key).
    public var isModifierOnly: Bool {
        keyCode == 0 && !includesFnKey
    }

    /// The default shortcut using Option key (maskAlternate).
    public static var `default`: RecordedShortcut {
        RecordedShortcut(flags: .maskAlternate, keyCode: 0, includesFnKey: false)
    }

    /// Returns a display string with modifier symbols and key (e.g., "⌃⌥A" or "Fn ⌥").
    public var displayString: String {
        var parts: [String] = []

        // Add Fn key first if present
        if includesFnKey {
            parts.append("Fn")
        }

        let flags = self.flags

        if flags.contains(.maskControl) {
            parts.append("⌃")
        }
        if flags.contains(.maskAlternate) {
            parts.append("⌥")
        }
        if flags.contains(.maskShift) {
            parts.append("⇧")
        }
        if flags.contains(.maskCommand) {
            parts.append("⌘")
        }

        // Add the key character if not modifier-only
        if keyCode != 0 {
            if let char = KeyCodeMap.string(for: keyCode) {
                parts.append(char.uppercased())
            }
        }

        return parts.joined(separator: " ")
    }
}

// MARK: - Key Code Mapping

/// Maps key codes to their display strings
public enum KeyCodeMap {
    private static let map: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 10: "B", 11: "Q", 12: "W", 13: "E", 14: "R",
        15: "Y", 16: "T", 17: "1", 18: "2", 19: "3", 20: "4", 21: "6",
        22: "5", 23: "=", 24: "9", 25: "7", 26: "-", 27: "8", 28: "0",
        29: "]", 30: "O", 31: "U", 32: "[", 33: "I", 34: "P", 35: "Return",
        36: "L", 37: "J", 38: "'", 39: "K", 40: ";", 41: "\\", 42: ",",
        43: "/", 44: "N", 45: "M", 46: ".", 47: "Tab", 48: "Space",
        49: "`", 50: "Delete", 51: "Return", 52: "Escape", 53: "Escape",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        103: "F11", 105: "F13", 106: "F16", 107: "F14", 109: "F10",
        111: "F12", 113: "F15", 114: "Help", 115: "Home", 116: "PgUp",
        117: "Delete", 118: "F4", 119: "End", 120: "F2", 121: "PgDn",
        122: "F1", 123: "Left", 124: "Right", 125: "Down", 126: "Up",
        0x52: "Keypad 0", 0x53: "Keypad 1", 0x54: "Keypad 2", 0x55: "Keypad 3",
        0x56: "Keypad 4", 0x57: "Keypad 5", 0x58: "Keypad 6", 0x59: "Keypad 7",
        0x5B: "Keypad 8", 0x5C: "Keypad 9",
        63: "Fn"  // Left Fn key on Mac keyboards
    ]

    public static func string(for keyCode: UInt16) -> String? {
        return map[keyCode]
    }
}

// MARK: - UserDefaults Persistence

public extension RecordedShortcut {
    /// The UserDefaults key for storing the recorded shortcut.
    private static let defaultsKey = "recordedShortcut"

    /// Loads a RecordedShortcut from UserDefaults, or returns the default if none exists.
    /// - Returns: The stored RecordedShortcut, or `.default` if not found or invalid.
    static func loadFromDefaults() -> RecordedShortcut {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            return .default
        }

        do {
            let shortcut = try JSONDecoder().decode(RecordedShortcut.self, from: data)
            return shortcut
        } catch {
            return .default
        }
    }

    /// Saves this RecordedShortcut to UserDefaults.
    func saveToDefaults() {
        do {
            let data = try JSONEncoder().encode(self)
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        } catch {
            // Silently fail - the shortcut will revert to default on next load
        }
    }

    // MARK: - Edit Window Record Shortcut Persistence

    private static let editRecordDefaultsKey = "editRecordShortcut"

    /// The default edit record shortcut: Cmd+R
    static var defaultEditRecordShortcut: RecordedShortcut {
        RecordedShortcut(flags: .maskCommand, keyCode: 15, includesFnKey: false) // Cmd+R
    }

    /// Loads the edit record shortcut from UserDefaults, or returns Cmd+R if none exists.
    static func loadEditRecordShortcut() -> RecordedShortcut {
        guard let data = UserDefaults.standard.data(forKey: editRecordDefaultsKey) else {
            return .defaultEditRecordShortcut
        }

        do {
            let shortcut = try JSONDecoder().decode(RecordedShortcut.self, from: data) 
            return shortcut
        } catch {
            return .defaultEditRecordShortcut
        }
    }

    /// Saves this RecordedShortcut as the edit record shortcut.
    func saveEditRecordShortcut() {
        do {
            let data = try JSONEncoder().encode(self)
            UserDefaults.standard.set(data, forKey: Self.editRecordDefaultsKey)
        } catch {
            // Silently fail
        }
    }
}
