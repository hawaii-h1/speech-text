# VoicePeter

macOS menu bar voice-to-text app. Records audio via a global hotkey, transcribes speech, and pastes the result at the cursor position in the previously active app.

## Build & Run

Open `VoicePeter/VoicePeter.xcodeproj` in Xcode and build (Cmd+B) / run (Cmd+R). No external dependencies or package managers — everything uses Apple frameworks.

Target: macOS (native Swift/SwiftUI). The app runs as a menu bar agent (`LSUIElement = true`) with no dock icon or main window.

## Architecture

All source files live in `VoicePeter/VoicePeter/`. There are no tests, no SPM packages, and no third-party dependencies.

### Core Components

- **`App.swift`** — Entry point. `VoicePeterApp` is the `@main` SwiftUI app with an empty `Settings` scene. `AppDelegate` manages the `NSStatusItem` (menu bar icon/menu) and settings window. `AppState` orchestrates recording flow, overlay/panel lifecycle, previous-app tracking, and paste-back. Also contains `ObservedOverlay`, a small wrapper view that bridges `SpeechEngine` to `RecordingOverlayView`.
- **`SpeechEngine.swift`** — Central recording + transcription engine. Manages `AVAudioEngine` for capture, `SFSpeechRecognizer` for Apple on-device STT, and delegates to `BatchSTTProvider` for Groq. Supports start/pause/resume/stop lifecycle. Exposes `barLevels` (per-segment RMS) for waveform visualization, `liveText` for in-progress transcription, `finalText` for completed transcription, and `editedText` for user-editable result. `pendingInsertionText` signals when a segment is ready for cursor insertion.
- **`STTProvider.swift`** — `STTProviderType` enum (`.apple`, `.groq`), `BatchSTTProvider` protocol, and `GroqSTTProvider` implementation (multipart POST to Groq Whisper API). Includes `Data` extensions for multipart form encoding and `GroqError` for API error handling.
- **`AudioBufferWriter.swift`** — Accumulates `AVAudioPCMBuffer` frames and writes them to a temporary WAV file for batch STT providers. Handles buffer copying, WAV file creation via `AVAudioFile`, and cleanup of temp files.
- **`LLMProvider.swift`** — `LLMProviderType` enum (`.groq`, `.anthropic`, `.openai`), `LLMChatProvider` protocol, `OpenAICompatibleLLMProvider` (one implementation covering Groq and OpenAI, which share the `/chat/completions` shape) and `AnthropicLLMProvider` (raw `POST /v1/messages`; sends `output_config.effort = low` where supported, opts into server-side refusal fallbacks on Opus 5, and treats `stop_reason == "refusal"` as an error). `LLMConfiguration` resolves provider/key/model from UserDefaults and builds the provider.
- **`PromptPresets.swift`** — `PromptPreset` model (`name`, `whenToUse`, `instructions`) and `PromptPresetStore` (JSON in UserDefaults, six built-in defaults with fixed UUIDs, plus the "default preset" pointer).
- **`TextRefinementService.swift`** — Builds the routing system prompt from the presets, sends the transcript wrapped in `<transcript>` tags, and parses the reply's leading `<<mode:NAME>>` marker (plus a wrapping code fence, if any).

### Recording Modes

- **Inline recording** — Triggered by global hotkey (default: `Ctrl+Shift+Q`). Shows a small floating overlay (`RecordingOverlay.swift`) at the bottom of the screen. On stop, transcribed text is pasted at the cursor in the previously focused app via `PasteService`. Falls back to opening the Record Window if accessibility permission is missing or the previous app couldn't be detected.
- **AI recording** — Triggered by global hotkey (default: `Ctrl+Shift+A`). Same flow as inline recording, but before pasting, the transcription is sent to an LLM by `TextRefinementService`. The dictation itself is the prompt: the model picks the best-matching prompt preset from `whenToUse` descriptions, applies that preset's instructions, and returns only the resulting text. The overlay stays up (tinted purple, with a sparkles badge) while the LLM works. Any LLM failure or refusal falls back to pasting the raw transcript, so a dictation is never lost.
- **Record Window** — Triggered by global hotkey (default: `Ctrl+Shift+W`). Opens `DirectRecordingPanel.swift`, a floating panel that auto-starts recording and shows waveform + live text in an editable text area. Supports pause/resume via hotkey or button. After transcription, text can be edited, then pasted at cursor, copied, or sent to webhook. The hotkey toggles recording state when the panel is already open. A ✨ toggle in the toolbar turns on LLM processing: each time a segment finishes transcribing, the whole text area is sent through `TextRefinementService` and replaced with the result (turning the toggle on with text already present processes it immediately).

