# Adding a provider

How to add a speech engine, an AI Rewrite provider or a model, and how to change what
providers can do. The `add-provider` skill (`.claude/skills/add-provider/`) follows this
guide.

Two rules before any code:

- **Open an issue first.** A new vendor is a new place user audio or text goes. The
  maintainer agrees to the vendor before the PR.
- **Measure, don't recall.** Every vendor fact in the code carries the date it was checked
  against the live API. Vendor docs have been wrong before.

## 1. Pick the shape

| The vendor offers | What you write |
|---|---|
| An endpoint that takes an audio file | a `BatchSTTProvider` struct (~80 lines) |
| A WebSocket with live text | a `StreamingSTTProvider` (~500 lines) **plus** an upload model from the same vendor |
| OpenAI-compatible `/chat/completions` | a case returning `OpenAICompatibleLLMProvider(baseURL:dialect:)` |
| Its own chat API | a `LLMChatProvider` struct, like `AnthropicLLMProvider` |
| A new model for a vendor already here | a catalogue entry (section 3) |
| A model that runs on the Mac | **stop**: that is a new dependency, the maintainer's decision |

Capabilities belong to the **model**, not the provider: Scribe v2 and Scribe v2 Realtime
are one provider, one key, two catalogue entries. All capability values:

| Field | Value | Meaning |
|---|---|---|
| `Delivery` | `.upload` | file sent after the segment ends |
| | `.realtime(RealtimeShape)` | WebSocket, text while speaking |
| | `.onDevice(LocalSTTEngine)` | model on the Mac |
| | `.systemRecognizer` | Apple's recogniser |
| `TranscriptForm` | `.cumulative` | each message restates the segment |
| | `.incremental` | each message has only new words |
| `LanguageSupport` | `.localeRequired` | needs a locale, cannot detect (Apple) |
| | `.single` | one language or none |
| | `.set` | a list of candidates (`gpt-live-transcribe`) |
| `BatchUpload` | `.itself` | uploads under its own ID |
| | `.model(id)` | realtime model's upload twin, same vendor |
| | `.selectedModel(of:)` | borrows another vendor's pick (Apple → Groq) |
| `Requirement` | `.none` / `.apiKey(key)` / `.installedModel` | what must exist before it runs |
| `Vocabulary` | `.none` / `.termList(TermListLimits)` | takes the user's term list, and its limits |
| `Dialect` (chat) | `.classic` | `max_tokens` + `temperature` (Groq) |
| | `.reasoning` | `max_completion_tokens` + measured `reasoning_effort` (OpenAI) |

A vendor that fits none of these is a change to this table (section 9), not a special
case in a `switch`.

## 2. Measure first

With a real key; write the date next to each answer. `scripts/provider-test-clips.sh`
makes the audio clips.

**Speech**
- Silence (`silence-2s.flac`): a model that invents text from silence is not offered.
- Shortest clip (`short-0.3s.wav`): text or empty, not an error.
- FLAC (`speech-en.flac`) accepted, whatever the docs say.
- Language: parameter name; single, list or none; what happens when it is omitted
  (detects, or assumes English?).
- Defaults that leak into text (audio tags, speaker labels): switch them off explicitly.
- Term list: is there a *list* parameter (not a free-text prompt), its count and length
  limits, forbidden characters, and any price change.
- Error body shape for a bad key, bad model, bad file.
- Quality on **real** speech. `say` output tells you nothing about quality.

**Realtime, also:** exact sample rate · cumulative or incremental text · server VAD or
client commit · which message means "ready" · minimum commit size · echoes of committed text.

**Chat:** which parameters each model rejects (HTTP 400 loses the rewrite) · how to turn
reasoning off, and the latency with and without · how a refusal arrives · whether the
`<<mode:NAME>>` marker comes back intact on real dictations.

**Key:** its prefix (must not match another vendor's; `sk-` is shared, so if it collides,
no clipboard pick-up) · a free authenticated request for the key check (usually `GET /models`).

## 3. A new model for a vendor already here

- Speech: one `STTModelDescriptor` in `sttModelCatalog`, with a dated comment. Update
  `testPickersKeepTheirOrderAndNames`.
