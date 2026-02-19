# Custom Shortcut Recorder Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement a custom shortcut recorder that allows users to define their own modifier key combinations for voice activation, replacing the preset dropdown.

**Architecture:** Create a `RecordedShortcut` data model to replace `HotkeyPreset`, build a custom `ShortcutRecorder` NSView with local event monitoring for recording, update `HotkeyManager` to use dynamic shortcuts, and integrate with SwiftUI settings. Changes apply immediately via notification system.

**Tech Stack:** Swift, AppKit (NSView, NSEvent), Combine, CGEventTap, SwiftUI

---

## Prerequisites

- Review design doc: `docs/plans/2026-02-19-shortcut-recorder-design.md`
- Current hotkey system uses `CGEventTap` with `flagsChanged` events
- Existing `HotkeyPreset` enum with 3 presets: Option Key, Right Option, Right Command
- Settings stored in `@AppStorage` with UserDefaults

---

### Task 1: Create RecordedShortcut Data Model

**Files:**
- Create: `Sources/LiuyuLib/Hotkey/RecordedShortcut.swift`
- Reference: `Sources/LiuyuLib/Hotkey/HotkeyPreset.swift` (existing)

**Step 1: Write the model with Codable support**

```swift
import Foundation
import CoreGraphics

struct RecordedShortcut: Codable, Equatable {
    let modifierFlags: CGEventFlags.RawValue

    init(modifierFlags: CGEventFlags) {
        self.modifierFlags = modifierFlags.rawValue
    }

    var flags: CGEventFlags {
        CGEventFlags(rawValue: modifierFlags)
    }

    var isValid: Bool {
        flags != []
    }

    static var `default`: RecordedShortcut {
        RecordedShortcut(modifierFlags: .maskAlternate)
    }

    /// Display string like "⌥⌘" or "⌃⇧"
    var displayString: String {
        var parts: [String] = []
        let flags = self.flags

        if flags.contains(.maskControl) { parts.append("⌃") }
        if flags.contains(.maskOption) { parts.append("⌥") }
        if flags.contains(.maskShift) { parts.append("⇧") }
        if flags.contains(.maskCommand) { parts.append("⌘") }

        return parts.joined()
    }
}

// MARK: - Migration from HotkeyPreset

extension RecordedShortcut {
    static func from(preset: HotkeyPreset) -> RecordedShortcut {
        RecordedShortcut(modifierFlags: preset.modifierFlag)
    }
}

// MARK: - UserDefaults Support

extension RecordedShortcut {
    static func loadFromDefaults() -> RecordedShortcut {
        guard let data = UserDefaults.standard.data(forKey: "recordedShortcut"),
              let shortcut = try? JSONDecoder().decode(RecordedShortcut.self, from: data) else {
            return .default
        }
        return shortcut
    }

    func saveToDefaults() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "recordedShortcut")
        }
    }
}
```

**Step 2: Verify the file compiles**

Run: `swift build 2>&1 | head -20`
Expected: No errors

**Step 3: Commit**

```bash
git add Sources/LiuyuLib/Hotkey/RecordedShortcut.swift
git commit -m "feat: add RecordedShortcut data model with migration support"
```

---

### Task 2: Update HotkeyManager to Use RecordedShortcut

**Files:**
- Modify: `Sources/LiuyuLib/Hotkey/HotkeyManager.swift`

**Step 1: Update the HotkeyManager class**

Change from:
```swift
public var preset: HotkeyPreset = .rightOption
```

To:
```swift
public var shortcut: RecordedShortcut = .default {
    didSet {
        // Restart tap with new shortcut immediately
        stop()
        try? start()
    }
}
```

**Step 2: Update handleEvent method**

Replace the entire `handleEvent` method:

```swift
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
```

**Step 3: Verify compilation**

Run: `swift build 2>&1 | head -20`
Expected: No errors

**Step 4: Commit**

```bash
git add Sources/LiuyuLib/Hotkey/HotkeyManager.swift
git commit -m "refactor: HotkeyManager uses RecordedShortcut with dynamic updates"
```

---

### Task 3: Add Notification for Shortcut Changes

**Files:**
- Modify: `Sources/LiuyuLib/Hotkey/HotkeyManager.swift` (add notification name)

**Step 1: Add notification extension**

At the end of `HotkeyManager.swift`, add:

