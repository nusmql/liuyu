# Design: Custom Shortcut Recorder

## Overview
Replace the preset-based "Activation Key" dropdown with a user-recordable modifier key combination system. Users can define their own shortcuts (e.g., ⌘+⌥, ⌃+⇧) through an intuitive "Record Shortcut" interface.

## Goals
- Replace preset dropdown with user-recordable modifier combinations
- Keep hold-to-record paradigm (press and hold to record voice)
- Live preview of captured shortcut during recording
- Persist shortcut configuration
- Validate against system/app conflicts with warnings
- Apply changes dynamically without app restart

## Constraints
- Modifier keys only (⌘, ⌥, ⌃, ⇧) - aligns with hold-to-record UX
- Must work with existing `CGEventTap` architecture
- No new dependencies (custom implementation)
- Apply changes dynamically (no restart required)

## Data Model

### RecordedShortcut

```swift
struct RecordedShortcut: Codable, Equatable {
    let modifierFlags: CGEventFlags

    /// Display string like "⌥⌘" or "⌃⇧"
    var displayString: String { ... }

    /// Validation: at least one modifier required
    var isValid: Bool { modifierFlags != [] }

    static var `default`: RecordedShortcut {
        RecordedShortcut(modifierFlags: .maskAlternate)
    }
}

// Migration from old preset system
extension RecordedShortcut {
    static func from(preset: HotkeyPreset) -> RecordedShortcut {
        RecordedShortcut(modifierFlags: preset.modifierFlag)
    }
}
```

### Storage

- Replace `UserDefaults` key `"hotkeyPreset"` with `"recordedShortcut"`
- Store as JSON-encoded data (Codable)
- Migration on first launch: convert existing preset to equivalent `RecordedShortcut`

## UI Components

### ShortcutRecorderView

SwiftUI wrapper around NSView providing the recording interface:

```
┌─────────────────────────────────────┐
│  Voice Input Activation Key         │
│                                     │
│  ┌─────────────────────────────┐    │
│  │   ⌥  (Right Option)         │ ✕  │  ← Normal state
│  └─────────────────────────────┘    │
│                                     │
│  ┌─────────────────────────────┐    │
│  │   Recording... Press keys   │    │  ← Recording state
│  └─────────────────────────────┘    │
│                                     │
│  [Record Shortcut]                  │
│                                     │
│  ⚠️ Warning: Common system shortcut  │  ← Warning state
└─────────────────────────────────────┘
```

**States:**
- **Idle:** Shows current shortcut with "×" to clear
- **Recording:** Red border, "Recording... Press modifier keys", captures live
- **Conflict:** Shows warning if shortcut conflicts with system

### ShortcutRecorder (NSView)

```swift
final class ShortcutRecorder: NSView {
    var onRecordingComplete: ((RecordedShortcut?) -> Void)?
    var isRecording: Bool = false

    /// Start recording: installs local event monitor
    func startRecording()

    /// Called when user releases all keys or presses Return
    private func finishRecording(flags: CGEventFlags)

    /// Cancel recording (Escape or click outside)
    private func cancelRecording()
}
```

**Key behaviors:**
- Recording starts when user clicks "Record Shortcut"
- Shows live key display as modifiers are pressed (e.g., shows "⌘" then "⌘⌥" as user adds modifiers)
- Press **Return** or release all keys to confirm
- Press **Escape** to cancel
- Click outside to cancel

## Recording Flow

1. User clicks "Record Shortcut"
2. Disable global hotkey temporarily (prevent triggering during recording)
3. Install local event monitor via `NSEvent.addLocalMonitorForEvents`
4. Listen for `.flagsChanged` events
5. Show live preview as user presses modifier keys
6. User releases keys or presses Return → capture final shortcut
7. Validate and check for conflicts
8. Notify settings to save
9. Re-enable global hotkey with new configuration

## HotkeyManager Integration

### Updated HotkeyManager

```swift
public class HotkeyManager {
    public var shortcut: RecordedShortcut = .default {
        didSet {
            // Restart tap with new shortcut immediately
            stop()
            try? start()
        }
    }

    private func handleEvent(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let flags = event.flags

        // Check if flags contain our configured modifiers
        let modifierMatch = flags.intersection(shortcut.modifierFlags) == shortcut.modifierFlags

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
}
```

