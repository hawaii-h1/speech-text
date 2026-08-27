# SpeachText

macOS menu bar voice-to-text app. Records audio via a global hotkey, transcribes speech, and pastes the result at the cursor position in the previously active app.

The app was called **VoicePeter** until the 2026 rebrand. The bundle identifier moved with it (`com.voicepeter.app` → `com.speachtext.app`), which means macOS treats it as a new app and re-asks for microphone, speech-recognition and accessibility permission. Two one-shot migrations run on first launch so the rename doesn't read as a factory reset: `TranscriptionHistory.adoptPreRenameStore()` moves the old Application Support folder across, and `adoptPreRenameDefaults()` (Settings.swift) copies `SettingsKeys.portable` out of the `com.voicepeter.app` preference domain — API keys, shortcuts and prompt presets included. The launch-at-login and accessibility-prompt flags are deliberately left behind: they record grants made to the *old* bundle identifier.

## Build & Run

Open `SpeachText/SpeachText.xcodeproj` in Xcode and build (Cmd+B) / run (Cmd+R). No external dependencies or package managers — everything uses Apple frameworks.

Target: macOS (native Swift/SwiftUI). The app runs as a menu bar agent (`LSUIElement = true`) with no dock icon or main window.

## Architecture

All source files live in `SpeachText/SpeachText/`. There are no tests, no SPM packages, and no third-party dependencies.

### Core Components

