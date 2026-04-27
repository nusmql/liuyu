import AppKit
import CoreGraphics

public enum ShortcutMatcher {
    private static let cgModifierMask: CGEventFlags = [
        .maskCommand,
        .maskShift,
        .maskAlternate,
        .maskControl
    ]

    public static func normalizedCGFlags(_ flags: CGEventFlags) -> CGEventFlags {
        flags.intersection(cgModifierMask)
    }

    public static func containsFn(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskSecondaryFn)
    }

    public static func matches(
        cgFlags: CGEventFlags,
        keyCode: UInt16?,
        shortcut: RecordedShortcut
    ) -> Bool {
        guard shortcut.isValid else { return false }

        let modifiersMatch = normalizedCGFlags(cgFlags) == normalizedCGFlags(shortcut.flags)
        let fnMatches = shortcut.includesFnKey == containsFn(cgFlags)

        if shortcut.isModifierOnly {
            return modifiersMatch && fnMatches && keyCode == nil
        }

        return modifiersMatch && fnMatches && keyCode == shortcut.keyCode
    }

    public static func normalizedEventFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.command, .shift, .option, .control, .function])
    }

    public static func matches(
        eventFlags: NSEvent.ModifierFlags,
        keyCode: UInt16?,
        shortcut: RecordedShortcut
    ) -> Bool {
        guard shortcut.isValid else { return false }

        var target: NSEvent.ModifierFlags = []
        let flags = shortcut.flags
        if flags.contains(.maskCommand) { target.insert(.command) }
        if flags.contains(.maskShift) { target.insert(.shift) }
        if flags.contains(.maskAlternate) { target.insert(.option) }
        if flags.contains(.maskControl) { target.insert(.control) }
        if shortcut.includesFnKey { target.insert(.function) }

        let modifiersMatch = normalizedEventFlags(eventFlags) == target

        if shortcut.isModifierOnly {
            return modifiersMatch && keyCode == nil
        }

        return modifiersMatch && keyCode == shortcut.keyCode
    }
}
