# Design: Edit Window as Primary Workflow

## Overview
Change the user workflow so the Edit window opens automatically after recording, replacing the current two-step flow (floating panel result → optional Edit window).

## Current Workflow (Problematic)
1. Press & hold shortcut → Floating panel shows recording animation
2. Release shortcut → Floating panel shows result with Insert/Copy/Cancel buttons
3. User clicks button in panel → Text inserted
4. Menu bar "Open..." → Opens Edit window (separate, inconsistent flow)

**Issues:**
- Two separate workflows for shortcut vs menu
- Limited editing capability in floating panel
- Panel stays visible until user interacts
- Edit window is disconnected from recording flow

## New Workflow (Simplified)
1. Press & hold shortcut → Floating panel shows recording animation
2. Speak → Audio level visualization updates
3. Release shortcut →
   - Floating panel immediately hides
   - Processing indicator (brief)
   - Edit window opens with transcribed text
4. User reviews/edits text in Edit window
5. Click Insert → Edit window closes, text inserted into previous app

## Benefits
- **Consistent workflow** - Always use Edit window for text review
- **Better editing** - Full text editor with cursor, selection, etc.
- **Simpler state management** - Panel only handles recording state
- **Clear mental model** - Shortcut = "record and open editor"

## Design Decisions

### 1. Error Handling
If transcription fails:
- Edit window still opens
- Shows error message in place of text
- User can retry recording from Edit window (existing mic button)

### 2. Minimum Recording Duration
Keep 0.3s minimum, but with a difference:
- If released too early → Show brief "Recording too short" notification
- Don't open Edit window for very short recordings (accidental triggers)

### 3. Menu Bar "Open..." Behavior
Keep existing behavior:
- Opens Edit window in blank state (no recording)
- User can type or click mic to record inline

### 4. Panel State Changes
Remove `.result` state from `PanelState` enum:
```swift
public enum PanelState {
    case hidden
    case recording(audioLevel: Float)
    case processing  // Optional brief state
}
```

## Files to Modify

1. **PanelState.swift** - Remove `.result` state
2. **PanelViewModel.swift** - Remove result-related methods
3. **PanelContentView.swift** - Remove result view
4. **AppDelegate.swift** -
   - On key release: hide panel → transcribe → open Edit window
   - Remove panel action handlers for result buttons
5. **EditWindowController.swift** -
   - Add method to show with pre-filled text
   - Handle transcription errors in Edit view

## UI Mockup

### Floating Panel (Recording Only)
```
┌─────────────────┐
│  🎤 Recording   │  ← Audio waveform animation
│     ⌥           │  ← Shows current shortcut
└─────────────────┘
```

### Edit Window (Auto-opens)
```
┌──────────────────────────────────┐
│ LiuYu                            │
├──────────────────────────────────┤
│                                  │
│  [Transcribed text here...]      │  ← Editable text area
│                                  │
│  🎤                              │  ← Re-record button
│                                  │
├──────────────────────────────────┤
│  [Cancel]    [Copy]  [Insert]   │
└──────────────────────────────────┘
```

## Implementation Notes

- Edit window should capture the "previous app" when recording starts (not when inserting)
- Text should be pre-selected in Edit window for easy replacement
- Focus should be in the text editor when Edit window opens
- Keyboard shortcut: Cmd+Enter to Insert (in addition to button)