```swift
// MARK: - Notifications

extension Notification.Name {
    public static let hotkeyShortcutChanged = Notification.Name("hotkeyShortcutChanged")
}
```

**Step 2: Commit**

```bash
git add Sources/LiuyuLib/Hotkey/HotkeyManager.swift
git commit -m "feat: add hotkeyShortcutChanged notification"
```

---

### Task 4: Create ShortcutRecorder NSView

**Files:**
- Create: `Sources/LiuyuLib/Settings/ShortcutRecorder.swift`

**Step 1: Implement the recorder view**

```swift
import AppKit
import CoreGraphics

protocol ShortcutRecorderDelegate: AnyObject {
    func shortcutRecorderDidBeginRecording(_ recorder: ShortcutRecorder)
    func shortcutRecorder(_ recorder: ShortcutRecorder, didRecord shortcut: RecordedShortcut?)
}

final class ShortcutRecorder: NSView {
    weak var delegate: ShortcutRecorderDelegate?

    private var isRecording = false
    private var localMonitor: Any?
    private var currentFlags: CGEventFlags = []

    // MARK: - UI Components

    private let label: NSTextField = {
        let field = NSTextField(labelWithString: "Click to record")
        field.alignment = .center
        field.font = .systemFont(ofSize: 14, weight: .medium)
        return field
    }()

    private let clearButton: NSButton = {
        let button = NSButton(title: "×", target: nil, action: nil)
        button.bezelStyle = .circular
        button.font = .systemFont(ofSize: 14, weight: .bold)
        return button
    }()

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        label.translatesAutoresizingMaskIntoConstraints = false
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(clearButton)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 20),
            clearButton.heightAnchor.constraint(equalToConstant: 20)
        ])

        clearButton.target = self
        clearButton.action = #selector(clearTapped)

        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(viewClicked))
        addGestureRecognizer(clickGesture)
    }

    // MARK: - Public Methods

    func setShortcut(_ shortcut: RecordedShortcut?) {
        if let shortcut = shortcut, shortcut.isValid {
            label.stringValue = shortcut.displayString
            clearButton.isHidden = false
        } else {
            label.stringValue = "Click to record"
            clearButton.isHidden = true
        }
    }

    // MARK: - Actions

    @objc private func viewClicked() {
        guard !isRecording else { return }
        startRecording()
    }

    @objc private func clearTapped() {
        delegate?.shortcutRecorder(self, didRecord: nil)
    }

    // MARK: - Recording

    private func startRecording() {
        isRecording = true
        currentFlags = []
        label.stringValue = "Recording..."
        label.textColor = .systemRed
        clearButton.isHidden = true

        layer?.borderColor = NSColor.systemRed.cgColor

        delegate?.shortcutRecorderDidBeginRecording(self)

        // Install local monitor to capture modifier key events
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        // Also monitor key down to detect Return (confirm) or Escape (cancel)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 36 { // Return
                self?.finishRecording()
                return nil
            } else if event.keyCode == 53 { // Escape
                self?.cancelRecording()
                return nil
            }
            return event
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        currentFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Update display live
        let tempShortcut = RecordedShortcut(modifierFlags: currentFlags)
        if tempShortcut.isValid {
            label.stringValue = tempShortcut.displayString
        } else {
            label.stringValue = "Recording..."
        }
    }

    private func finishRecording() {
        guard isRecording else { return }

        cleanupRecording()

        let shortcut = RecordedShortcut(modifierFlags: currentFlags)
        delegate?.shortcutRecorder(self, didRecord: shortcut.isValid ? shortcut : nil)
    }

    private func cancelRecording() {
        guard isRecording else { return }

        cleanupRecording()
        delegate?.shortcutRecorder(self, didRecord: nil)
    }

    private func cleanupRecording() {
        isRecording = false
        label.textColor = .label
        layer?.borderColor = NSColor.separatorColor.cgColor

        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Cancel recording if view is removed from window
        if window == nil && isRecording {
            cancelRecording()
        }
    }
}
```

**Step 2: Verify compilation**

Run: `swift build 2>&1 | head -30`
Expected: No errors

**Step 3: Commit**

```bash
git add Sources/LiuyuLib/Settings/ShortcutRecorder.swift
git commit -m "feat: add ShortcutRecorder NSView for capturing modifier keys"
```

---

### Task 5: Create SwiftUI Wrapper