- Chat: one tuple in `…ChatModels`; a new model family gets a `payload` branch and a
  `LLMRequestPayloadTests` case.
- **Changing a default is a trap.** `defaultOpenAISTTModel` / `defaultElevenLabsModel` are
  also a catalogue entry's ID and the realtime model's fallback. Moving the constant
  removes the old model and migrates its users. Instead: give the old entry a literal ID,
  add the new one, move the constant, and decide whether the fallback moves too. Pin
  tests to literal IDs.
- Retiring a model: remove it; `normalizeStoredProviders` moves its users to the default.
- The vendor's name is already everywhere, so `check-provider-guide.sh` cannot help here.

## 4. Upload speech engine

1. Add the case to `STTProviderType` and `STTVendor`, build, and fill every `switch` the
   compiler reports.
2. Write the provider in `STTProvider.swift`, copying `GroqSTTProvider`:
   - own `URLSession` with the `STTTuning` batch timeouts;
   - `multipartAudioPart(for:)` for filename and MIME type (FLAC or WAV);
   - `language == nil` means "let the model detect": send nothing, or the vendor's
     detect switch if it otherwise assumes English. Never send a guess;
   - `validatedHTTPResponse` + an error enum using `providerErrorMessage`;
   - let `URLError` through unwrapped (offline detection reads it);
   - a term-list parameter: take `keyterms` in `init` from `configuration.batchVocabulary`
     (realtime: `liveVocabulary`), and set the entry's `vocabulary` limits;
   - log sizes, timings and counts, never text, terms or keys; Foundation only, no SDK.
3. Catalogue entries, a model key in `SettingsKeys` + `portable`, the picker
   (`pickerModels(of:)`), a `normalizeStoredModel` line.
4. `RecordingConfiguration`: key and model as `var` with defaults; read in `current()`.
5. `makeBatchProvider` and `makeRecognitionSession`.

## 5. Realtime speech engine

Read CLAUDE.md's streaming sections first. The rules:

- **An upload twin is required**: `batchUpload: .model(id)` from the same vendor. A failed
  or dropped stream is finished by uploading the same audio.
- Follow the `StreamingSTTProvider` protocol comments: `send` never blocks, `finish()` pads
  the tail with silence and waits a bounded time, `connect` once per instance.
- Events are **cumulative per segment**; accumulate deltas inside the provider.
  `.committed` means the segment ended at a pause.
- Hold audio until the session is ready (bounded buffer); if it fills, emit `.failed`,
  never drop audio.
- Keep the lock order: `sendLock` before `lock`, and never hold `lock` across `task.send`.
- Add the vendor's "no session" error to `StreamReconnectPolicy.isReconnectable`.
- If the vendor uses one model name on both endpoints, coin a realtime ID
  (`<model>-realtime`) and map it back in the provider.
- Start from the closer existing provider: ElevenLabs (cumulative, server VAD) or OpenAI
  (incremental, client commit).

## 6. AI Rewrite provider

- OpenAI-compatible: a case in `LLMConfiguration.makeProvider` with `baseURL` and a
  `Dialect`. Parameters that fit neither dialect → a new `Dialect`, not a name check.
- Own API: a struct like `AnthropicLLMProvider`; build the request body in a pure
  function so it can be tested.
- Either way: `LLMProviderType` case, `…ChatModels` (fastest good model first) and a
  default, `SettingsKeys` model key + `portable` + `normalizeStoredModel`.
- Throw on any failure; the app falls back to the raw transcript.

## 7. The key

- `SettingsKeys.<vendor>APIKey` in `APIKeyStore.keys`. **Never** in `portable`.
- A `SetupService` case: key page, create note, `looksLikeKey`, `verificationRequest`.
- A row in Settings › API Keys (`apiKeys`, with roles).
- A vendor with speech and chat has **one** key.

## 8. UI, tests, docs

- UI: model pickers on the Speech / AI Rewrite pages. In setup, the branches with
  `default:` (Onboarding.swift) must not save a new vendor as Groq. Whether it gets a
  setup card is the maintainer's call.
- Tests: new files go in **both** targets in `project.pbxproj`. Test request builders and
  parsers as pure functions; realtime vendors get a `DictationReplay` script with a drop.
