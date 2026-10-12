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
| OpenAI's `/audio/transcriptions` shape (Bearer key, `file` / `model` / `language`) | the descriptor's `speechUpload: OpenAICompatibleUpload(url:…)`, no code |
| Its own upload endpoint | a `BatchTranscriber` struct (~80 lines), like `ElevenLabsTranscriber` |
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
| `VocabularyField` (OpenAI-compatible upload) | `.prompt` | the words as Whisper's free-text `prompt` (Groq) |
| | `.keywords` | a `keywords[]` field per term (OpenAI) |
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
2. OpenAI-compatible: fill the descriptor's `speechUpload` (`OpenAICompatibleUpload`: the
   URL, any fixed fields such as Groq's `response_format=json`, and whether the
   vocabulary goes as a `prompt` or as `keywords[]`, and `minimumBilledSeconds` where the
   vendor documents a per-request minimum), add the engine to
   `makeBatchTranscriber`'s `OpenAICompatibleTranscriber` case, and pin its form in
   `UploadBodyTests`. Otherwise write the transcriber in `Transcribers.swift`, copying
   `ElevenLabsTranscriber`:
   - own `URLSession` with the `STTTuning` batch timeouts;
   - the form built by a pure `multipartBody`, pinned in `UploadBodyTests`;
   - `multipartAudioPart(for:)` for filename and MIME type (FLAC or WAV);
   - `language == nil` means "let the model detect": send nothing, or the vendor's
     detect switch if it otherwise assumes English. Never send a guess;
   - `validatedHTTPResponse` throwing `TranscriptionError` with the `Provider`, so the
     message names it (`providerErrorMessage`);
   - let `URLError` through unwrapped (offline detection reads it);
   - a term-list parameter: take `keyterms` in `init` from `configuration.batchVocabulary`
     (realtime: `liveVocabulary`), and set the entry's `vocabulary` limits;
   - metering: implement `transcribeMetered` (with `transcribe` calling it) returning
     the reply's billed seconds or tokens as `SpeechBilling` — extend `SpeechBilling.decode`
     for a new shape and pin it with a literal reply in `UsageLedgerTests` — and `meter`
     (`UsageMeter`: the vendor, the model, the terms sent). A transcriber without them
     leaves no entry in History's ledger and is counted as free;
   - log sizes, timings and counts, never text, terms or keys; Foundation only, no SDK.
3. Catalogue entries, a model key in `SettingsKeys`, and the descriptor's `speechModel`
   (`ModelSetting`: that key and the default). `portable`, normalisation and
   `RecordingConfiguration`'s `apiKeys` / `models` and the Settings picker follow
   from the descriptor. A realtime model's ID gets a constant in Settings.swift, beside
   `elevenLabsRealtimeModel`.
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
- Report a server that never started a session as `TranscriptionError.realtime(provider,
  "no_session", …)`: that is the code `StreamReconnectPolicy.isReconnectable` reopens.
- `RealtimeShape.serverVAD` decides more than segmentation: a server-VAD model's stream is
  trusted only while no segment stays open past `STTTuning.streamLongestTrustedSegmentSeconds`
  (`RecordingConfiguration.longestTrustedStreamSegment`); past it the stop takes the upload.
  Measure the new model on the corpus's `uk-continuous-long` before relying on that limit.
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
  first), a `SettingsKeys` model key and the
  descriptor's `chatModel` (`ModelSetting`); `portable` and normalisation follow.