**Files:**
- Create: `Sources/LiuyuLib/Settings/ShortcutRecorderView.swift`

**Step 1: Implement SwiftUI wrapper**

```swift
import SwiftUI

struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var shortcut: RecordedShortcut?

    func makeNSView(context: Context) -> ShortcutRecorder {
        let recorder = ShortcutRecorder()
        recorder.delegate = context.coordinator
        recorder.setShortcut(shortcut)
        return recorder
    }

    func updateNSView(_ nsView: ShortcutRecorder, context: Context) {
        nsView.setShortcut(shortcut)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, ShortcutRecorderDelegate {
        var parent: ShortcutRecorderView

        init(_ parent: ShortcutRecorderView) {
            self.parent = parent
        }

        func shortcutRecorderDidBeginRecording(_ recorder: ShortcutRecorder) {
            // Disable global hotkey during recording
            NotificationCenter.default.post(name: .disableGlobalHotkey, object: nil)
        }

        func shortcutRecorder(_ recorder: ShortcutRecorder, didRecord shortcut: RecordedShortcut?) {
            // Re-enable global hotkey
            NotificationCenter.default.post(name: .enableGlobalHotkey, object: nil)

            // Update binding
            parent.shortcut = shortcut

            // Save and notify
            shortcut?.saveToDefaults()
            NotificationCenter.default.post(name: .hotkeyShortcutChanged, object: shortcut)
        }
    }
}

// MARK: - Notifications for enabling/disabling global hotkey

extension Notification.Name {
    static let disableGlobalHotkey = Notification.Name("disableGlobalHotkey")
    static let enableGlobalHotkey = Notification.Name("enableGlobalHotkey")
}
```

**Step 2: Verify compilation**

Run: `swift build 2>&1 | head -20`
Expected: No errors

**Step 3: Commit**

```bash
git add Sources/LiuyuLib/Settings/ShortcutRecorderView.swift
git commit -m "feat: add ShortcutRecorderView SwiftUI wrapper"
```

---

### Task 6: Update HotkeySettingsView

**Files:**
- Modify: `Sources/LiuyuLib/Settings/HotkeySettingsView.swift`

**Step 1: Replace entire file**

```swift
import SwiftUI

struct HotkeySettingsView: View {
    @State private var shortcut: RecordedShortcut? = RecordedShortcut.loadFromDefaults()
    @State private var conflictWarning: String? = nil

    var body: some View {
        Form {
            Section("Voice Input Activation") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Activation Shortcut")
                        .font(.headline)

                    Text("Press and hold this shortcut to start recording voice. Release to transcribe.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        ShortcutRecorderView(shortcut: $shortcut)
                            .frame(height: 36)
                            .onChange(of: shortcut) { _, newValue in
                                checkConflicts(for: newValue)
                            }

                        if let warning = conflictWarning {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle")
                                Text(warning)
                            }
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400)
    }

    private func checkConflicts(for shortcut: RecordedShortcut?) {
        guard let shortcut = shortcut else {
            conflictWarning = nil
            return
        }

        let flags = shortcut.flags
        let modifiers = flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])

        // Check for common system shortcuts
        let commonSystemShortcuts: [CGEventFlags] = [
            [.maskCommand, .maskShift, .maskAlternate],
            [.maskCommand, .maskControl],
            [.maskCommand, .maskShift, .maskControl],
        ]

        if commonSystemShortcuts.contains(where: { $0 == modifiers }) {
            conflictWarning = "May conflict with system shortcuts"
        } else {
            conflictWarning = nil
        }
    }
}
```

**Step 2: Verify compilation**

Run: `swift build 2>&1 | head -20`
Expected: No errors

**Step 3: Commit**

```bash
git add Sources/LiuyuLib/Settings/HotkeySettingsView.swift
git commit -m "feat: update HotkeySettingsView with custom shortcut recorder"
```

---

### Task 7: Update AppDelegate for Dynamic Updates

**Files:**
- Modify: `Sources/LiuyuLib/App/AppDelegate.swift`

**Step 1: Update applyHotkeyPreset to use RecordedShortcut**

Replace:
```swift
private func applyHotkeyPreset() {
    let presetRaw = UserDefaults.standard.string(forKey: "hotkeyPreset") ?? HotkeyPreset.rightOption.rawValue
    hotkeyManager.preset = HotkeyPreset.from(rawValue: presetRaw)
}
```

