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
| An endpoint that takes an audio file | a `BatchTranscriber` struct (~80 lines) |
| A WebSocket with live text | a `StreamingTranscriber` (~500 lines) **plus** an upload model from the same vendor |
| OpenAI-compatible `/chat/completions` | a case returning `OpenAICompatibleChatClient(baseURL:dialect:)` |
| Its own chat API | a `ChatClient` struct, like `AnthropicChatClient` |
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
| `ReasoningOutput` (chat) | `.unchanged` | nothing sent |
| | `.excluded` | `include_reasoning: false` (Groq gpt-oss) |
| | `.hidden` | `reasoning_format: hidden` (Groq Qwen) |

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
- Chat: one `ChatModelDescriptor` in `chatModelCatalog`, with its measured switches
  (`reasoningEffort`, `reasoningOutput`, `refusalFallbacks`) and a dated comment, and its
  whole body in `ChatRequestBodyTests`. An Ollama model is a `LocalLLMModel`, with its
  `reasoningEffort`; its descriptor is derived.
- Changing a default: the `defaultID` of the provider's `ModelSetting` in
  `ProviderDescriptor`, and `testTheDefaultModelsAreTheChosenOnes`. Catalogue entries carry
  literal IDs, so the old model stays offered and whoever stored it keeps it; a realtime
  model's fallback (`batchUpload: .model(id)`) is its own decision. The local tier's
  default reaches installs that never chose: read `preserveInstalledLocalModel` first.
- Retiring a model: remove it; `normalizeStoredProviders` moves its users to the default.
- The vendor's name is already everywhere, so `check-provider-guide.sh` cannot help here.

## 4. Upload speech engine

1. Add the `Provider` case with its `ProviderDescriptor` (section 7) and the
   `STTProviderType` case, build, and fill every `switch` the compiler reports.
2. Write the transcriber in `STTProvider.swift`, copying `GroqTranscriber`:
   - own `URLSession` with the `STTTuning` batch timeouts;
   - `multipartAudioPart(for:)` for filename and MIME type (FLAC or WAV);
   - `language == nil` means "let the model detect": send nothing, or the vendor's
     detect switch if it otherwise assumes English. Never send a guess;
   - `validatedHTTPResponse` + an error enum using `providerErrorMessage`;
   - let `URLError` through unwrapped (offline detection reads it);
   - a term-list parameter: take `keyterms` in `init` from `configuration.batchVocabulary`
     (realtime: `liveVocabulary`), and set the entry's `vocabulary` limits;
   - log sizes, timings and counts, never text, terms or keys; Foundation only, no SDK.
3. Catalogue entries, a model key in `SettingsKeys`, and the descriptor's `speechModel`
   (`ModelSetting`: that key and the default). `portable`, normalisation and
   `RecordingConfiguration`'s `apiKeys` / `models` follow from the descriptor. The
   picker list: `<vendor>Models = pickerModels(of:)`.
4. `makeBatchTranscriber` and `makeRecognitionSession`.

## 5. Realtime speech engine

Read CLAUDE.md's streaming sections first. The rules:

- **An upload twin is required**: `batchUpload: .model(id)` from the same vendor. A failed
  or dropped stream is finished by uploading the same audio.
- Follow the `StreamingTranscriber` protocol comments: `send` never blocks, `finish()` pads
  the tail with silence and waits a bounded time, `connect` once per instance.
- Events are **cumulative per segment**; accumulate deltas inside the transcriber.
  `.committed` means the segment ended at a pause.
- Hold audio until the session is ready (bounded buffer); if it fills, emit `.failed`,
  never drop audio.
- Keep the lock order: `sendLock` before `lock`, and never hold `lock` across `task.send`.
- Add the vendor's "no session" error to `StreamReconnectPolicy.isReconnectable`.
- If the vendor uses one model name on both endpoints, coin a realtime ID
  (`<model>-realtime`) and map it back in the transcriber.
- Start from the closer existing transcriber: ElevenLabs (cumulative, server VAD) or OpenAI
  (incremental, client commit).

## 6. AI Rewrite provider

- OpenAI-compatible: a case in `LLMConfiguration.makeChatClient` with `baseURL` and a
  `Dialect`. Parameters that fit neither dialect → a new `Dialect` or a descriptor field,
  never a check on the model's name.
- Own API: a struct like `AnthropicChatClient`; build the request body in a pure
  function so it can be tested.
- Either way: `LLMProviderType` case, `chatModelCatalog` entries (fastest good model
  first), a `<vendor>ChatModels` picker list, a `SettingsKeys` model key and the
  descriptor's `chatModel` (`ModelSetting`); `portable` and normalisation follow.
- Throw on any failure; the app falls back to the raw transcript.

## 7. The key

- A `Provider` case and its `ProviderDescriptor` (ProviderRegistry.swift): the name, the
  roles it serves, and an `APIKeyDescriptor` — its `SettingsKeys.<vendor>APIKey` (**never**
  in `portable`), key page, create button and note, prefix, a sample key, and the
  verification request. `APIKeyStore.keys`, the key check, the clipboard pick-up and the
  AI step's reuse of a speech key all follow from it; `ProviderKeyTests` checks the
  prefix against every other provider's.
- A row in Settings › API Keys (`apiKeys`, with roles).
- A vendor with speech and chat has **one** key.

## 8. UI, tests, docs