- **`App.swift`** — Entry point. `SpeachTextApp` is the `@main` SwiftUI app with an empty `Settings` scene. `AppDelegate` manages the `NSStatusItem` (menu bar icon/menu) and settings window. `AppState` orchestrates recording flow, overlay/panel lifecycle, previous-app tracking, and paste-back. Also contains `ObservedOverlay`, a small wrapper view that bridges `SpeechEngine` to `RecordingOverlayView`.
- **`SpeechEngine.swift`** — Central recording + transcription engine. Manages `AVAudioEngine` for capture, `SFSpeechRecognizer` for Apple on-device STT, and delegates to `BatchSTTProvider` for Groq. Supports start/pause/resume/stop lifecycle. Exposes `barLevels` (per-segment RMS) for waveform visualization, `liveText` for in-progress transcription, `finalText` for completed transcription, and `editedText` for user-editable result. `pendingInsertionText` signals when a segment is ready for cursor insertion.
- **`STTProvider.swift`** — `STTProviderType` enum (`.apple`, `.groq`, `.elevenlabs`), `BatchSTTProvider` protocol, the shared `makeBatchProvider(for:)` factory (used by both live recording and History retries), plus `GroqSTTProvider` and `ElevenLabsSTTProvider` implementations (multipart POST to Groq Whisper API). Includes `Data` extensions for multipart form encoding and `GroqError` for API error handling.
- **`AudioBufferWriter.swift`** — Accumulates `AVAudioPCMBuffer` frames and writes them to a temporary WAV file for batch STT providers. Handles buffer copying, WAV file creation via `AVAudioFile`, and cleanup of temp files.
- **`TranscriptionHistory.swift`** — `TranscriptionRecord` + an `@Observable` store persisted to `Application Support/VoicePeter/history.json` (newest first, capped at 300). Failed and empty results keep their WAV under `Recordings/` for 7 days so they can be retried. `TranscriptionRecord.Refinement` records the LLM pass: `inputText` (what was actually sent — the Record Window refines its whole text area, not just one segment), `outputText`, `presetName`, `provider`/`model`, and `errorMessage` when the pass failed. `record.text` always stays the raw transcription; `deliveredText` returns what the user actually received.
- **`HistoryView.swift`** — History browser (`HistoryWindow`): filterable list, retry-from-archived-audio, copy, and a two-pane “Dictated / AI output” comparison for entries that went through the LLM.
- **`LLMProvider.swift`** — `LLMProviderType` enum (`.groq`, `.anthropic`, `.openai`), `LLMChatProvider` protocol, `OpenAICompatibleLLMProvider` (one implementation covering Groq and OpenAI, which share the `/chat/completions` shape but not its parameters — see its `Dialect`: Groq takes `max_tokens`/`temperature`, OpenAI's GPT-5.x reasoning models reject both and use `max_completion_tokens`) and `AnthropicLLMProvider` (raw `POST /v1/messages`; sends `output_config.effort = low` where supported, opts into server-side refusal fallbacks on Opus 5, and treats `stop_reason == "refusal"` as an error). `LLMConfiguration` resolves provider/key/model from UserDefaults and builds the provider.
- **`PromptPresets.swift`** — `PromptPreset` model (`name`, `whenToUse`, `instructions`) and `PromptPresetStore` (JSON in UserDefaults, six built-in defaults with fixed UUIDs, plus the "default preset" pointer).
- **`TextRefinementService.swift`** — Builds the routing system prompt from the presets, sends the transcript wrapped in `<transcript>` tags, and parses the reply's leading `<<mode:NAME>>` marker (plus a wrapping code fence, if any).

### Recording Modes

- **Inline recording** — Triggered by global hotkey (default: `Ctrl+Shift+Q`). Shows a small floating overlay (`RecordingOverlay.swift`) at the bottom of the screen. On stop, transcribed text is pasted at the cursor in the previously focused app via `PasteService`. Falls back to opening the Record Window if accessibility permission is missing or the previous app couldn't be detected.
- **AI recording** — Triggered by global hotkey (default: `Ctrl+Shift+A`). Same flow as inline recording, but before pasting, the transcription is sent to an LLM by `TextRefinementService`. The dictation itself is the prompt: the model picks the best-matching prompt preset from `whenToUse` descriptions, applies that preset's instructions, and returns only the resulting text. The overlay stays up (tinted purple, with a sparkles badge) while the LLM works. Any LLM failure or refusal falls back to pasting the raw transcript, so a dictation is never lost.
- **Record Window** — Triggered by global hotkey (default: `Ctrl+Shift+W`). Opens `DirectRecordingPanel.swift`, a floating panel that auto-starts recording. The transport knob starts, pauses and resumes; the dot matrix along the bottom shows the level while recording and a sweeping comet while a provider is working. Transcribed segments land in an editable text column, and the button rail on the right insert-at-cursor / copies / sends to the webhook. The hotkey toggles recording when the panel is already open; ⎋ or ⌘W closes it, as does the ✕ revealed on hover. The rail's ✨ button turns on LLM processing: each time a segment finishes transcribing, the whole text area goes through `TextRefinementService` and is replaced with the result (turning it on with text already present processes it immediately), and the phosphor turns violet for as long as it is on.

### Services

- **`HotkeyManager.swift`** — Registers global hotkeys using Carbon `RegisterEventHotKey`. Supports two hotkeys (inline recording and record window) with configurable key codes and modifiers. Listens for `hotkeyDidChange` notifications to hot-reload shortcuts. Uses `Unmanaged` pointer for Carbon event handler callback.
- **`HotkeyRecorderView.swift`** — SwiftUI view that captures a new keyboard shortcut via `NSEvent.addLocalMonitorForEvents`. Filters out bare modifier keys and requires at least one modifier. Also contains free functions `shortcutDisplayString()` (builds display string with modifier symbols) and `keyCodeToString()` (converts virtual key codes to readable strings using `UCKeyTranslate`). Defines the `hotkeyDidChange` notification name.
- **`PasteService.swift`** — Pastes text at cursor by saving clipboard contents, setting the clipboard to the transcription text, simulating `Cmd+V` via `CGEvent`, then restoring the original clipboard after a delay. Also handles app activation (via `NSRunningApplication.activate` + AppleScript fallback) and accessibility permission checks/prompts.
- **`WebhookService.swift`** — Sends transcribed text to a user-configured webhook URL via POST with JSON body (`text`, `source`, `timestamp`). Supports optional Bearer token auth. Uses completion handler pattern with `Result<Void, Error>`.

### UI

- **`MenuBarView.swift`** — `SettingsView` form, organised as a pipeline so the two independent model choices don't get confused: **Step 1 · Speech → Text** (engine picker with a plain-language subtitle, Whisper model when Groq is selected, language), **Step 2 · Text → Text (AI)** (LLM provider, chat model, presets editor link, ready/needs-a-key status), **API Keys** (only the credentials the current selections use; the shared Groq key names both consumers), then shortcuts, webhook and permissions. All pickers read through a resolved `STTProviderType`/`LLMProviderType` rather than the raw stored string.
- **`PromptPresetsView.swift`** — Presets editor window (`PromptPresetsWindow`): sidebar list with add/remove/reorder, detail pane editing name / "when to use" / instructions, default-preset toggle, and restore-defaults.
- **`DesignKit.swift`** — The look, in one place. `Skin` (every colour and the shared geometry), `SVGPathData` (a reader for the absolute-command subset of SVG path data, so shapes traced from Figma keep their raw `d` string), `LCDScreenShape` / `LCDScreen` (the notched glass and its inner shadow), `ShellBackground`, `InnerShadow`, `PlasticButton` / `ButtonRail`, `TransportKnob` and `LanguageBadge`.
- **`PixelDisplay.swift`** — The dot-matrix display. `PixelMatrix` renders the grid in a `Canvas`; `PixelWaveform` drives it from `SpeechEngine.barLevels` on its own 30Hz clock; `PixelDisplayMode` collapses the engine's states into idle / listening / working, and `PixelPalette` supplies the green or (AI mode) violet phosphor.
- **`RecordingOverlay.swift`** — `RecordingOverlayView` (the inline strip: a `LanguageBadge` beside a 100×56 LCD showing the live level, with a cancel button revealed on hover), `StatusOverlayView` (the transient failure notice, on the same glass), plus their `NSPanel`s.
- **`DirectRecordingPanel.swift`** — The record window, drawn at the design's fixed 362×284 size: the shell, the notched glass, the transport knob, the button rail, the dot matrix, and an editable text column. Contains `DirectRecordingPanelWindow` (a borderless floating `NSPanel` — it draws its own shell, so a titlebar would only sit on top of it), `TextInsertionHandler` (inserts transcribed segments at the cursor, adding spaces as needed) and `LCDTextEditor` (`NSViewRepresentable` wrapping `NSTextView`, phosphor on black).
- **`Settings.swift`** — `SettingsKeys` constants enum, `SupportedLanguage` model, `groqModels` list, `autoLanguageID` sentinel value, `supportedLanguages` array (Auto/English/Ukrainian). Also contains `resolvedLocale()` which resolves the effective speech recognition locale — when set to "auto", it detects the active macOS keyboard input source via `com.apple.HIToolbox` preferences and maps layout names to ISO 639-1 codes using the `layoutToLanguage` dictionary.

## Key Patterns

- **`@Observable` macro** — Used for `SpeechEngine`, `HotkeyManager`, and `AppState` (Swift Observation framework, not Combine).
- **UserDefaults via `@AppStorage`** — All settings stored in standard UserDefaults. Keys defined in `SettingsKeys` enum.
- **`NSPanel` subclasses** — Floating panels use `.nonactivatingPanel` style so they don't steal focus from the user's active app.
- **One skin, two surfaces** — The inline overlay and the record window are the same device: a moulded plastic shell with a dark-green LCD in it. Every colour, radius and dot pitch lives in `Skin` (DesignKit.swift), so neither surface can drift from the other or from the Figma file.
- **Traced shapes keep their path data** — `LCDScreenShape` stores the two `d` strings Figma exported and scales them onto whatever rect it is given, instead of a hand translation into `Path` calls. Re-exporting a tweaked vector is then a copy-paste. The two halves are `union`ed, not merely overlaid: they share an internal edge at the knob's waistline, and the inner shadow strokes the shape, so anything less would draw a seam across the glass.
- **The knob is drawn, not exported** — `TransportKnob` rebuilds the design's layer stack (bevel → outer disc → groove → cap → glyph) in SwiftUI because the app needs the knob in states the design never drew (recording, transcribing, AI, hover, pressed) and a bitmap can't take a different glyph or tint. Its shading was matched against the design render pixel by pixel; changing a gradient stop by feel will drift.
- **The bevel is a `.background`, not a ZStack layer** — it is larger than the knob, and a `ZStack` re-proposes its final size to flexible children, so putting it in the stack silently inflates the disc to match it.
- **The display has its own clock** — `PixelWaveform` scrolls at a fixed 30Hz and samples `barLevels` on each tick, rather than advancing when the audio tap fires: Core Audio's callback rate varies, and driving the scroll from it makes the waveform speed up and slow down. It samples the *mean* of the per-segment RMS, not the peak — the peak pins nearly every column to full height, because one transient in any segment wins.
- **`.task` captures the view by value** — which is why `PixelWaveform` reads levels through a small `LevelFeed` class rather than its own stored property, and why the task is keyed on `mode`.
- **Carbon Events API** — Global hotkeys use `RegisterEventHotKey` / `InstallEventHandler` from Carbon.HIToolbox (the only way to register system-wide hotkeys on macOS).
- **No app sandbox** — Disabled in entitlements to allow accessibility APIs (`AXIsProcessTrusted`) and global event taps.
- **Clipboard preservation** — `PasteService` saves and restores clipboard contents around paste operations so the user's clipboard is not clobbered.
- **Stored-value normalization** — `normalizeStoredProviders()` (Settings.swift) runs at launch and from the Settings view: a `sttProvider`/`llmProvider` string that no longer maps to a case is reset, and every stored model ID is checked against its catalogue (vendors retire whole generations, e.g. OpenAI's GPT-4.x → GPT-5.6). Without it the picker finds no matching tag and renders *blank* while the engine silently falls back to its default — the UI shows nothing and the app runs something the user didn't pick.
- **Rename migrations are opt-in per key** — `SettingsKeys.portable` lists what crosses the bundle-identifier change, rather than copying the whole old domain. A blanket copy would bring `hasRegisteredLaunchAtLogin` and `hasPromptedAccessibility` with it, leaving the new app both unregistered as a login item and never prompting for accessibility.
- **One-time shortcut migration** — `AppDelegate.migrateHotkeyLayoutIfNeeded()` clears stored hotkey values once (guarded by `hotkeyLayoutVersion`) so a changed built-in layout reaches existing installs; later customisations survive because the version has already been bumped.
- **Auto language detection** — When language is set to "Auto (System)", the app reads the active keyboard input source and maps it to the corresponding speech recognition locale.
- **Preset routing in one call** — The LLM both picks the preset and applies it in a single request; it reports its choice on a leading `<<mode:NAME>>` line that `TextRefinementService.parse` strips. This avoids a separate router round-trip, which matters because the user is waiting for the paste.
- **Graceful LLM degradation** — Every LLM failure path (missing key, HTTP error, refusal, empty response) falls back to the raw transcription rather than producing nothing, surfaces a status overlay, and is written to the history entry so a silently-unrewritten paste is explainable after the fact.
- **Attaching the LLM pass to a history entry** — `SpeechEngine` writes the history record, but refinement happens later in `AppState`/`DirectRecordingPanelView`. The engine exposes `lastRecordID` (cleared on each new session) so the LLM step can update that entry instead of creating a second one. A successful retry clears any refinement, since it described text that no longer exists.

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
| `elevenLabsAPIKey` / `elevenLabsModel` | ElevenLabs key and Scribe model | empty / `"scribe_v1"` |
| `selectedLanguage` | Locale identifier or `"auto"` | `"auto"` |
| `hotkeyKeyCode` / `hotkeyModifierFlags` | Inline recording hotkey | `12` (Q) / Control+Shift |
| `recordWindowHotkeyKeyCode` / `recordWindowHotkeyModifierFlags` | Record window hotkey | `13` (W) / Control+Shift |
| `aiHotkeyKeyCode` / `aiHotkeyModifierFlags` | AI recording hotkey | `0` (A) / Control+Shift |
| `hotkeyLayoutVersion` | Shortcut-layout migration marker | `0` (unmigrated) |
| `llmProvider` | LLM backend (`"groq"`, `"anthropic"`, `"openai"`) | `"groq"` |
| `groqLLMModel` | Groq chat model ID | `"llama-3.3-70b-versatile"` |
| `anthropicAPIKey` / `anthropicModel` | Anthropic key and model | empty / `"claude-opus-5"` |
| `openAIAPIKey` / `openAIModel` | OpenAI key and model | empty / `"gpt-5.6-terra"` |
| `promptPresets` | JSON-encoded `[PromptPreset]` | built-in defaults |
| `defaultPresetID` | UUID of the fallback preset | Clean-up |
| `aiModeInRecordWindow` | Record Window ✨ toggle state | `false` |
| `webhookURL` | Webhook endpoint URL | empty |
| `authToken` | Webhook Bearer token | empty |