With:
```swift
private func applyHotkeyShortcut() {
    // Check if migration needed
    migrateHotkeySettingsIfNeeded()

    hotkeyManager.shortcut = RecordedShortcut.loadFromDefaults()
}
```

**Step 2: Add migration function**

Add to AppDelegate:

```swift
private func migrateHotkeySettingsIfNeeded() {
    guard UserDefaults.standard.object(forKey: "hotkeyPreset") != nil,
          UserDefaults.standard.object(forKey: "recordedShortcut") == nil else {
        return
    }

    let presetRaw = UserDefaults.standard.string(forKey: "hotkeyPreset") ?? "Right Option"
    let preset = HotkeyPreset.from(rawValue: presetRaw)

    // Convert to new format
    let shortcut = RecordedShortcut.from(preset: preset)
    shortcut.saveToDefaults()

    // Clean up old key
    UserDefaults.standard.removeObject(forKey: "hotkeyPreset")

    print("[Liuyu] Migrated hotkey preset to new shortcut format")
}
```

**Step 3: Update setupHotkeySubscription to listen for changes**

After `setupHotkeySubscription()`, add:

```swift
private func setupHotkeyRefresh() {
    NotificationCenter.default
        .publisher(for: .hotkeyShortcutChanged)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] notification in
            guard let shortcut = notification.object as? RecordedShortcut else { return }
            self?.hotkeyManager.shortcut = shortcut
        }
        .store(in: &cancellables)

    // Listen for disable/enable during recording
    NotificationCenter.default
        .publisher(for: .disableGlobalHotkey)
        .sink { [weak self] _ in
            self?.hotkeyManager.stop()
        }
        .store(in: &cancellables)

    NotificationCenter.default
        .publisher(for: .enableGlobalHotkey)
        .sink { [weak self] _ in
            try? self?.hotkeyManager.start()
        }
        .store(in: &cancellables)
}
```

**Step 4: Update applicationDidFinishLaunching**

Change:
```swift
applyHotkeyPreset()
```

To:
```swift
applyHotkeyShortcut()
setupHotkeyRefresh()
```

**Step 5: Verify compilation**

Run: `swift build 2>&1 | head -30`
Expected: No errors

**Step 6: Commit**

```bash
git add Sources/LiuyuLib/App/AppDelegate.swift
git commit -m "feat: AppDelegate supports dynamic shortcut updates and migration"
```

---

### Task 8: Build and Test

**Step 1: Full build**

Run: `swift build`
Expected: Build successful

**Step 2: Run tests if available**

Run: `swift test 2>&1 || echo "No tests configured"`

**Step 3: Commit any final changes**

```bash
git status
git add -A
git commit -m "feat: complete custom shortcut recorder implementation" || echo "No changes to commit"
```

---

## Manual Testing Checklist

Test these scenarios after building:

- [ ] **Fresh install:** Delete app preferences, launch, verify default ⌥ shortcut works
- [ ] **Open settings:** Settings > Hotkey shows current shortcut
- [ ] **Record single modifier:** Click Record, press ⌘, release, verify ⌘ shows
- [ ] **Record combination:** Record ⌘⌥, verify both show
- [ ] **Cancel recording:** Click Record, press Escape, verify old shortcut preserved
- [ ] **Clear shortcut:** Click ×, verify "Click to record" shows
- [ ] **Conflict warning:** Record ⌘⇧⌥, verify warning appears
- [ ] **Dynamic apply:** Change shortcut in settings, immediately test in another app
- [ ] **Migration:** Set old preset in UserDefaults, launch app, verify migrated correctly
- [ ] **Hold to record:** Hold new shortcut, verify recording starts, release, verify transcription

---

## Files Summary

**New Files:**
- `Sources/LiuyuLib/Hotkey/RecordedShortcut.swift`
- `Sources/LiuyuLib/Settings/ShortcutRecorder.swift`
- `Sources/LiuyuLib/Settings/ShortcutRecorderView.swift`

**Modified Files:**
- `Sources/LiuyuLib/Hotkey/HotkeyManager.swift`
- `Sources/LiuyuLib/Settings/HotkeySettingsView.swift`
- `Sources/LiuyuLib/App/AppDelegate.swift`

**Deprecated (keep for migration):**
- `Sources/LiuyuLib/Hotkey/HotkeyPreset.swift`
