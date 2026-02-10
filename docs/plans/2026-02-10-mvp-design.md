# Liuyu MVP Design

**Date:** 2026-02-10
**Scope:** MVP — global hotkey, recording, OpenAI Whisper API, auto-insert, minimal UI
**Platform:** macOS 13.0+, Apple Silicon (arm64), Developer ID distribution
**Icons:** Lucide icon set (via lucide-swift or bundled SVG assets)

---

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Hotkey detection | `CGEventTap` | Reliable key-down/key-up for modifiers, can suppress events from reaching other apps |
| Audio capture | `AVAudioEngine` | Real-time amplitude metering, easy to extend with waveform later |
| UI framework | SwiftUI in AppKit `NSPanel` | SwiftUI for views, `NSPanel` for proper floating/non-activating behavior |
| App type | Menu bar only (`LSUIElement`) | Utility app stays out of the way |
| Post-transcription | Auto-insert via Cmd+V simulation | Primary action is Insert (Enter key), copies to clipboard and pastes into previous app |
| API key storage | macOS Keychain | Secure storage for sensitive credentials |
| Recall last result | No | Dismissed results are gone. Clipboard has the text if you inserted or copied. |

---

## Project Structure

```
liuyu/
├── App/
│   ├── LiuyuApp.swift              # @main entry point
│   └── AppDelegate.swift            # NSStatusItem, owns managers, orchestrates state
├── Hotkey/
│   └── HotkeyManager.swift          # CGEventTap setup, publishes key events
├── Audio/
│   └── RecordingController.swift     # AVAudioEngine capture and metering
├── Transcription/
│   └── TranscriptionService.swift    # OpenAI Whisper API client
├── UI/
│   ├── FloatingPanelController.swift # NSPanel wrapper, hosts SwiftUI views
│   ├── RecordingView.swift           # Waveform bars, mic icon, close button
│   ├── ProcessingView.swift          # Spinner, "Transcribing..." text
│   └── ResultView.swift              # Transcribed text, Clear/Copy/Insert buttons
├── Settings/
│   ├── SettingsView.swift            # API key form, language picker
│   └── KeychainHelper.swift          # Keychain read/write wrapper
└── Resources/
    └── Info.plist
```

Dependencies: Lucide icons (bundled SVG or lucide-swift package). All other frameworks are Apple-native.

---

## Hotkey Manager & Event Flow

`HotkeyManager` installs a `CGEventTap` at the session level listening for `.flagsChanged` events. When the configured modifier key (default: right Option) is pressed, it publishes `.keyDown`. When released, it publishes `.keyUp`. The tap suppresses the modifier event from reaching other apps.

On first launch, the app checks `AXIsProcessTrusted()`. If Accessibility permission is not granted, it shows an alert with a button to open System Settings. The app polls `AXIsProcessTrusted()` every 2 seconds until granted, then installs the event tap.

### State Machine

```
Idle ──(keyDown)──→ Recording ──(keyUp)──→ Processing ──(API result)──→ Result
                                                                          │
                                                       (Enter / Escape / auto-dismiss)
                                                                          │
                                                                        Idle
```

### Orchestration (AppDelegate)

`HotkeyManager` exposes a Combine `PassthroughSubject<HotkeyEvent, Never>`.

- **keyDown:** Show floating panel in recording state, start `RecordingController`
- **keyUp:** Stop `RecordingController` (returns temp file URL), show processing state, call `TranscriptionService`
- **Transcription result:** Show result state with transcribed text

### Minimum Recording Duration

If keyUp arrives before 300ms, keep recording until 300ms then stop. Prevents sending audio too short for Whisper to process.

### Focus Tracking

Before showing the panel, `AppDelegate` saves `NSWorkspace.shared.frontmostApplication` so Insert can re-activate that app later.

---

## Audio Recording

`RecordingController` wraps `AVAudioEngine`.

### Recording Flow

1. **Start:** Create temp file in `NSTemporaryDirectory()`, configure input format (16kHz, 1 channel), install tap on `inputNode`, write to `.m4a` file with AAC encoding (~15KB/sec)
2. **During recording:** Each buffer callback writes PCM samples to `AVAudioFile` and calculates RMS amplitude. Published via `@Published var audioLevel: Float` (0.0–1.0, normalized from dB range)
3. **Stop:** Remove tap, stop engine, close file. Return temp file URL via async completion

### Microphone Permission

Requested on first `start()` via `AVCaptureDevice.requestAccess(for: .audio)`. If denied, throws an error — `AppDelegate` shows alert with link to System Settings.

### Cleanup

Temp files deleted after successful transcription. Orphaned files swept on app launch.

---

## Transcription Service

`TranscriptionService` sends audio to the OpenAI Whisper API via `URLSession`.

