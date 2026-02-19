// Sources/LiuyuLib/Hotkey/RecordedShortcut.swift
import Foundation
import CoreGraphics

/// A recorded shortcut that stores modifier flags for hotkey activation.
public struct RecordedShortcut: Codable, Equatable, Sendable {
    /// The raw flag value for CGEventFlags.
    public let modifierFlags: CGEventFlags.RawValue

    /// Creates a new RecordedShortcut from CGEventFlags.
    /// - Parameter flags: The CGEventFlags to store.
    public init(flags: CGEventFlags) {
        self.modifierFlags = flags.rawValue
    }

    /// Returns the CGEventFlags computed from the stored raw value.
    public var flags: CGEventFlags {
        CGEventFlags(rawValue: modifierFlags)
    }

    /// Returns true if the shortcut has any modifier flags set.
    public var isValid: Bool {
        modifierFlags != 0
    }

    /// The default shortcut using Option key (maskAlternate).
    public static var `default`: RecordedShortcut {
        RecordedShortcut(flags: .maskAlternate)
    }

    /// Returns a display string with modifier symbols (e.g., "⌃⌥⇧⌘").
    public var displayString: String {
        var symbols: [String] = []
        let flags = self.flags

        if flags.contains(.maskControl) {
            symbols.append("⌃")
        }
        if flags.contains(.maskAlternate) {
            symbols.append("⌥")
        }
        if flags.contains(.maskShift) {
            symbols.append("⇧")
        }
        if flags.contains(.maskCommand) {
            symbols.append("⌘")
        }

        return symbols.joined()
    }
}

// MARK: - Migration Support

public extension RecordedShortcut {
    /// Creates a RecordedShortcut from an existing HotkeyPreset.
    /// - Parameter preset: The HotkeyPreset to migrate from.
    /// - Returns: A new RecordedShortcut with equivalent modifier flags.
    static func from(preset: HotkeyPreset) -> RecordedShortcut {
        RecordedShortcut(flags: preset.modifierFlag)
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
}
