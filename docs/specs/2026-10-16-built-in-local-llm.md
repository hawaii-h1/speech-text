# SPEC: AI Rewrite on this Mac without Ollama (llama.cpp, built in)

- **Status:** Phases 0–6 implemented 2026-10-16, uncommitted; phase 0 measured (see *Phase 0 results*); the gate — which models to offer — is the owner's
- **Date:** 2026-10-16
- **Base revision:** `7b83bbb`
- **Scope:** new files (`LocalLlamaRuntime.swift`, `LocalChatCatalog.swift`, `ChatTemplates.swift`, a local binary package); from what exists — `ChatClients.swift` (`LLMProviderType`, `chatModelCatalog`, `LLMConfiguration.makeChatClient`), `ProviderRegistry.swift`, `LocalModelStore.swift`, `LocalModelCatalog.swift` (`firstFitting`, `MacTier`), `Ollama.swift` (`localLLMPicks`), `SettingsEngines.swift`, `OnboardingScreens.swift` / `SetupServices.swift` (`SetupCards`), `HomeSummary.swift` (`ListPrice`), `SpeechTextEvaluation`, packaging scripts
- **Does not touch:** `TextRefinementService` prompts and parser, `InlineDelivery`, the speech tiers, `PasteService`

## What it is

Today "On this Mac" for AI Rewrite means Ollama: a separate app the user installs, starts and keeps updated (the setup screen says "Open Ollama" when it is not running). This adds a second local path that needs nothing else installed: SpeechText downloads a GGUF model into `Application Support/SpeechText/Models/` and runs it in-process through llama.cpp, the way Parakeet and Whisper already run for speech.

Ollama is **removed** (D1): the built-in path replaces it. The rewrite prompt, the parser, the fallbacks and History are unchanged: the new path is one more `ChatClient`.

## Why llama.cpp, not MLX

Prior research (speech-text-private/research/2026-09-21-local-llm-without-ollama.md, …-how-oss-apps-run-local-llm.md) and a check of build b11696 on 2026-10-16:

- MLX needs `swift-transformers`, which another app's `Package.swift` documents as unable to resolve alongside `argmax-oss-swift` (WhisperKit) at 1.3 — a conflict in *our* graph. llama.cpp ships as a prebuilt binary `xcframework` with no Swift package graph at all.
- The official `llama-<build>-xcframework.zip` (67 MB zipped): dynamic `llama.framework`, macOS slice universal arm64 + x86_64, **24 MB** (≈12 MB arm64 only), links only Foundation / Metal / Accelerate / libc++, minimum macOS 13.3, signed ad hoc only.
- Every build is a GitHub *prerelease*, several a day, no semver; `llama.h` carries 40 `DEPRECATED` marks. We pin one build and move deliberately.
- The C API has **no Jinja**: `llama_chat_apply_template` knows 54 built-in templates (`chatml`, `gemma`, `gpt-oss`, …). Prompt formatting and switching reasoning off are ours to write per model family — the main work and the main source of silent errors.

ROADMAP's rule for a fourth dependency applies: it must earn its place by a measurement, and one file names it. Phase 0 is that measurement.

## Phases

### Phase 0 — measurement spike (go / no-go)

Nothing in the app yet. Goal: numbers to decide on, and a template check.

