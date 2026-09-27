# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **A new Settings window**, laid out like the setup window and split into categories: General, Appearance, Speech, Formatting, AI Rewrite, API Keys and Permissions. Each skin shows a preview of its overlay, in the colours you picked.
- **API Keys lists every key.** The ones your current choices need come first, marked *Added* or *Needed*. Each key is tagged with what it can serve, *Speech*, *AI Rewrite* or both, so a key can be entered before you pick the engine that needs it.
- **Display colours for the techno skin**: green (the original), amber, cyan, white, or any colour of your own. AI mode stays violet whatever you pick.
- **Hold to talk needs only the letter.** Once a hold recording has started you can let go of the modifier keys and keep holding just the letter, so clicks and ⌘Tab work normally while you speak. A small tip beside the overlay teaches this for your first few recordings, and setup and Settings show it too.

### Changed

- **No cancel is silent.** Every cancelled dictation or edit now says so, and why. A dictation cancelled while the AI was rewriting it says it is saved in History. While a dictation is being transcribed or rewritten, the menu's recording items read *Cancel Dictation*.
- **Edit with AI works on what is selected when you finish the instruction**, not what was selected when you started. If you select other text while speaking, that is the text that gets edited.
- Clearer messages when a selection edit can no longer find the text it was asked to change.
- **A dictation made with no connection says where it went.** Instead of "Transcription failed", the notice reads "No connection — saved to History" and offers **Retry**. Once the network is back it is transcribed by itself — only what was saved since SpeechText started — and its text goes to the clipboard with a notice, never into whatever app is in front by then.
- **Live text survives a short outage.** When the connection drops mid-dictation, the live engines (ElevenLabs and OpenAI) reconnect and the overlay keeps showing your words. The text pasted at the stop still comes from the upload, which heard what was said while the connection was down.

## [0.9.1] - 2026-09-24

### Added

- **A disk image that shows how to install.** Opening it shows SpeechText, an arrow and your Applications folder, and says what happens next. Opened straight from the disk image, SpeechText offers to move itself to Applications and starts again from there; once it is installed, setup offers to eject the disk image and move it to the Trash.
- **A setup window on first run**, instead of two unexplained permission alerts. It walks through choosing a speech engine, an optional AI provider, the keys those need, the microphone and Accessibility permissions and whether to launch at login — and ends with a dictation you can try before you rely on it. Close it half-way and it opens where you left it. It is in the menu any time as *Continue Setup…*.
- **Automatic updates.** SpeechText now checks once a day whether a newer version has been released, offers it with that version's release notes, and installs it when you agree — the menu's *Check for Updates…* asks right away. Every update is signed with a key of the project's own, checked before anything is installed.
- **Local speech recognition** with open-source models, run on-device, installed, cancelled or removed with one click. No key, and nothing leaves the Mac. Two engines: **Parakeet v3** — NVIDIA's multilingual model in 25 European languages, through FluidAudio — and Whisper, through WhisperKit.
- Parakeet v3 is now the recommended local model on every Apple Silicon Mac. On a real Ukrainian dictation it matched the best cloud engine word for word where local Whisper misread a word, answered in well under a second, and downloads 483 MB rather than 645 MB. Whisper stays installable and is still what Intel Macs are pointed at.
- **Local AI processing through Ollama**: Qwen3.5 / 3.6 / 3.8, Gemma 4 and gpt-oss, pulled with one click. Any model you already have in Ollama can be picked too.
- **Model recommendations by Mac class**, from an 8 GB MacBook Neo to a 512 GB Mac Studio: each class gets a recommended model (the fastest of good quality) and a best-quality one, and heavier models stay available with a warning.
- **OpenAI as a speech engine**, alongside Groq and ElevenLabs, with your own key: an upload model and a live one that streams words as you speak. It is the newest engine here and the least used, so treat the live model as the rough edge it is. The chat models keep their own setting, and the two share one key.
- **"Languages I speak"** replaces the old single-language picker. Name one and every engine is told it, which is the accuracy win the setting exists for; name several and the engine detects the language itself rather than being handed a guess. Naming several also narrows what the Apple engine picks from your keyboard layout, so a layout you type in but don't speak can no longer decide. Your old choice is carried over once.
- **Edit the selected text with AI** — `Ctrl+Shift+E`. Select text anywhere, press it, optionally say what to change, and the rewrite replaces the selection. With no instruction it polishes; with one, it follows it. If anything fails — no instruction transcribed, the model refuses, the rewrite is identical — your original text is put back exactly as it was, formatting included.
- **Hold to talk**, off by default: hold a dictation shortcut to record and let go to stop, tap it twice to lock recording on hands-free, and a single tap cancels. While a dictation runs, the *other* mode's shortcut switches it between plain and AI, and its own stops it.
- **Escape cancels a dictation** while the overlay is up. Off by default, because for that time Escape belongs to SpeechText and reaches no other app.
- **Dashes** setting: the long `—` that speech models put where you paused is redrawn as a short `–` (the default) or a plain hyphen, or left alone. The dash stays where it was; only the character changes.
- **Hesitation cleanup**, on by default: "е-е-е", "uh", "um", stretched letters and a trailing "..." are dropped from transcripts. Words that merely look like fillers are kept.
- **A Dock icon while a window is open**, so the Settings window can be found again once something covers it. Configurable: never, while a window is open, or always.
- **Shortcut conflict warnings** in Settings: a combination already used by another SpeechText shortcut is refused, and one used by an enabled macOS shortcut is saved with a warning. A shortcut that failed to register says so under the row, instead of silently doing nothing.
- The menu bar's first line says which build is running — version, build number, commit and build date — and copies it when clicked.
- **AI dictations tell the model which app, window and text field they are for**, so the same words come out as a chat message in Slack and as a letter in Mail. Nothing is read from password managers, and only the app's name from a password field.

