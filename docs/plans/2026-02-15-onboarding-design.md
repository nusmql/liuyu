# Onboarding Flow Design

## Goal

Guide first-time users through permissions and provider setup so the app is usable immediately after onboarding.

## Architecture

- **Dedicated window:** `OnboardingWindowController` — fixed ~500x400, centered, not resizable. Title: "Welcome to LiuYu".
- **Trigger:** `AppDelegate.applicationDidFinishLaunching` checks `hasCompletedOnboarding` UserDefaults flag. If false, shows onboarding instead of settings.
- **Navigation:** 3-step wizard with Back/Next/Done buttons. Step indicator at top (e.g. "Step 1 of 3" or dots).
- **Completion:** Sets `hasCompletedOnboarding = true`, closes window. App ready to use.

## Step 1: Permissions

Two permission rows stacked vertically:

**Microphone Access:**
- Mic icon + title + "Required to record your voice"
- Green checkmark when granted, "Grant" button when not
- "Grant" triggers `AVCaptureDevice.requestAccess(for: .audio)` (native dialog)

**Accessibility Access:**
- Keyboard icon + title + "Required for the global hotkey"
- Green checkmark when granted, "Grant" button when not
- "Grant" calls `AXIsProcessTrustedWithOptions` with prompt flag (opens System Settings)

**Polling:** Both statuses refresh every 2 seconds (same pattern as GeneralSettingsView).

**Next button:** Always enabled. If mic not granted, show subtle warning: "Recording won't work without microphone access."

## Step 2: Provider + API Key

**Provider picker:** Segmented control or dropdown: OpenAI, Groq, GLM, Alibaba. No "Custom" during onboarding.

**API key input:** SecureField with "Paste your API key" placeholder. Small "Get API Key" link below opens the provider's API key page in browser.

**API key page URLs:**
- OpenAI: `https://platform.openai.com/api-keys`
- Groq: `https://console.groq.com/keys`
- GLM: `https://open.bigmodel.cn/usercenter/apikeys`
- Alibaba: `https://dashscope.console.aliyun.com/apiKey`

**On "Next":**
- Creates `ProviderConfig` for selected provider
- Saves API key via `ProviderConfigStore`
- Auto-assigns STT Primary to provider's first STT model
- Auto-assigns LLM Primary to provider's first LLM model
- No manual model selection needed — sensible defaults

**Validation:** "Next" disabled until API key is entered. No API call to validate (errors surface on first use).

## Step 3: Done

- Checkmark icon + "You're all set!"
- Usage instructions:
  - "Hold **Right Option** to record and transcribe anywhere"
  - "Or click **Open** in the menu bar to use the Edit window"
- Single "Get Started" button

**On completion:**
- Sets `hasCompletedOnboarding = true` in UserDefaults
- Closes onboarding window

## Files to Create/Modify

- **Create:** `Sources/LiuyuLib/Onboarding/OnboardingWindowController.swift`
- **Create:** `Sources/LiuyuLib/Onboarding/OnboardingView.swift`
- **Modify:** `Sources/LiuyuLib/App/AppDelegate.swift` — check flag, show onboarding on first launch
- **Modify:** `Sources/LiuyuLib/Settings/ModelConfig.swift` — add API key page URLs to ProviderDefinition