- Docs: README (engine table and **privacy list**), SECURITY.md, CLAUDE.md (component
  bullet, Settings Keys table), CHANGELOG, manual-testing rows.

## 9. Keeping this guide true

A PR that changes the provider abstractions updates this guide:

- a new value or field in the capability table;
- a new place a provider must be registered (add a row below);
- a changed realtime rule, a new `Dialect`, a step of #55.

CI runs `scripts/check-provider-guide.sh`. It fails when a place named below no longer
exists, or when the code has a capability value the table in section 1 does not list. It
cannot notice a new place that nobody added below; that is for the reviewer.

## Touchpoints

Places the compiler does not point to. `scripts/check-provider-guide.sh KINDS VENDOR`
(e.g. `stt,key,docs deepgram`) shows which ones do not mention the new vendor yet.
Kinds: `stt`, `realtime`, `llm`, `key` (a new API key), `docs`. Check: `compiler` = a
`switch` the build reports; `manual` = the block at the anchor must name the vendor;
`manual:file` = the file must (coarse); `review` = check by hand.

```touchpoints
# kind   | file                                                  | anchor (must exist in the file)               | check       | what to do
stt      | SpeechText/SpeechText/STTProvider.swift               | enum STTProviderType                          | compiler    | case, displayName, subtitle (key? live text? what it is good at)
stt      | SpeechText/SpeechText/STTProvider.swift               | protocol BatchSTTProvider                     | manual:file | the provider struct and its error enum
stt      | SpeechText/SpeechText/STTProvider.swift               | func makeBatchProvider                        | compiler    | a case returning the provider with configuration.batchModel
stt      | SpeechText/SpeechText/STTProvider.swift               | private func providerErrorReason              | review      | a candidate for a new error JSON shape, and a ProviderErrorMessageTests case
stt      | SpeechText/SpeechText/STTModelCatalog.swift           | enum STTVendor                                | compiler    | case, displayName, apiKeyPhrase; and STTProviderType.vendor below it
stt      | SpeechText/SpeechText/STTModelCatalog.swift           | let sttModelCatalog                           | manual      | one descriptor per model, with a dated comment on why it is offered
stt      | SpeechText/SpeechText/RecordingConfiguration.swift    | struct RecordingConfiguration                 | manual      | key and model as defaulted vars; read both in current()
stt      | SpeechText/SpeechText/RecordingConfiguration.swift    | private func modelID(for vendor               | compiler    | the vendor's model field
stt      | SpeechText/SpeechText/RecordingConfiguration.swift    | private func apiKey(for vendor                | compiler    | the vendor's key field
stt      | SpeechText/SpeechText/RecognitionSessionFactory.swift | func makeRecognitionSession                   | compiler    | add the case to the cloud list
stt      | SpeechText/SpeechText/Settings.swift                  | enum SettingsKeys                             | manual      | the model key, and in portable (never the API key)
stt      | SpeechText/SpeechText/Settings.swift                  | let groqModels = pickerModels                 | manual:file | <vendor>Models = pickerModels(of:), default (and realtime) model constants
stt      | SpeechText/SpeechText/Settings.swift                  | func normalizeStoredProviders                 | manual      | a normalizeStoredModel line
stt      | SpeechText/SpeechText/MenuBarView.swift               | private var speechPage                        | compiler    | model picker; a SettingsNote for a realtime model
stt      | SpeechText/SpeechText/MenuBarView.swift               | struct SpokenLanguagesField                   | review      | the caption, only if the engine takes a language set
stt      | SpeechText/SpeechText/Onboarding.swift                | Setup run again: open on what is set up now   | manual      | map the stored engine to its service (default: break hides a new one)
stt      | SpeechText/SpeechText/Onboarding.swift                | func continueFromSpeech                       | manual      | a vendor with no card must not fall into case .groq, .anthropic; a card that promises live words saves the realtime model
stt      | SpeechText/SpeechTextTests/PureLogicTests.swift       | func testPickersKeepTheirOrderAndNames        | manual      | the new picker's ids and names
realtime | SpeechText/SpeechText/StreamingSTTProvider.swift      | protocol StreamingSTTProvider                 | manual:file | the provider class
realtime | SpeechText/SpeechText/StreamingSTTProvider.swift      | func makeStreamingProvider                    | compiler    | a case returning the realtime provider
realtime | SpeechText/SpeechTextTests/PureLogicTests.swift       | func testRealtimeShapesMatchTheirProviders    | manual      | its provider ternary covers two vendors only
realtime | SpeechText/SpeechTextTests/PureLogicTests.swift       | func testEveryRealtimeModelFallsBackToAnUploadModelOfItsOwnVendor | manual | the realtime model IDs, listed by hand
realtime | SpeechText/SpeechText/NetworkFailure.swift            | static func isReconnectable                   | manual      | the vendor's own "no session" error, or its stream is never reconnected
llm      | SpeechText/SpeechText/LLMProvider.swift               | enum LLMProviderType                          | compiler    | case, displayName, needsAPIKey
llm      | SpeechText/SpeechText/LLMProvider.swift               | let openAIChatModels                          | manual:file | <vendor>ChatModels next to the others, and default<Vendor>Model
llm      | SpeechText/SpeechText/LLMProvider.swift               | static func makeProvider                      | compiler    | OpenAICompatibleLLMProvider(baseURL:dialect:) or a new struct
llm      | SpeechText/SpeechText/LLMProvider.swift               | static func model(for type: LLMProviderType)  | compiler    | the stored model key and default
llm      | SpeechText/SpeechText/Settings.swift                  | enum SettingsKeys                             | manual      | the chat model key, and in portable
llm      | SpeechText/SpeechText/Settings.swift                  | func normalizeStoredProviders                 | manual      | a normalizeStoredModel line
llm      | SpeechText/SpeechText/MenuBarView.swift               | private var aiPage                            | compiler    | model picker
llm      | SpeechText/SpeechText/MenuBarView.swift               | private var hasLLMKey                         | compiler    | the key (or model) that makes it configured
llm      | SpeechText/SpeechText/Onboarding.swift                | func continueFromAI                           | manual      | default: .groq hides a new service
llm      | SpeechText/SpeechTextTests/PureLogicTests.swift       | final class LLMRequestPayloadTests            | manual      | each model family's body, and what it must not carry
key      | SpeechText/SpeechText/Settings.swift                  | enum SettingsKeys                             | manual      | <vendor>APIKey
key      | SpeechText/SpeechText/APIKeyStore.swift               | static let keys                               | manual      | the key constant
key      | SpeechText/SpeechText/LLMProvider.swift               | static func apiKey(for type: LLMProviderType) | compiler    | only if the vendor serves AI Rewrite
key      | SpeechText/SpeechText/SetupServices.swift             | enum SetupService                             | compiler    | key page, create note, looksLikeKey, verificationRequest
key      | SpeechText/SpeechText/MenuBarView.swift               | private var apiKeys: [APIKey]                 | manual      | an APIKey with its roles and active:
key      | SpeechText/SpeechTextTests/OnboardingTests.swift      | func testKeyShapesTellTheServicesApart        | manual      | its shape, and no overlap with the others
key      | SpeechText/SpeechText/Onboarding.swift                | func continueFromSpeech                       | manual      | a service with no speech engine belongs in the branch that saves none
key      | docs/development.md                                   | ## API keys                                   | manual      | the list and count of keys
key      | docs/manual-testing.md                                | Відкритого тексту не лишилось                 | manual      | the key in the loop that checks no plain-text copy is left
key      | CLAUDE.md                                             | `APIKeyStore.shared`: the four API keys       | review      | the count of keys (and the same words in APIKeyStore.swift)
docs     | README.md                                             | ## Privacy: where your audio goes             | manual      | the privacy list (and the engine table or AI sentence above it)
docs     | SECURITY.md                                           | The privacy practices of                      | manual:file | add the vendor
docs     | CLAUDE.md                                             | ## Settings Keys Reference                    | manual      | the new keys, and the provider file's Architecture bullet
docs     | CHANGELOG.md                                          | ## [Unreleased]                               | manual:file | an Added entry
docs     | docs/manual-testing.md                                | ## Журнал прогонів                            | manual:file | rows for the vendor, in a section above the run log
```