### Changed

- An inline dictation shows its transcript **on the overlay** as it is built — with a streaming engine or the Apple engine; settled words bright, the words still moving dimmer — and pastes it once, in its final form, when you stop. Live recognition corrects itself a second later ("…we'll do it." becoming "…we'll do it, then"), and text already pasted into another app cannot take that back.
- A dictation is pasted where your cursor is **when you stop**, in whichever app is in front then — not in the app you started in. An AI dictation is written for that app too.
- A delivered dictation now ends with a space, so a second dictation into the same field doesn't start glued to the first.
- AI dictations and selection edits on OpenAI's GPT-5.x models no longer wait for the model to think first — measured at about 0.6 s per dictation spent on reasoning nobody reads.
- The instructions sent with every AI dictation are shorter. Nothing they asked for was dropped; the wording was cut, which leaves more of a free tier's per-minute allowance for your own presets.
- Model catalogues checked against the vendors on 2026-09-16. Groq's retired Llama 3.3 70B, Llama 3.1 8B, Qwen3 32B and Kimi K2 are replaced by gpt-oss 120B / 20B (plus Qwen3.8 27B and MiniMax M2.7 as labelled previews), and a stored retired model moves to gpt-oss 120B. ElevenLabs Scribe v1 and v1 Experimental are replaced by Scribe v2, which is also what a broken realtime stream now falls back to. New defaults: Claude Sonnet 5 and GPT-5.6 Luna.

### Removed

- Message delivery. An AI dictation can no longer be sent to someone through iMessage, Mail, Telegram or WhatsApp, and the app no longer asks for Contacts access.
- Webhook delivery. The Record Window no longer has a send button, and a stored webhook URL and token are deleted at launch.

### Fixed