### Notification for Settings Update

```swift
extension Notification.Name {
    static let hotkeyShortcutChanged = Notification.Name("hotkeyShortcutChanged")
}

// In AppDelegate
private func setupHotkeyRefresh() {
    NotificationCenter.default
        .publisher(for: .hotkeyShortcutChanged)
        .sink { [weak self] notification in
            guard let shortcut = notification.object as? RecordedShortcut else { return }
            self?.hotkeyManager.shortcut = shortcut
        }
        .store(in: &cancellables)
}
```

## Conflict Detection

### Conflict Levels

```swift
enum ConflictLevel {
    case none
    case warning  // e.g., uses common system shortcuts
    case critical // e.g., matches another Liuyu shortcut
}
```

### Conflict Checking

```swift
func checkConflict(flags: CGEventFlags) -> ConflictLevel {
    let modifiers = flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])

    // Critical: Check against other Liuyu shortcuts
    // (e.g., if we add more shortcuts in future)

    // Warning: Common system shortcuts
    let commonSystemShortcuts: [CGEventFlags] = [
        [.maskCommand, .maskShift, .maskAlternate],
        [.maskCommand, .maskControl],
    ]

    if commonSystemShortcuts.contains(where: { $0 == modifiers }) {
        return .warning
    }

    return .none
}
```

### UI Feedback

- **Warning (yellow):** "This shortcut may conflict with macOS system shortcuts"
- **Critical (red):** "Shortcut already used" (blocks saving)

Users can save with warning, but not with critical conflicts.

## Migration Plan

### Automatic Migration

```swift
func migrateHotkeySettings() {
    guard UserDefaults.standard.object(forKey: "hotkeyPreset") != nil,
          UserDefaults.standard.object(forKey: "recordedShortcut") == nil else {
        return
    }

    let presetRaw = UserDefaults.standard.string(forKey: "hotkeyPreset") ?? "Right Option"
    let preset = HotkeyPreset.from(rawValue: presetRaw)

    // Convert to new format
    let shortcut = RecordedShortcut(modifierFlags: preset.modifierFlag)
    UserDefaults.standard.set(try? JSONEncoder().encode(shortcut), forKey: "recordedShortcut")

    // Clean up old key
    UserDefaults.standard.removeObject(forKey: "hotkeyPreset")
}
```

## Testing Scenarios

1. **Fresh install:** Shows default shortcut (⌥), can record new one
2. **Migrate from preset:** Existing user sees their preset converted to recorded shortcut
3. **Record single modifier:** ⌥, ⌘, ⌃, or ⇧
4. **Record combination:** ⌘⌥, ⌃⇧, ⌘⌥⌃, etc.
5. **Cancel recording:** Press Escape, old shortcut preserved
6. **Clear shortcut:** Click ×, no shortcut set (show warning)
7. **Conflict warning:** Common system shortcut shows yellow warning
8. **Dynamic apply:** Change shortcut, immediately usable without restart

## Files to Modify

1. **New Files:**
   - `Sources/LiuyuLib/Hotkey/RecordedShortcut.swift` - Data model
   - `Sources/LiuyuLib/Settings/ShortcutRecorder.swift` - NSView recorder
   - `Sources/LiuyuLib/Settings/ShortcutRecorderView.swift` - SwiftUI wrapper

2. **Modified Files:**
   - `Sources/LiuyuLib/Hotkey/HotkeyManager.swift` - Use RecordedShortcut
   - `Sources/LiuyuLib/Hotkey/HotkeyPreset.swift` - Deprecate/remove
   - `Sources/LiuyuLib/Settings/HotkeySettingsView.swift` - New UI
   - `Sources/LiuyuLib/App/AppDelegate.swift` - Migration, dynamic refresh

## Implementation Notes

- Keep modifier-only restriction for consistent UX with hold-to-record
- Consider supporting both left/right modifier distinction in future (separate flags)
- Ensure accessibility: VoiceOver can announce current shortcut and recording state
- Add haptic feedback when recording starts/ends (optional polish)
