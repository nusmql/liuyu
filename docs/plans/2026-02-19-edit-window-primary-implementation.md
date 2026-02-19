# Edit Window as Primary Workflow Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Change the recording workflow so the Edit window opens automatically after releasing the shortcut key, instead of showing the result in the floating panel.

**Architecture:** Simplify PanelState to only handle recording (no result state), modify AppDelegate to hide panel and open Edit window after transcription, update EditView to show transcribed text on open.

**Tech Stack:** Swift, SwiftUI, AppKit, Combine

---

## Prerequisites

- Review design doc: `docs/plans/2026-02-19-edit-window-primary-workflow.md`
- Current PanelState has: hidden, recording, processing, result
- Current flow: shortcut → panel (recording) → panel (result) → user clicks → insert
- New flow: shortcut → panel (recording) → hide panel → Edit window opens → user edits → insert

---

### Task 1: Remove .result state from PanelState

**Files:**
- Modify: `Sources/LiuyuLib/UI/PanelViewModel.swift`

**Step 1: Remove .result case from PanelState enum**

```swift
public enum PanelState {
    case hidden
    case recording(audioLevel: Float)
    case processing
}
```

**Step 2: Remove showResult method from PanelViewModel**

Remove:
```swift
public func showResult(_ text: String) {
    state = .result(text: text)
    startAutoDismiss()
}
```

**Step 3: Remove result-related logic from PanelViewModel**

Remove:
- `autoDismissTimer` property
- `autoDismissInterval` constant
- `startAutoDismiss()` method
- `cancelAutoDismiss()` method (keep timer invalidation in `showRecording`)
- Remove `cancelAutoDismiss()` call from `showProcessing`

**Step 4: Verify compilation**

Run: `swift build 2>&1 | head -20`
Expected: No errors

**Step 5: Commit**

```bash
git add Sources/LiuyuLib/UI/PanelViewModel.swift
git commit -m "refactor: remove .result state from PanelViewModel"
```

---

### Task 2: Update PanelContentView to remove ResultView

**Files:**
- Modify: `Sources/LiuyuLib/UI/PanelContentView.swift`

**Step 1: Read current file to understand structure**

**Step 2: Remove ResultView from body**

Current structure is:
```swift
var body: some View {
    ZStack {
        switch viewModel.state {
        case .hidden:
            EmptyView()
        case .recording(let level):
            RecordingView(audioLevel: level)
        case .processing:
            ProcessingView()
        case .result(let text):
            ResultView(text: text)  // REMOVE THIS
        }
    }
}
```

Change to:
```swift
var body: some View {
    ZStack {
        switch viewModel.state {
        case .hidden:
            EmptyView()
        case .recording(let level):
            RecordingView(audioLevel: level)
        case .processing:
            ProcessingView()
        }
    }
}
```

**Step 3: Remove ResultView struct if defined in same file**

**Step 4: Verify compilation**

Run: `swift build 2>&1 | head -20`
Expected: No errors

**Step 5: Commit**

```bash
git add Sources/LiuyuLib/UI/PanelContentView.swift
git commit -m "refactor: remove ResultView from PanelContentView"
```

---

### Task 3: Update EditView to accept initial text

**Files:**
- Modify: `Sources/LiuyuLib/Edit/EditView.swift`

**Step 1: Add initialText parameter to EditView**

```swift
struct EditView: View {
    let initialText: String
    let onInsert: (String) -> Void
    let onClose: () -> Void

    @State private var text: String
    @State private var isRecording = false

    init(initialText: String = "", onInsert: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.initialText = initialText
        self.onInsert = onInsert
        self.onClose = onClose
        _text = State(initialValue: initialText)
    }
```

**Step 2: Verify compilation**

Run: `swift build 2>&1 | head -20`
Expected: No errors

**Step 3: Commit**

```bash
git add Sources/LiuyuLib/Edit/EditView.swift
git commit -m "feat: EditView accepts initialText parameter"
```

---

### Task 4: Update EditWindowController to show with text