- AI mode on Groq stopped working on the default model for free and developer accounts when Groq retired Llama 3.3 70B in August 2026.
- ElevenLabs realtime no longer pastes a dictation twice. The stream re-states text it has already committed — grown by the words said since, and with a word or two revised, even when a revision changes the word count ("FN+Q" → "FN плюс Q") — and that was being appended instead of merged.
- A recording stopped a moment after it started no longer fails with "Audio file might be corrupted or unsupported". Anything shorter than 0.3 s is dropped quietly, and a very short upload is sent in a format the engines can read. OpenAI's live model no longer rejects a dictation stopped before its connection was ready.
- The Record Window's ✨ rewrites only the segment you just dictated, instead of rewriting everything above it in that segment's style. A rewrite that would cut the text to less than half is refused and the dictation kept as you said it — unless it went to a preset meant to shorten, such as Notes or Bullets.
- With the Apple engine, a recognition failure at the very start ends the recording at once, with a notice that says what to do — add the language to Dictation, or allow Speech Recognition — instead of leaving the overlay listening to nothing until you stop.
- "Auto (System)" no longer forces the keyboard layout's language on a cloud speech model. Whisper and Scribe detect the language themselves; being told the wrong one made them drop most of a recording and translate the rest. Apple's recogniser, which has no auto mode, still follows the layout.
- The end of a dictation is no longer lost when the connection drops mid-sentence. The upload that takes over re-words the opening slightly, which used to read as a different dictation and stop everything after it from being pasted. Where the text really is unrelated, a notice now says part of the dictation wasn't pasted and opens History, instead of saying nothing.
- Connecting AirPods or unplugging an interface in the middle of a sentence no longer loses the first half of the dictation. A headset that keeps reconnecting ends the recording with what you said rather than looping.
- A word the live stream cut in two ("…база дани" + "х, звідки") is glued back together instead of being pasted with a space in the middle.
- A muted or dead microphone no longer produces "Thank you for watching." Silence is not uploaded, and the recording is kept so you can retry it from History once the microphone works.
- Pasting works on non-QWERTY keyboard layouts. On Dvorak, `Cmd+V` was being sent as whatever key sits in V's place, so a dictation quietly went nowhere.
- Your clipboard is no longer left holding a fragment of your own dictation after a recording that pasted several times, and something you copied while dictating is not overwritten by what was on the clipboard before.
- A dictation no longer lands at the very start of a document when an app reports a nonsense cursor position.
- The model's reply no longer comes back with characters that imitate ordinary ones — a non-breaking hyphen where you dictated a plain one. Nothing on screen tells them apart, and inside a shell command or an identifier the result is a failure with no visible cause. Dashes, quotation marks and emoji are untouched.
- Closing Settings while recording a new shortcut no longer swallows the next keystroke anywhere on the Mac.
- The Debug Log keeps scrolling to the newest line in long sessions.
- Cancelling a recording while a paste is still landing no longer leaves the app waiting for it.

## [0.9.0] - 2026-09-13

First tagged as 1.0.0, renumbered on 2026-09-18: SpeechText is still in a closed beta, and a 1.0 promised more than that.

### Added

- Three recording modes: inline dictation pasted at the cursor, AI dictation rewritten by an LLM before pasting, and a Record Window for longer dictation you want to edit first — each on its own configurable global hotkey.
- Speech engines: Apple on-device (nothing leaves the Mac), Groq Whisper, and ElevenLabs Scribe — including realtime streaming with live partial text, which falls back to a batch upload of the same audio if the stream breaks.
- An LLM pass with prompt presets: the dictation itself is the prompt, and the model routes it to the preset whose "when to use" description matches. Groq, Anthropic and OpenAI are supported. Any failure or refusal falls back to the raw transcript.
- Message delivery (off by default): a dictation that names a person and a channel is resolved against your own Contacts and shown in a confirmation panel before anything is sent. iMessage, Mail, Telegram and WhatsApp.
- History of every transcription, stored locally, with retry from the archived audio for failed or empty results.
- Two skins — minimal and techno — covering the same features, with an optional accent colour for the minimal one.
- Webhook delivery: POST the transcribed text to a URL of your own, with optional Bearer token auth.
- Automatic language detection that follows the active macOS keyboard layout.

[Unreleased]: https://github.com/yavno/speech-text/compare/v0.9.1...HEAD
[0.9.1]: https://github.com/yavno/speech-text/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/yavno/speech-text/releases/tag/v0.9.0
