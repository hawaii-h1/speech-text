# VoicePeter

macOS menu bar voice-to-text app. Records audio via a global hotkey, transcribes speech, and pastes the result at the cursor position in the previously active app.

## Build & Run

Open `VoicePeter/VoicePeter.xcodeproj` in Xcode and build (Cmd+B) / run (Cmd+R). No external dependencies or package managers — everything uses Apple frameworks.

Target: macOS (native Swift/SwiftUI). The app runs as a menu bar agent (`LSUIElement = true`) with no dock icon or main window.

## Architecture

All source files live in `VoicePeter/VoicePeter/`. There are no tests, no SPM packages, and no third-party dependencies.

### Core Components

- **`App.swift`** — Entry point. `AppDelegate` manages the `NSStatusItem` (menu bar icon/menu). `AppState` orchestrates recording flow, overlay/panel lifecycle, and paste-back.
- **`SpeechEngine.swift`** — Central recording + transcription engine. Manages `AVAudioEngine` for capture, `SFSpeechRecognizer` for Apple on-device STT, and delegates to `BatchSTTProvider` for Groq. Exposes `barLevels` (per-segment RMS) for waveform visualization.
- **`STTProvider.swift`** — `STTProviderType` enum (`.apple`, `.groq`), `BatchSTTProvider` protocol, and `GroqSTTProvider` implementation (multipart POST to Groq Whisper API).
- **`AudioBufferWriter.swift`** — Accumulates `AVAudioPCMBuffer` frames and writes them to a temporary WAV file for batch STT providers.

### Recording Modes

- **Inline recording** — Triggered by global hotkey (default: `Option+Space`). Shows a small floating overlay (`RecordingOverlay.swift`) at the bottom of the screen. On stop, transcribed text is pasted at the cursor in the previously focused app via `PasteService`.
- **Record Window** — Triggered by global hotkey (default: `Option+Shift+Space`). Opens `DirectRecordingPanel.swift`, a floating panel that auto-starts recording and shows waveform + live text. After transcription, displays result with actions: paste at cursor, copy, send to webhook. Supports re-recording.

### Services

- **`HotkeyManager.swift`** — Registers global hotkeys using Carbon `RegisterEventHotKey`. Listens for `hotkeyDidChange` notifications to hot-reload shortcuts.
- **`HotkeyRecorderView.swift`** — SwiftUI view that captures a new keyboard shortcut via `NSEvent.addLocalMonitorForEvents`. Also contains `shortcutDisplayString()` and `keyCodeToString()` helpers.
- **`PasteService.swift`** — Pastes text at cursor by setting the clipboard and simulating `Cmd+V` via AppleScript (primary) or `CGEvent` (fallback). Also handles app activation and accessibility permission checks.
- **`WebhookService.swift`** — Sends transcribed text to a user-configured webhook URL with optional Bearer token auth.

### UI

- **`MenuBarView.swift`** — `SettingsView` form: STT provider picker, Groq API key/model, language, hotkey recorders, webhook URL/token, accessibility permission status.
- **`RecordingOverlay.swift`** — `WaveformBarsView` (reusable animated bar visualization), `RecordingOverlayView`, and `RecordingOverlayPanel` (borderless floating `NSPanel`).
- **`DirectRecordingPanel.swift`** — Full recording panel with states: recording, transcribing, result. Floating `NSPanel`.
- **`ResultPanel.swift`** — Standalone result display panel (copy/send to webhook actions).
- **`Settings.swift`** — `SettingsKeys` constants, `SupportedLanguage` model, `groqModels` list.

## Key Patterns

- **`@Observable` macro** — Used for `SpeechEngine`, `HotkeyManager`, and `AppState` (Swift Observation framework, not Combine).
- **UserDefaults via `@AppStorage`** — All settings stored in standard UserDefaults. Keys defined in `SettingsKeys` enum.
- **`NSPanel` subclasses** — Floating panels use `.nonactivatingPanel` style so they don't steal focus from the user's active app.
- **Carbon Events API** — Global hotkeys use `RegisterEventHotKey` / `InstallEventHandler` from Carbon.HIToolbox (the only way to register system-wide hotkeys on macOS).
- **No app sandbox** — Disabled in entitlements to allow accessibility APIs (`AXIsProcessTrusted`) and global event taps.

## Permissions Required

- **Microphone** — For audio capture (`AVAudioEngine`)
- **Speech Recognition** — For Apple on-device STT (`SFSpeechRecognizer`)
- **Accessibility** — For simulating `Cmd+V` paste via AppleScript/CGEvent. Must be granted in System Settings > Privacy & Security > Accessibility.

## Settings Keys Reference

| Key | Purpose | Default |
|-----|---------|---------|
| `sttProvider` | STT backend (`"apple"` or `"groq"`) | `"apple"` |
| `groqAPIKey` | Groq API key | empty |
| `groqModel` | Groq Whisper model ID | `"whisper-large-v3-turbo"` |
| `selectedLanguage` | Locale identifier | `"en-US"` |
| `hotkeyKeyCode` / `hotkeyModifierFlags` | Inline recording hotkey | `49` (Space) / Option |
| `recordWindowHotkeyKeyCode` / `recordWindowHotkeyModifierFlags` | Record window hotkey | `49` (Space) / Option+Shift |
| `webhookURL` | Webhook endpoint URL | empty |
| `authToken` | Webhook Bearer token | empty |