**Files:**
- Modify: `Sources/LiuyuLib/Edit/EditWindowController.swift`

**Step 1: Add showWithText method**

```swift
func showWithText(_ text: String, onInsert: @escaping (String) -> Void) {
    // Capture context before showing
    let liuyuBundleID = Bundle.main.bundleIdentifier
    let frontApp = NSWorkspace.shared.frontmostApplication
    if frontApp?.bundleIdentifier != liuyuBundleID {
        previousApp = frontApp
    }
    previousMouseLocation = NSEvent.mouseLocation

    let isNew = (window == nil)
    let window = self.window ?? NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.title = "LiuYu"
    window.minSize = NSSize(width: 400, height: 150)
    if isNew { window.center() }

    // Set content with initial text
    let capturedApp = previousApp
    let capturedMouse = previousMouseLocation
    window.contentView = NSHostingView(
        rootView: EditView(
            initialText: text,
            onInsert: { [weak self] insertedText in
                self?.performInsert(text: insertedText, app: capturedApp, mouseLocation: capturedMouse)
                onInsert(insertedText)
            },
            onClose: { [weak self] in self?.close() }
        )
    )
    window.isReleasedWhenClosed = false
    window.delegate = self

    NSApp.setActivationPolicy(.regular)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    self.window = window
}
```

**Step 2: Update existing show() method to use empty string**

```swift
func show() {
    showWithText("") { _ in }
}
```

**Step 3: Verify compilation**

Run: `swift build 2>&1 | head -20`
Expected: No errors

**Step 4: Commit**

```bash
git add Sources/LiuyuLib/Edit/EditWindowController.swift
git commit -m "feat: EditWindowController can show with pre-filled text"
```

---

### Task 5: Update AppDelegate workflow

**Files:**
- Modify: `Sources/LiuyuLib/App/AppDelegate.swift`

**Step 1: Remove panel action handling for result buttons**

Current `handlePanelAction` handles .insert, .copy, .clear, .cancel

Simplify to:
```swift
private func handlePanelAction(_ action: PanelAction) {
    // Only handle cancel from panel (user cancelled during recording)
    if case .cancel = action {
        cleanupCurrentAudio()
        panelController.hide()
    }
}
```

**Step 2: Update stopRecordingAndTranscribe to open Edit window**

Current:
```swift
private func stopRecordingAndTranscribe() {
    guard isRecording else { return }
    isRecording = false

    guard let audioURL = recordingController.stop() else {
        panelController.viewModel.showResult("Error: No audio recorded.")
        return
    }

    currentAudioFileURL = audioURL
    panelController.viewModel.showProcessing()
    panelController.resize(width: 280, height: 80)

    Task {
        await transcribe(audioURL: audioURL)
    }
}
```

New:
```swift
private func stopRecordingAndTranscribe() {
    guard isRecording else { return }
    isRecording = false

    // Stop recording and hide panel immediately
    guard let audioURL = recordingController.stop() else {
        panelController.hide()
        showErrorNotification("No audio recorded")
        return
    }

    currentAudioFileURL = audioURL
    panelController.viewModel.showProcessing()

    Task {
        let text = await transcribeForEditWindow(audioURL: audioURL)
        await MainActor.run {
            panelController.hide()
            editController.showWithText(text) { [weak self] _ in
                self?.cleanupCurrentAudio()
            }
        }
    }
}
```

**Step 3: Create transcribeForEditWindow method**

```swift
private func transcribeForEditWindow(audioURL: URL) async -> String {
    let feature = providerStore.loadFeatureConfig()

    guard let sttAssignment = feature.sttPrimary else {
        return "Error: No STT model configured. Open Settings."
    }

    // Try primary
    let (primaryText, primaryError) = await tryTranscribe(assignment: sttAssignment, audioURL: audioURL)
    if let primaryText {
        return primaryText
    }

    // Try fallback
    if let fallback = feature.sttFallback {
        let (fallbackText, _) = await tryTranscribe(assignment: fallback, audioURL: audioURL)
        if let fallbackText {
            return fallbackText
        }
    }

    return primaryError ?? "Transcription failed. Check Settings."
}
```