- UI: model pickers on the Speech / AI Rewrite pages. In setup, the compiler points to
  the mappings between a service and what it saves (Onboarding.swift). Whether the vendor
  gets a setup card is the maintainer's call.
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
stt      | SpeechText/SpeechText/STTProvider.swift               | protocol BatchTranscriber                     | manual:file | the transcriber struct and its error enum
stt      | SpeechText/SpeechText/STTProvider.swift               | func makeBatchTranscriber                     | compiler    | a case returning the transcriber with configuration.batchModel
stt      | SpeechText/SpeechText/STTProvider.swift               | private func providerErrorReason              | review      | a candidate for a new error JSON shape, and a ProviderErrorMessageTests case
stt      | SpeechText/SpeechText/STTModelCatalog.swift           | var vendor: Provider                          | compiler    | STTProviderType.vendor: the engine's provider
stt      | SpeechText/SpeechText/STTModelCatalog.swift           | let sttModelCatalog                           | manual      | one descriptor per model, with a dated comment on why it is offered
stt      | SpeechText/SpeechText/RecognitionSessionFactory.swift | func makeRecognitionSession                   | compiler    | add the case to the cloud list
stt      | SpeechText/SpeechText/Settings.swift                  | enum SettingsKeys                             | manual      | the model key, named in the descriptor's speechModel (never the API key)
stt      | SpeechText/SpeechText/Settings.swift                  | let groqModels = pickerModels                 | manual:file | <vendor>Models = pickerModels(of:), and a realtime model's ID constant
stt      | SpeechText/SpeechText/MenuBarView.swift               | private var speechPage                        | compiler    | model picker; a SettingsNote for a realtime model
stt      | SpeechText/SpeechText/MenuBarView.swift               | struct SpokenLanguagesField                   | review      | the caption, only if the engine takes a language set
stt      | SpeechText/SpeechText/Onboarding.swift                | Setup run again: open on what is set up now   | compiler    | the setup service the stored engine opens on, or none
stt      | SpeechText/SpeechText/Onboarding.swift                | func continueFromSpeech                       | manual      | a vendor with no card must not fall into case .groq, .anthropic; a card that promises live words saves the realtime model
stt      | SpeechText/SpeechTextTests/PureLogicTests.swift       | func testPickersKeepTheirOrderAndNames        | manual      | the new picker's ids and names
stt      | SpeechText/SpeechText/HomeView.swift                  | private var speechEngine                      | compiler    | the engine's line on Home, with its stored model
stt      | SpeechText/SpeechText/HomeSummary.swift               | static func speech(provider: String)          | compiler    | its price a minute, or nil written out (#129)
realtime | SpeechText/SpeechText/StreamingSTTProvider.swift      | protocol StreamingTranscriber                 | manual:file | the transcriber class
realtime | SpeechText/SpeechText/StreamingSTTProvider.swift      | func makeStreamingTranscriber                 | compiler    | a case returning the realtime transcriber
realtime | SpeechText/SpeechText/NetworkFailure.swift            | static func isReconnectable                   | manual      | the vendor's own "no session" error, or its stream is never reconnected
llm      | SpeechText/SpeechText/LLMProvider.swift               | enum LLMProviderType                          | compiler    | case, displayName, needsAPIKey
llm      | SpeechText/SpeechText/LLMProvider.swift               | let chatModelCatalog                          | manual      | the vendor's models with their switches; a <vendor>ChatModels picker list below it
llm      | SpeechText/SpeechText/LLMProvider.swift               | static func makeChatClient                    | compiler    | OpenAICompatibleChatClient(baseURL:dialect:) or a new struct
llm      | SpeechText/SpeechText/Settings.swift                  | enum SettingsKeys                             | manual      | the chat model key, named in the descriptor's chatModel
llm      | SpeechText/SpeechText/MenuBarView.swift               | private var aiPage                            | compiler    | model picker
llm      | SpeechText/SpeechText/MenuBarView.swift               | private var hasLLMKey                         | compiler    | the key (or model) that makes it configured
llm      | SpeechText/SpeechTextTests/PureLogicTests.swift       | final class ChatRequestBodyTests              | manual      | each model's whole request body, written out
llm      | SpeechText/SpeechText/HomeSummary.swift               | static func chat(provider: String, model: String) | review      | its models' token prices, or they show as not priced (#129)
key      | SpeechText/SpeechText/Settings.swift                  | enum SettingsKeys                             | manual      | <vendor>APIKey
key      | SpeechText/SpeechText/ProviderRegistry.swift          | var descriptor: ProviderDescriptor            | compiler    | the Provider case and its ProviderDescriptor: name, roles, and the APIKeyDescriptor (key page, create note, prefix, sample, verification)
key      | SpeechText/SpeechText/MenuBarView.swift               | private var apiKeys: [APIKey]                 | manual      | an APIKey with its roles and active:
key      | SpeechText/SpeechText/Onboarding.swift                | func continueFromAI                           | compiler    | the AI Rewrite provider the service saves
key      | SpeechText/SpeechText/OnboardingScreens.swift         | private var onlineDetails                     | review      | a setup card on the Speech and AI steps, if the maintainer wants one
key      | SpeechText/SpeechText/Onboarding.swift                | func continueFromSpeech                       | manual      | a service with no speech engine belongs in the branch that saves none
key      | docs/development.md                                   | ## API keys                                   | manual      | the list of keys
key      | docs/manual-testing.md                                | Відкритого тексту не лишилось                 | manual      | the key in the loop that checks no plain-text copy is left
docs     | README.md                                             | ## Privacy: where your audio goes             | manual      | the privacy list (and the engine table or AI sentence above it)
docs     | SECURITY.md                                           | The privacy practices of                      | manual:file | add the vendor
docs     | CLAUDE.md                                             | ## Settings Keys Reference                    | manual      | the new keys, and the provider file's Architecture bullet
docs     | CHANGELOG.md                                          | ## [Unreleased]                               | manual:file | an Added entry
docs     | docs/manual-testing.md                                | ## Журнал прогонів                            | manual:file | rows for the vendor, in a section above the run log
```