1. Local package `Packages/LlamaBinary/` with `.binaryTarget(url:checksum:)` at the pinned ggml-org release (D5). Added to the `SpeechTextEvaluation` target only.
2. `LocalLlamaRuntime.swift` minimal: load GGUF, render prompt, greedy/low-temp sampling, stop tokens, max tokens, return text + token counts + timings.
3. `SpeechTextEvaluation --rewrite <fixtures>`: runs each text fixture through the app's real `TextRefinementService` prompt + parser against (a) the local runtime per model, (b) Groq `openai/gpt-oss-120b` as the quality reference (key from env). Output to `<SPEECHTEXT_RUNS>/<date>/rewrite-summary.md`.
4. **Fixtures are text, not audio** — AI Rewrite's input is a transcript. ~20 written in the shape STT really produces: Ukrainian with English terms, hesitations left in, missing or odd punctuation, Scribe's trailing `...`, routing requests stacked ("зроби список, англійською, коротко"), a code-editor context where an instruction is content, an edit (`<selected_text>` + `<instruction>`). Each with the expected mode and must-keep / must-not-appear checks. Generated fixtures are cleaner than real speech; a private set of real History transcripts can be run the same way from outside the repo, never committed.
5. Template check: render the same messages with our formatter and with `llama-server --jinja` (the model's own template, from the `macos-arm64` release tarball) and diff the token strings.
6. Models: Gemma 4 12B and Qwen3.5 9B (the two measured winners at 16–32 GB via Ollama), Qwen3.5 4B for 8 GB, Qwen3.8 27B, all Q4_K_M from HuggingFace, plus gpt-oss 20B in its MXFP4 GGUF (hf.co pulls work on this Mac; Ollama's CDN does not).
7. Measure per model: cold load, warm time to first token, total per dictation, RSS, routing accuracy, must-keep failures, Ukrainian → Russian drift, reasoning leaking into the reply.

**Gate:** the owner decides on the numbers whether to go on, and with which models.

### Phase 1 — the pure half (both test targets)

- `LocalChatCatalog.swift`: `LocalChatModel` — id, display name, HF repo + file(s), SHA-256, bytes, RAM floor, `ChatTemplateFamily`, reasoning control, context size, summary. Picks per `MacTier` reusing `firstFitting` / `TierPicks`.
- `ChatTemplates.swift`: render system + user messages for `chatml` (Qwen, with the empty `<think></think>` prefill that switches reasoning off), `gemma` (Gemma 4 — verify against its Jinja in phase 0), `harmony` (gpt-oss: `Reasoning: low`, reply read from the `final` channel only). Stop strings per family.
- Tests: each family's rendering written out literally (as `ChatRequestBodyTests` does for cloud bodies), reasoning stripped, Harmony parsing, catalogue invariants (every entry has a family, sizes and hashes, picks present per tier).

### Phase 2 — runtime and client

- **Out of process from the start (D3).** An XPC service target (`SpeechTextLLM.xpc`, in `Contents/XPCServices`) links `llama.framework`; the app does not link it at all, so the test bundle and the app's own memory are untouched and a crash in llama.cpp ends the service, not the dictation (the client sees an interrupted connection, and AI Rewrite falls back to the raw transcript as for any LLM failure, then relaunches the service on the next request). The protocol is small: `load(modelPath)`, `complete(system, user, maxTokens) -> reply + token counts + timings`, `cancel()`, `unload()`. Idle unload is the service exiting.
- `LocalLlamaRuntime.swift` — the only `import llama`, compiled into the XPC service and `SpeechTextEvaluation` (phase 0 runs it in-process). An actor holding one loaded model, jobs strictly one at a time (as `WhisperKitPipelineCache`), unload after an idle period (D-later: 5 min like Ollama), cancellation through the abort callback, a refusal to load when free memory is under the model's floor.
- `LocalChat` registration box + `registerLocalChat()` at launch, as `LocalSTT`; unregistered it throws (`ChatError.noLocalModel`), never returns "".
- `LocalChatClient: ChatClient` — talks to the XPC service through `NSXPCConnection` — returning `ChatReply` with `ChatUsage` from its own token counts, so Usage and History see it like any other provider.

### Phase 3 — provider wiring

Naming (CLAUDE.md § Naming): the standard terms are *on-device* / *local*; the code already calls the Mac `Provider.local`. Proposed: `Provider.local` gains `.chat` with `ModelSetting(SettingsKeys.localLLMModel, default: tier pick)`; `LLMProviderType.local` (stored `"local"`); entries in `chatModelCatalog` derived from `LocalChatCatalog`, priced `.free`. Updates `StoredProviderNameTests`, `ProviderDescriptorTests`, `ChatModelCatalogTests`, `ListPriceTests`, `docs/adding-a-provider.md` and `scripts/check-provider-guide.sh` passes.

### Phase 4 — install

`LocalModelStore` learns chat models: URLSession download with progress and resume into a staging folder, SHA-256 check, move into `Models/llm/<id>/`, prewarm, remove (also unloads). Same `InstallState`s Settings already draws. Multi-file GGUF only if a picked model needs it.

### Phase 5 — UI

- Settings › AI Rewrite › On this Mac: the built-in models as rows with download state (as speech's local models).
- Setup AI step: the "On this Mac" card no longer says "Needs the free Ollama app"; it offers the tier's recommended model.
- Intel (D6): the path stays available, with a warning under the card and in Settings that on Intel the model runs on the processor and a rewrite takes far longer (figure unmeasured — no Intel Mac here).

### Phase 5b — removing Ollama (D1)

Delete `Ollama.swift`'s client, service and version checks, `LocalModelsView.swift`'s `OllamaModelManager`, the Ollama rows in Settings and setup, `Provider.ollama` / `LLMProviderType.ollama`. `localLLMPicks` and the tier logic move to `LocalChatCatalog`. `normalizeStoredProviders()` maps a stored `llmProvider = "ollama"` to `"local"` and deletes `ollamaModel` / `ollamaBaseURL`; such an install needs its model downloaded again (a GGUF, not Ollama's store), so AI Rewrite says so rather than failing silently. A remote Ollama (`ollamaBaseURL` on another machine) has no replacement — acceptable before the first public release, when the only install is the owner's. `StoredProviderNameTests` keeps `"ollama"` as a name History's ledger may still hold (`UsageEvent.vendor`) so old records decode.
- Privacy & Data › What leaves this Mac, Home's Engines, Usage ("Free on this Mac") read the new provider.

### Phase 6 — packaging and docs

- Embed and sign `llama.framework` under the hardened runtime in `rebuild.sh` and `package-release.sh`; notarization run; the arm64-only slice if D6 says so.
- `ThirdPartyNotices.txt` via `scripts/third-party-notices.sh` (llama.cpp / ggml, MIT), `ThirdPartyNoticesTests`.
- CLAUDE.md (three → four dependencies, new files, the test subset list), ROADMAP's dependency record with the phase 0 numbers.

### Later, not in this plan

Models above gpt-oss 20B, streaming the reply.

## Phase 0 results (2026-10-16, M1 Pro 32 GB, llama.cpp b11696)

`SpeechTextEvaluation --rewrite`: 21 generated fixtures (SpeechTextTests/Rewrite/rewrite-fixtures.json) × 2 runs, the app's own built-in presets, prompt and parser; top-k 40, top-p 0.95, temperature 0.3, seed 42, 8K context. Runs in speech-text-private/corpus-runs/2026-10-16_*_rewrite. Times are with the system prompt's state restored (below); every template matched the model's own Jinja token for token (`llama-server --jinja` `/apply-template`).

| Model | passed | mode reported right | median | p90 | generation | load |
|---|---|---|---|---|---|---|
| Groq gpt-oss 120B (reference, free tier) | 31/42 | 31/42 | 0.7 s | 5.9 s (rate-limit waits) | — | — |
| **Gemma 4 12B** QAT Q4_0 | **40/42** | **40/42** | 2.4 s | 3.8 s | 21 tok/s | 3.7 s |
| gpt-oss 20B MXFP4 | 38/42 | 34/42 | 2.1 s | 2.7 s | 45 tok/s | 6.8 s |
| Qwen3.5 9B Q4_K_M | 36/42 | 32/42 | 2.5 s | 4.2 s | — | 2.8 s |
| Qwen3.8 27B Q4_K_M | 36/42 | 28/42 | 7.9 s | 12.1 s | 6.6 tok/s | 10.6 s |
| Qwen3.5 4B Q4_K_M | 30/42 | 8/42 | 1.4 s | 2.0 s | — | 1.6 s |

The rows come from three runs of the same tool and fixtures: Groq, 4B and 9B first; Gemma and 27B next; gpt-oss again after the Harmony parser fix below. Between them one check was loosened ("first aid" → "aid": the models write "First-aid kit"), which touches one fixture and none of the ordering.

Memory: the runs' `phys_footprint` figures (0.5–3.5 GB) leave out the model's weights, which are mapped from the file and wired by Metal; a model needs about its file size (2.7–19 GB) plus that, which is what the catalogue's memory floors allow for.

No model drifted into Russian or leaked reasoning into the reply. What failed:

- **Every model, Groq's included,** obeyed a dictated instruction in a code editor ("перепиши цей файл англійською…") instead of typing it — the prompt's code-editor rule does not hold; a prompt matter, not a local one.
- **Abbreviated mode names** (`<<mode:Email>>`, `<<mode:Technical>>`) from Groq 120B, gpt-oss 20B and Qwen: the parser drops a name no preset has, so History loses the prompt's name; the text is unaffected. Counted as "no marker", not as a failure.
- **Qwen3.5 4B** routes badly — plain clean-ups written as emails — and often omits the marker. Usable on 8 GB, but the online services are the better answer there.
- **Qwen3.8 27B** is not better than Gemma 4 12B on these fixtures and is three times slower (6.6 tokens/s on an M1 Pro).
- **gpt-oss 20B** writes its final channel's header three ways (`final<|message|>`, `final <|constrain|>…<|message|>`, and once with no `<|message|>`); `ChatTemplates.reply` reads all three since this run (4 empty replies before).

**Latency, and what changed because of it.** Reading the ~880-token system prompt is most of a local rewrite: six seconds of Gemma 4 12B's eight. The runtime now saves the model's state after the system prompt and restores it (two states: dictation and Edit), and an AI dictation asks the service to load the model and read both while the user speaks. Through the real XPC service, signed with the hardened runtime and a Developer ID as `rebuild.sh` signs it: cold 14 s; once the prewarm has finished, 1.3–2.9 s (gpt-oss 20B 1.3–1.5, Qwen3.5 9B 1.9–2.1, Gemma 4 12B 2.0–2.9). The prewarm takes 7–10 s, so a short dictation after the service went idle waits for the rest of it: Gemma 4 12B answered 9.0 s after a stop with no speech before it and 5.6 s after 3 s of speech. The service exits after 5 minutes idle; keeping it longer, or saving the system prompt's state to disk so a fresh service restores it, would close that gap — not built, the owner's call. Two measurement traps were found on the way: `llama_decode` returns before Metal finishes (so the prompt must be synchronised before it is timed), and the generation loop must not sample with top-p alone (it sorts the whole 248–262K vocabulary per token).

**Gate** (owner, 2026-10-17: the proposal stands for now; model choice is being reworked in the MB session): Gemma 4 12B the recommendation from 16 GB up (as now); gpt-oss 20B, not Qwen3.8 27B, the best-quality pick for 24 GB+ — better on these fixtures and four times faster; Qwen3.8 27B dropped or kept only as a listed option; Qwen3.5 4B for 8 GB with the online services recommended beside it. Unmeasured: base M-chips, 8/16 GB Macs, Intel, and real History transcripts (run the same tool on a private fixture file).

## Decisions (owner, 2026-10-16)

- **D1 — Ollama is removed**, replaced by the built-in path (phase 5b). D2 follows: "On this Mac" is the built-in path.
- **D3 — XPC from the start.**
- **D4 — Catalogue includes gpt-oss 20B** (`ggml-org/gpt-oss-20b-GGUF`, `gpt-oss-20b-MXFP4.gguf`, 12.1 GB) through the Harmony format, `Reasoning: low` (it cannot be switched off), the reply read from the `final` channel. Phase 0 measures it beside Qwen3.5 4B / 9B, Gemma 4 12B and Qwen3.8 27B. Recommended for 24 GB+ only. Fit per Mac: see *Which Mac runs what*.
- **D5 — Our own local package** with a `binaryTarget` at ggml-org's release URL + checksum.
- **D6 — Intel is not hidden, but warned** (phase 5).

## Which Mac runs what (expectations to confirm in phase 0)

From the Ollama measurements of 2026-09-17 on this Mac (M1 Pro, 32 GB, 200 GB/s): Qwen3.5 2B turned Ukrainian into Russian; 4B usable with misroutes; Qwen3.5 9B and Gemma 4 12B handled all six dictations at 2–4 s, Gemma cleaner; Qwen3.8 27B best text at 5–14 s. Generation speed follows memory bandwidth, so a base M1/M2/M3 (68–100 GB/s) is roughly half as fast as an M1 Pro for the same model.

| Mac | fits (Q4) | expectation |
|---|---|---|
| 8 GB | Qwen3.5 4B (~3 GB) | works, misroutes; cloud (Groq, free) is the honest recommendation |
| 16 GB | Qwen3.5 9B / Gemma 4 12B (6–8 GB) | good quality, ~4–8 s on a base chip, tight beside a browser |
| 24–32 GB | + gpt-oss 20B (12 GB), Qwen3.8 27B (~17 GB) on 32 GB | Gemma 12B the default; 27B for best text |
| Intel | any that fits in RAM | CPU only, slow — warned |

Phase 0 measures on this M1 Pro only; base-chip and 8 GB figures stay estimates until run on such a Mac.

## Risks

- Hand-written templates drift from the model's real one → phase 0's diff against `llama-server --jinja`, and literal rendering tests.
- In-process crash or memory pressure in a menu-bar agent → memory floor check before load, idle unload; XPC if it shows up.
- llama.cpp API churn → pinned build, upgrades as their own PRs with the eval rerun.
- A new model architecture needs a newer build → ships with an app update; the catalogue lists only what the pinned build loads (phase 0 loads each).
