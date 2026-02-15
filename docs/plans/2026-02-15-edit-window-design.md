# Edit Window & Provider Settings Redesign

**Date:** 2026-02-15
**Scope:** Edit window with mouse-driven recording + voice-to-edit via LLM + provider/model settings restructure
**Platform:** macOS 13.0+, Apple Silicon (arm64)

---

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Edit window type | Regular `NSWindow` | Proper workspace for text editing, resizable, standard macOS feel |
| Recording trigger | Mouse press-and-hold on mic button | Alternative to hotkey for users who prefer mouse interaction |
| Voice-to-edit | LLM-powered | Send existing text + voice instruction to LLM; flexible, handles "fix grammar", "make formal", "translate to English" etc. |
| Provider config | One API key per provider | User sets up OpenAI key once, uses it for both whisper-1 (STT) and gpt-4o-mini (LLM) |
| Model assignment | Per-feature primary + fallback | STT and LLM each get a primary model and optional fallback |
| Mic button placement | Inline in content area | Centered when empty, below text when content exists; keeps user's eyes on the text |
| Text append behavior | New transcriptions append at end | Space separator between chunks, text freely editable between recordings |

---

## Part 1: Provider & Model Settings Architecture

### Current Architecture (to be replaced)

Each `ModelConfig` bundles provider + model + endpoint + API key + isActive flag in a flat list. One "active" config used for all transcription.

### New Architecture

Two-level structure: providers configured once, models assigned to features.

#### Provider Catalog Update

Expand `ProviderDefinition` to include both STT and LLM models:

| Provider | STT Models | LLM Models | STT Endpoint | LLM Endpoint |
|----------|-----------|------------|--------------|--------------|
| OpenAI | whisper-1 | gpt-4o-mini, gpt-4o | /v1/audio/transcriptions | /v1/chat/completions |
| Groq | whisper-large-v3, whisper-large-v3-turbo, distil-whisper-large-v3-en | llama-3.3-70b-versatile | /openai/v1/audio/transcriptions | /openai/v1/chat/completions |
| GLM (Zhipu) | glm-asr-2512 | glm-4-flash | /v4/audio/transcriptions | /v4/chat/completions |
| Alibaba (Qwen) | qwen3-asr-flash | qwen-turbo | /compatible-mode/v1/chat/completions | /compatible-mode/v1/chat/completions |
| Custom | (user-defined) | (user-defined) | (user-defined) | (user-defined) |

#### Data Model

```swift
struct ProviderConfig: Codable, Identifiable {
    var id: UUID
    var provider: ProviderType
    var baseURL: String?          // optional override of default base URL
    // API key stored in Keychain via keychainKey
    var keychainKey: String { "provider-\(id.uuidString)" }
}

struct ModelAssignment: Codable, Equatable {
    var providerID: UUID          // references ProviderConfig.id
    var modelId: String           // e.g. "whisper-1", "gpt-4o-mini"
}

struct FeatureConfig: Codable {
    var sttPrimary: ModelAssignment?
    var sttFallback: ModelAssignment?
    var llmPrimary: ModelAssignment?
    var llmFallback: ModelAssignment?
}
```

Storage: `ProviderConfig` array in UserDefaults (JSON-encoded). `FeatureConfig` in UserDefaults. API keys in Keychain keyed by `ProviderConfig.keychainKey`.

#### Migration

On first launch with the new format:
1. Read old `ModelConfig` list
2. Group by provider → create one `ProviderConfig` per unique provider
3. Copy API keys to new keychain entries
4. Set the old active model as STT primary in `FeatureConfig`
5. LLM primary left empty (user must configure)
6. Delete old storage keys after successful migration

### Settings UI Changes

Sidebar sections:

| Section | Content |
|---------|---------|
| **General** | Permissions (unchanged) |
| **Providers** | Add/remove providers, set API keys, optional base URL override. Replaces old "Models" section. |
| **Models** | Two sub-sections: "Speech-to-Text" and "LLM (Voice Edit)". Each has a primary picker (provider + model) and optional fallback picker. Only shows models from configured providers. |
| **Transcription** | Language setting (unchanged) |
| **Hotkey** | Hotkey preset picker (unchanged) |
| **About** | App info (unchanged) |

---

## Part 2: Edit Window

### Overview

A standalone window opened from the status bar menu ("Edit..."). Contains a content area with an inline mic button and a bottom action bar. Independent from the hotkey/floating-panel flow — uses its own `RecordingController` instance.

### Files

- `Sources/LiuyuLib/Edit/EditWindowController.swift` — NSWindow lifecycle
- `Sources/LiuyuLib/Edit/EditView.swift` — SwiftUI view
- `Sources/LiuyuLib/Edit/EditViewModel.swift` — State management, recording/transcription/LLM orchestration

### Window Configuration

- Regular `NSWindow` with `.titled, .closable, .resizable`
- Default size: 500×400, min size: 400×300
- Title: "Liuyu Edit"
- Shows in Cmd+Tab while open (`setActivationPolicy(.regular)`)
- Menu item: "Edit..." in status bar menu (between "Settings..." and separator)
- Saves `NSWorkspace.shared.frontmostApplication` on open for Insert action