- Return a `ChatReply`: the text and the reply's token counts as a `ChatUsage` — every
  input token in `inputTokens` (cache reads and writes added in where the API reports them
  apart, as Anthropic's does) and every output token, reasoning included, in
  `outputTokens`. Usage prices these; nil, for an API that reports none, falls back to an
  estimate from the words. Pin the decode with a literal reply in `ChatUsageTests`.
- Throw on any failure; the app falls back to the raw transcript.

## 7. The key

- A `Provider` case and its `ProviderDescriptor` (ProviderRegistry.swift): the name, the
  roles it serves, and an `APIKeyDescriptor` — its `SettingsKeys.<vendor>APIKey` (**never**
  in `portable`), key page, create button and note, prefix, a sample key, and the
  verification request. `APIKeyStore.keys`, the key check, the clipboard pick-up and the
  AI step's reuse of a speech key all follow from it; `ProviderKeyTests` checks the
  prefix against every other provider's.
- The Settings › API Keys row follows from the descriptor (`APIKeyPage.order`, its `roles`
  as tags); nothing to add.
- A vendor with speech and chat has **one** key.

## 8. UI, tests, docs

- UI: the pickers, the API Keys page and the AI Rewrite status are built from the
  descriptors; the compiler names the Settings cases to extend. Add the vendor to
  `SetupCards` if it gets a setup card — the maintainer's call.
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
stt      | SpeechText/SpeechText/Transcribers.swift              | enum STTProviderType                          | compiler    | case, displayName, subtitle (key? live text? what it is good at)
stt      | SpeechText/SpeechText/Transcribers.swift              | protocol BatchTranscriber                     | manual:file | an own-API transcriber struct, if it is not OpenAI-compatible
stt      | SpeechText/SpeechText/Transcribers.swift              | func makeBatchTranscriber                     | compiler    | a case returning the transcriber with configuration.batchModel
stt      | SpeechText/SpeechText/Transcribers.swift              | private func providerErrorReason              | review      | a candidate for a new error JSON shape, and a ProviderErrorMessageTests case
stt      | SpeechText/SpeechText/STTModelCatalog.swift           | var vendor: Provider                          | compiler    | STTProviderType.vendor: the engine's provider
stt      | SpeechText/SpeechText/STTModelCatalog.swift           | let sttModelCatalog                           | manual      | one descriptor per model, with a dated comment on why it is offered
stt      | SpeechText/SpeechText/RecognitionSessionFactory.swift | func makeRecognitionSession                   | compiler    | add the case to the cloud list
stt      | SpeechText/SpeechText/Settings.swift                  | enum SettingsKeys                             | manual      | the model key, named in the descriptor's speechModel (never the API key)
stt      | SpeechText/SpeechText/MenuBarView.swift               | private var speechPage                        | compiler    | the engine in the cloud case; the picker, the descriptor's caption and a realtime model's settingsNote follow
stt      | SpeechText/SpeechText/MenuBarView.swift               | struct SpokenLanguagesField                   | review      | the caption, only if the engine takes a language set
stt      | SpeechText/SpeechTextTests/PureLogicTests.swift       | func testPickersKeepTheirOrderAndNames        | manual      | the new picker's ids and names
stt      | SpeechText/SpeechText/HomeView.swift                  | private var speechEngine                      | compiler    | the engine's line on Home, with its stored model
stt      | SpeechText/SpeechText/HomeSummary.swift               | static func speech(provider: String)          | compiler    | its price a minute, or nil written out (#129)
realtime | SpeechText/SpeechText/StreamingTranscribers.swift     | protocol StreamingTranscriber                 | manual:file | the transcriber class
realtime | SpeechText/SpeechText/StreamingTranscribers.swift     | func makeStreamingTranscriber                 | compiler    | a case returning the realtime transcriber
realtime | SpeechText/SpeechText/NetworkFailure.swift            | static func isReconnectable                   | review      | its "no session" failure must be TranscriptionError.realtime(_, "no_session", _)
llm      | SpeechText/SpeechText/ChatClients.swift               | enum LLMProviderType                          | compiler    | case, displayName, needsAPIKey
llm      | SpeechText/SpeechText/ChatClients.swift               | let chatModelCatalog                          | manual      | the vendor's models with their switches
llm      | SpeechText/SpeechText/ChatClients.swift               | static func makeChatClient                    | compiler    | OpenAICompatibleChatClient(baseURL:dialect:) or a new struct
llm      | SpeechText/SpeechText/Settings.swift                  | enum SettingsKeys                             | manual      | the chat model key, named in the descriptor's chatModel
llm      | SpeechText/SpeechText/MenuBarView.swift               | private var aiPage                            | compiler    | the pick in the cloud case; the picker follows from the descriptor
llm      | SpeechText/SpeechTextTests/PureLogicTests.swift       | final class ChatRequestBodyTests              | manual      | each model's whole request body, written out
llm      | SpeechText/SpeechText/HomeSummary.swift               | static func chat(provider: String, model: String) | review      | its models' token prices, or they show as not priced (#129)
key      | SpeechText/SpeechText/Settings.swift                  | enum SettingsKeys                             | manual      | <vendor>APIKey
key      | SpeechText/SpeechText/ProviderRegistry.swift          | var descriptor: ProviderDescriptor            | compiler    | the Provider case and its ProviderDescriptor: name, roles, and the APIKeyDescriptor (key page, create note, prefix, sample, verification)
key      | SpeechText/SpeechText/SetupServices.swift             | enum SetupCards                               | review      | a setup card on the Speech and AI steps, if the maintainer wants one; SetupCardsTests checks what it saves
key      | docs/development.md                                   | ## API keys                                   | manual      | the list of keys
key      | docs/manual-testing.md                                | Відкритого тексту не лишилось                 | manual      | the key in the loop that checks no plain-text copy is left
docs     | README.md                                             | ## Privacy: where your audio goes             | manual      | the privacy list (and the engine table or AI sentence above it)
docs     | SECURITY.md                                           | The privacy practices of                      | manual:file | add the vendor
docs     | CLAUDE.md                                             | ## Settings Keys Reference                    | manual      | the new keys, and the provider file's Architecture bullet
docs     | CHANGELOG.md                                          | ## [Unreleased]                               | manual:file | an Added entry
docs     | docs/manual-testing.md                                | ## Журнал прогонів                            | manual:file | rows for the vendor, in a section above the run log
```