### API Request

`multipart/form-data` POST to the configured endpoint (default: `https://api.openai.com/v1/audio/transcriptions`).

Fields:
- `file`: the `.m4a` audio file
- `model`: `whisper-1`
- `language`: optional, user-configurable (`en`, `zh`, or omitted for auto-detect)
- `response_format`: `json` (returns `{"text": "..."}`)

### Interface

```swift
func transcribe(audioFileURL: URL) async throws -> String
```

### Error Handling

| Error | Behavior |
|-------|----------|
| Network timeout (30s) | Retry once. If second attempt fails, show error in result panel, keep audio file |
| 401 (bad API key) | Show message directing user to Settings |
| 429 (rate limit) | Wait 2 seconds, retry once |
| Other 4xx/5xx | Show error message as-is |
| Empty response | Show "No speech detected" |

API key read from Keychain on each request. If no key configured, immediately return error prompting user to open Settings.

---

## Floating Panel & UI

### NSPanel Configuration

- `styleMask`: `.borderless`, `.nonactivatingPanel`
- `level`: `.floating`
- `backgroundColor`: `.clear`
- `isMovableByWindowBackground`: `true`
- `hidesOnDeactivate`: `false`

Panel created once at launch, shown/hidden as needed. Positioned at center of the screen with the mouse cursor (multi-monitor support). Fade in/out with 0.15s opacity animation.

### View Model

```swift
enum PanelState {
    case recording(audioLevel: Float)
    case processing
    case result(text: String)
}
```

### RecordingView (~280x80pt)

Compact pill shape, light frosted material (`.ultraThinMaterial`). Lucide `mic` icon left, 5–7 waveform bars center (amplitude-driven `RoundedRectangle` shapes in `HStack`, ~15fps update), Lucide `x` close button right. No text labels.

### ProcessingView

Same pill dimensions. Spinner replaces waveform.

### ResultView (~400x120pt)

Wider panel, dark frosted material. Lucide `mic` icon top-left, transcribed text flowing right. Bottom-right action buttons: "Clear" (Lucide `trash-2` icon), "Copy" (Lucide `clipboard-copy` icon), "Insert" (blue pill, primary action, Lucide `corner-down-left` icon).

### Keyboard Shortcuts (Result State)

| Key | Action |
|-----|--------|
| **Enter** | Insert: copy to `NSPasteboard`, re-activate previous app via `NSRunningApplication.activate()`, simulate Cmd+V via `CGEvent`, dismiss panel |
| **Escape** | Clear & dismiss, discard everything |
| **Cmd+C** | Copy to clipboard, panel stays open |

### Auto-Dismiss

10 seconds with no interaction: same as Escape (dismiss, discard).

---

## Settings & Keychain

### Settings Window

Standard `NSWindow` opened from menu bar "Settings..." item. SwiftUI form with:

**API Configuration:**
- API Key (`SecureField`, masked)
- Endpoint URL (pre-filled with `https://api.openai.com/v1/audio/transcriptions`, editable)
- Language picker: Auto-detect, English, Chinese (Simplified)

**Hotkey Configuration:**
- MVP: label showing current hotkey ("Right Option"), customization deferred to Beta

### KeychainHelper

Thin wrapper around Security framework:

```swift
static func save(key: String, value: String) throws
static func read(key: String) throws -> String?
```

Uses `SecItemAdd` / `SecItemCopyMatching` / `SecItemUpdate` with `kSecClassGenericPassword`. Service name: `com.liuyu.api`.

### User Preferences

Non-sensitive settings (endpoint URL, language) stored in `UserDefaults` via `@AppStorage`.

### First Launch

If no API key configured, automatically open the settings window with instruction: "Enter your OpenAI API key to get started."

---

## Permissions & Build Configuration

### Info.plist

| Key | Value |
|-----|-------|
| `LSUIElement` | `true` |
| `NSMicrophoneUsageDescription` | "Liuyu needs microphone access to record your voice for transcription." |
| `LSMinimumSystemVersion` | `13.0` |

### Entitlements

Unsandboxed (required for `CGEventTap`). Only entitlement needed:
- `com.apple.security.device.audio-input`

### Accessibility Permission

Runtime check via `AXIsProcessTrusted(withOptions:)` on first launch. Not an entitlement — user must grant in System Settings.

### Build Settings

- Deployment target: macOS 13.0
- Architectures: `arm64`
- Swift: 5.9+
- Signing: Developer ID
- Hardened Runtime: enabled (required for notarization)
- Notarization via `xcrun notarytool`

### Build & Run

```bash
git clone <repo> && open liuyu.xcodeproj
# Or from command line:
xcodebuild -scheme liuyu -configuration Debug -arch arm64 build
```