### UI States

#### Empty State — no text yet

Mic button centered in the content area.

```
┌──────────────────────────────────────────┐
│  Liuyu Edit                          ─ □ x │
├──────────────────────────────────────────┤
│                                          │
│           🎤 Hold to Record              │
│                                          │
├──────────────────────────────────────────┤
│                     [Clear][Copy][Insert] │
└──────────────────────────────────────────┘
```

#### Recording (empty) — waveform animation

```
├──────────────────────────────────────────┤
│                                          │
│           ~~~~ ▍▎▌▎▍ ~~~~                │
│                                          │
├──────────────────────────────────────────┤
```

#### Transcribing (empty) — spinner

```
├──────────────────────────────────────────┤
│                                          │
│            ⟳ Transcribing...             │
│                                          │
├──────────────────────────────────────────┤
```

#### Has Text — editable text area + mic button inline below

```
├──────────────────────────────────────────┤
│  Previously transcribed text here.       │
│  More text from second recording.        │
│                                          │
│           🎤 Hold to Edit                │
│                                          │
├──────────────────────────────────────────┤
│                     [Clear][Copy][Insert] │
└──────────────────────────────────────────┘
```

Button label changes from "Hold to Record" → "Hold to Edit" once text exists.

#### Recording (has text) — waveform below text

```
├──────────────────────────────────────────┤
│  Previously transcribed text here.       │
│                                          │
│           ~~~~ ▍▎▌▎▍ ~~~~                │
│                                          │
├──────────────────────────────────────────┤
```

#### Processing (has text) — spinner below text

```
├──────────────────────────────────────────┤
│  Previously transcribed text here.       │
│                                          │
│            ⟳ Editing...                  │
│                                          │
├──────────────────────────────────────────┤
```

### Recording Interaction

The mic button uses a `DragGesture(minimumDistance: 0)` to detect press (`.onChanged`) and release (`.onEnded`). Same 300ms minimum recording duration as the hotkey flow.

### Pipelines

#### Record (empty state → append)

1. Mouse press → `RecordingController.start()` → show waveform
2. Mouse release → `RecordingController.stop()` → get audio URL
3. Transcribe via STT primary model (fallback on failure)
4. Append transcribed text to text area

#### Edit (has text state → LLM rewrite)

1. Mouse press → `RecordingController.start()` → show waveform
2. Mouse release → `RecordingController.stop()` → get audio URL
3. Transcribe voice instruction via STT primary model
4. Send to LLM: existing text + transcribed instruction
5. LLM returns edited text → replaces text area content

### Action Bar

| Button | Action |
|--------|--------|
| **Clear** | Empty text area, return to empty/centered state |
| **Copy** | Copy all text to clipboard |
| **Insert** | Copy to clipboard → activate previous app → simulate Cmd+V → close window |

### Error Handling

- No STT model configured → inline error message + open Settings
- No LLM model configured (voice-to-edit) → inline error message + open Settings
- Transcription/LLM error → show error message below text area (not in the editable area), auto-dismiss after 5s
- STT primary fails → try fallback automatically. If both fail → show error.
- LLM primary fails → try fallback automatically. If both fail → show error.

---

## Part 3: LLM Service

### Files

- `Sources/LiuyuLib/LLM/LLMService.swift`

### Interface

```swift
class LLMService {
    init(apiKey: String, endpoint: String, model: String, session: URLSession? = nil)
    func chat(system: String, user: String) async throws -> String
}
```

### Implementation

Standard OpenAI-compatible chat completions API:

```
POST {endpoint}
Authorization: Bearer {apiKey}
Content-Type: application/json

{
  "model": "{model}",
  "messages": [
    {"role": "system", "content": "{system}"},
    {"role": "user", "content": "{user}"}
  ]
}
```

Response: extract `choices[0].message.content`.

### Voice-to-Edit System Prompt

```
You are a text editor assistant. The user will give you existing text and a voice instruction.
Apply the instruction to the text and return ONLY the edited text. Do not add explanations.
If the instruction is unclear, make your best interpretation and apply it.
```

User message format:
```
Text:
{existing text}

Instruction:
{transcribed voice instruction}
```

### Error Types

Same pattern as `TranscriptionError`: `apiKeyInvalid`, `rateLimited`, `serverError`, `networkError`, `decodingFailed`.

Retry: one retry on network error, one retry with 2s wait on 429.

---

## Summary

| Component | What |
|-----------|------|
| Provider Settings | One API key per provider, replaces per-model keys |
| Model Assignment | STT primary/fallback + LLM primary/fallback |
| Edit Window | Mouse-driven recording, inline mic button, editable text area |
| Voice-to-Record | Empty state → transcribe → append text |
| Voice-to-Edit | Has-text state → transcribe instruction → LLM edits text |
| LLM Service | OpenAI-compatible chat completions client |
| Migration | Old ModelConfig list → new ProviderConfig + FeatureConfig |