**Step 4: Add error notification helper**

```swift
private func showErrorNotification(_ message: String) {
    let notification = NSUserNotification()
    notification.title = "Liuyu"
    notification.informativeText = message
    NSUserNotificationCenter.default.deliver(notification)
}
```

**Step 5: Update handleKeyUp for minimum duration**

```swift
private func handleKeyUp() {
    let elapsed = Date().timeIntervalSince(recordingStartTime ?? Date())

    if elapsed < minimumRecordingDuration {
        // Too short - cancel and show brief notification
        panelController.hide()
        isRecording = false
        cleanupCurrentAudio()
        showErrorNotification("Recording too short")
        return
    }

    stopRecordingAndTranscribe()
}
```

**Step 6: Remove insertText and simulatePaste (now handled by Edit window)**

Keep `performInsert` in EditWindowController which already handles this.

**Step 7: Verify compilation**

Run: `swift build 2>&1 | head -30`
Expected: No errors

**Step 8: Commit**

```bash
git add Sources/LiuyuLib/App/AppDelegate.swift
git commit -m "feat: Edit window opens automatically after recording"
```

---

### Task 6: Remove unused PanelAction cases

**Files:**
- Modify: `Sources/LiuyuLib/UI/PanelViewModel.swift`
- Modify: `Sources/LiuyuLib/App/AppDelegate.swift` (if needed)

**Step 1: Simplify PanelAction enum**

```swift
public enum PanelAction {
    case cancel
}
```

**Step 2: Update PanelViewModel to only send .cancel**

Remove insertText, copyText, clearResult methods, keep only cancel.

**Step 3: Update AppDelegate to handle only .cancel**

```swift
private func handlePanelAction(_ action: PanelAction) {
    cleanupCurrentAudio()
    isRecording = false
}
```

**Step 4: Verify compilation**

Run: `swift build 2>&1 | head -20`
Expected: No errors

**Step 5: Commit**

```bash
git add Sources/LiuyuLib/UI/PanelViewModel.swift Sources/LiuyuLib/App/AppDelegate.swift
git commit -m "refactor: simplify PanelAction to only .cancel"
```

---

### Task 7: Build and Test

**Step 1: Full build**

Run: `swift build`
Expected: Build successful

**Step 2: Test scenarios**

- [ ] Press & hold shortcut → panel shows recording
- [ ] Speak → audio level animates
- [ ] Release → panel hides, Edit window opens
- [ ] Edit text → click Insert → text inserted to previous app
- [ ] Press shortcut and release quickly (< 0.3s) → shows "too short" notification
- [ ] Cancel during recording → panel hides, no Edit window
- [ ] Transcription error → Edit window opens with error message

**Step 3: Commit any fixes**

```bash
git add -A
git commit -m "fix: address edge cases in new workflow" || echo "No changes"
```

---

## Files Summary

**Modified Files:**
- `Sources/LiuyuLib/UI/PanelViewModel.swift` - Remove result state
- `Sources/LiuyuLib/UI/PanelContentView.swift` - Remove ResultView
- `Sources/LiuyuLib/Edit/EditView.swift` - Accept initialText
- `Sources/LiuyuLib/Edit/EditWindowController.swift` - Add showWithText
- `Sources/LiuyuLib/App/AppDelegate.swift` - New workflow

**Potentially Removed:**
- `Sources/LiuyuLib/UI/ResultView.swift` (if separate file)

---

## Manual Testing Checklist

- [ ] Recording flow: shortcut → panel → release → Edit window
- [ ] Audio level visualization during recording
- [ ] Processing state shown briefly
- [ ] Edit window opens with transcribed text
- [ ] Edit window text is editable
- [ ] Insert button pastes text to previous app
- [ ] Cancel button closes Edit window without inserting
- [ ] Short recording (< 0.3s) shows error, no Edit window
- [ ] Menu bar "Open..." still works (blank Edit window)
- [ ] Re-record button in Edit window works