### Services

- **`HotkeyManager.swift`** — Registers global hotkeys using Carbon `RegisterEventHotKey`. Supports two hotkeys (inline recording and record window) with configurable key codes and modifiers. Listens for `hotkeyDidChange` notifications to hot-reload shortcuts. Uses `Unmanaged` pointer for Carbon event handler callback.
- **`HotkeyRecorderView.swift`** — SwiftUI view that captures a new keyboard shortcut via `NSEvent.addLocalMonitorForEvents`. Filters out bare modifier keys and requires at least one modifier. Also contains free functions `shortcutDisplayString()` (builds display string with modifier symbols) and `keyCodeToString()` (converts virtual key codes to readable strings using `UCKeyTranslate`). Defines the `hotkeyDidChange` notification name.
- **`PasteService.swift`** — Pastes text at cursor by saving clipboard contents, setting the clipboard to the transcription text, simulating `Cmd+V` via `CGEvent`, then restoring the original clipboard after a delay. Also handles app activation (via `NSRunningApplication.activate` + AppleScript fallback) and accessibility permission checks/prompts.
- **`WebhookService.swift`** — Sends transcribed text to a user-configured webhook URL via POST with JSON body (`text`, `source`, `timestamp`). Supports optional Bearer token auth. Uses completion handler pattern with `Result<Void, Error>`.

### UI

- **`MenuBarView.swift`** — `SettingsView` form, organised as a pipeline so the two independent model choices don't get confused: **Step 1 · Speech → Text** (engine picker with a plain-language subtitle, Whisper model when Groq is selected, language), **Step 2 · Text → Text (AI)** (LLM provider, chat model, presets editor link, ready/needs-a-key status), **API Keys** (only the credentials the current selections use; the shared Groq key names both consumers), then shortcuts, webhook and permissions. All pickers read through a resolved `STTProviderType`/`LLMProviderType` rather than the raw stored string.
- **`PromptPresetsView.swift`** — Presets editor window (`PromptPresetsWindow`): sidebar list with add/remove/reorder, detail pane editing name / "when to use" / instructions, default-preset toggle, and restore-defaults.
- **`RecordingOverlay.swift`** — `WaveformBarsView` (reusable animated bar visualization with configurable dimensions, colors, and loading animation), `RecordingOverlayView` (wraps waveform in a material background capsule), and `RecordingOverlayPanel` (borderless floating `NSPanel` positioned at bottom center of screen).
- **`DirectRecordingPanel.swift`** — Full recording panel with editable text area, waveform record button (expands to show waveform while recording/transcribing), copy and webhook send buttons with hover effects and checkmark feedback. Contains `DirectRecordingPanelWindow` (floating `NSPanel`), `TextInsertionHandler` (inserts transcribed segments at cursor position in the text view, adding spaces as needed), and `CursorTextEditor` (`NSViewRepresentable` wrapping `NSTextView` with coordinator for two-way binding).
- **`ResultPanel.swift`** — Standalone result display panel with copy/send-to-webhook actions and status messages. Contains `ResultPanelView` and `ResultPanelWindow`. Currently unused in the main flow (superseded by `DirectRecordingPanel`).
- **`Settings.swift`** — `SettingsKeys` constants enum, `SupportedLanguage` model, `groqModels` list, `autoLanguageID` sentinel value, `supportedLanguages` array (Auto/English/Ukrainian). Also contains `resolvedLocale()` which resolves the effective speech recognition locale — when set to "auto", it detects the active macOS keyboard input source via `com.apple.HIToolbox` preferences and maps layout names to ISO 639-1 codes using the `layoutToLanguage` dictionary.

## Key Patterns

- **`@Observable` macro** — Used for `SpeechEngine`, `HotkeyManager`, and `AppState` (Swift Observation framework, not Combine).
- **UserDefaults via `@AppStorage`** — All settings stored in standard UserDefaults. Keys defined in `SettingsKeys` enum.
- **`NSPanel` subclasses** — Floating panels use `.nonactivatingPanel` style so they don't steal focus from the user's active app.
- **Carbon Events API** — Global hotkeys use `RegisterEventHotKey` / `InstallEventHandler` from Carbon.HIToolbox (the only way to register system-wide hotkeys on macOS).
- **No app sandbox** — Disabled in entitlements to allow accessibility APIs (`AXIsProcessTrusted`) and global event taps.
- **Clipboard preservation** — `PasteService` saves and restores clipboard contents around paste operations so the user's clipboard is not clobbered.
- **Stored-value normalization** — `normalizeStoredProviders()` (Settings.swift) runs at launch and from the Settings view: a `sttProvider`/`llmProvider` string that no longer maps to a case is reset. Without it the picker finds no matching tag and renders *blank* while the engine silently falls back to its default — the UI shows nothing and the app runs something the user didn't pick.
- **One-time shortcut migration** — `AppDelegate.migrateHotkeyLayoutIfNeeded()` clears stored hotkey values once (guarded by `hotkeyLayoutVersion`) so a changed built-in layout reaches existing installs; later customisations survive because the version has already been bumped.
- **Auto language detection** — When language is set to "Auto (System)", the app reads the active keyboard input source and maps it to the corresponding speech recognition locale.
- **Preset routing in one call** — The LLM both picks the preset and applies it in a single request; it reports its choice on a leading `<<mode:NAME>>` line that `TextRefinementService.parse` strips. This avoids a separate router round-trip, which matters because the user is waiting for the paste.
- **Graceful LLM degradation** — Every LLM failure path (missing key, HTTP error, refusal, empty response) falls back to the raw transcription rather than producing nothing.

## Permissions Required

- **Microphone** — For audio capture (`AVAudioEngine`)
- **Speech Recognition** — For Apple on-device STT (`SFSpeechRecognizer`)
- **Accessibility** — For simulating `Cmd+V` paste via CGEvent. Must be granted in System Settings > Privacy & Security > Accessibility. The app prompts for this on first launch.

## Settings Keys Reference

| Key | Purpose | Default |
|-----|---------|---------|
| `sttProvider` | STT backend (`"apple"` or `"groq"`) | `"apple"` |
| `groqAPIKey` | Groq API key | empty |
| `groqModel` | Groq Whisper model ID | `"whisper-large-v3-turbo"` |
| `selectedLanguage` | Locale identifier or `"auto"` | `"auto"` |
| `hotkeyKeyCode` / `hotkeyModifierFlags` | Inline recording hotkey | `12` (Q) / Control+Shift |
| `recordWindowHotkeyKeyCode` / `recordWindowHotkeyModifierFlags` | Record window hotkey | `13` (W) / Control+Shift |
| `aiHotkeyKeyCode` / `aiHotkeyModifierFlags` | AI recording hotkey | `0` (A) / Control+Shift |
| `hotkeyLayoutVersion` | Shortcut-layout migration marker | `0` (unmigrated) |
| `llmProvider` | LLM backend (`"groq"`, `"anthropic"`, `"openai"`) | `"groq"` |
| `groqLLMModel` | Groq chat model ID | `"llama-3.3-70b-versatile"` |
| `anthropicAPIKey` / `anthropicModel` | Anthropic key and model | empty / `"claude-opus-5"` |
| `openAIAPIKey` / `openAIModel` | OpenAI key and model | empty / `"gpt-4.1-mini"` |
| `promptPresets` | JSON-encoded `[PromptPreset]` | built-in defaults |
| `defaultPresetID` | UUID of the fallback preset | Clean-up |
| `aiModeInRecordWindow` | Record Window ✨ toggle state | `false` |
| `webhookURL` | Webhook endpoint URL | empty |
| `authToken` | Webhook Bearer token | empty |
