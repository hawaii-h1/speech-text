# Vendor watch

When a vendor switches a model off, our release moves users off it. That only works if we
know weeks in advance, from the vendor rather than from a "Transcription failed" in
someone's History (#20). Two things keep us informed. One is a script that compares the
catalogues with each vendor's own API. The other is a weekly agent that runs the script,
reads the vendors' deprecation pages and changelogs, and opens an issue when something
changed.

The catalogues give each model a lifecycle state: `current`, `superseded`, `deprecated` or
`retired`, with the vendor's shutdown date once one is announced. A retired model stays in
the catalogue for History's sake and is removed **six months after its shutdown**. Its name
and price go to the permanent archive. The states come from the model-lifecycle work.

## The script

```bash
SPEECHTEXT_VENDOR_WATCH=<folder outside the repository> scripts/check-vendor-models.sh --out report.md
```

- **The catalogues.** The script builds `SpeechTextEvaluation` and runs
  `--export-catalogue`, which writes `sttModelCatalog` and `chatModelCatalog` as JSON
  (`CatalogueExport`, pinned by `CatalogueExportTests`). The script keeps no model list of
  its own. `--catalogue <file>` reuses an export and skips the build.
- **Keys.** The script reads `~/.config/speech-text/test-keys.env` (`OPENAI_API_KEY`,
  `GROQ_API_KEY`, `ELEVENLABS_API_KEY`, `ANTHROPIC_API_KEY`), or the environment. It makes
  every request from Python's `urllib`, so a key never appears on a command line or in the
  report.
- **Snapshots.** Each run keeps the vendors' lists in `$SPEECHTEXT_VENDOR_WATCH/snapshots/`.
  The next run uses them to tell which IDs are new. Without the variable, nothing can be
  called new.
- **CI never runs it:** it needs keys and the network.

### Where each list comes from

| Vendor | Request | What it gives |
|---|---|---|
| OpenAI | `GET /v1/models` | every model the key can use, each with a **`shutdown_date`** once one is announced |
| Groq | `GET /openai/v1/models` | every model, its `active` flag, and **prices** for chat models (`pricing`, dollars per token) |
| Anthropic | `GET /v1/models` (paged) | every model ID; no dates, no prices |
| ElevenLabs | `POST /v1/speech-to-text` and the realtime WebSocket, both with an unknown `model_id` | the validation error names every model the endpoint accepts ("Available models: …", "Supported models: …"). Nothing is transcribed or billed. `GET /v1/models` needs the `models_read` permission, which a speech key often lacks, and lists the voice models besides |
| FluidAudio, argmax-oss-swift | GitHub's releases API | releases newer than the version `Package.resolved` pins |
| Hugging Face | `/api/models/<repo>`, `/api/models?author=…` | each local model's folder or files still in its repository, the repository's last change, and new repositories by FluidInference and argmaxinc |

All of these were checked against real replies on 2026-10-16. Anthropic's list may name
an alias such as `claude-haiku-4-5` only by its dated snapshot
(`claude-haiku-4-5-20251001`), so an alias counts as served when its snapshot is.

The OpenAI and Groq lists are **per account**. A model missing from them means it is not
served *to this key*, which is not necessarily a retirement. The vendor's deprecation page
decides.

### The report

1. **Not checked.** A vendor with no key, no network or an error reply. Its models get
   no alarm, and the run is not an all-clear.
2. **Gone.** A catalogue model, or a realtime model's upload twin, that the vendor no
   longer serves. A model already `deprecated` or `retired` is listed apart, as expected.
3. **Shutdown announced.** The vendor's API gives a shutdown date (OpenAI) or marks the
   model inactive (Groq) while the catalogue still calls it current.
4. **Past their shutdown.** A `deprecated` model whose shutdown date has passed should
   become `retired`. A `retired` one whose six months are over is removed in the next
   release.
5. **Price drift.** Only where the API states prices, which today means Groq's chat
   models. Every other price is checked by hand (docs/prices.md).
6. **New at the vendor.** Relevant IDs that were not served at the previous snapshot.
   Voice, image and embedding models and dated snapshots of an alias are left out. Every
   relevant ID missing from the catalogue is listed below this, folded.
7. **Local models.** Newer package releases, each model's repository and files, and new
   speech repositories.

Exit status: **0** nothing blocks a release, **1** the release rule fails (sections 2 and
7: a model the vendor no longer serves that is not deprecated, or a local model's files
gone from its repository), **2** the export could not be built, **3** some vendor was not
checked.

## Pages the script cannot read

APIs do not say *why* a model goes, *when* it was announced, or *what replaces it*. The
weekly agent reads these pages for that:

| Vendor | Page |
|---|---|
| OpenAI | https://developers.openai.com/api/docs/deprecations |
| OpenAI | https://developers.openai.com/api/docs/changelog |
| Groq | https://console.groq.com/docs/deprecations |
| Groq | https://console.groq.com/docs/changelog |
| Groq | https://console.groq.com/docs/models (preview models can be withdrawn without a deprecation entry) |
| ElevenLabs | https://elevenlabs.io/docs/changelog |
| ElevenLabs | https://elevenlabs.io/docs/overview/models |
| Anthropic | https://platform.claude.com/docs/en/about-claude/model-deprecations |
| FluidAudio | https://github.com/FluidInference/FluidAudio/releases |
| WhisperKit | https://github.com/argmaxinc/argmax-oss-swift/releases |

## The weekly agent

The agent runs once a week as a scheduled task on the maintainer's Mac, since GitHub-hosted
runners are not available to this repository. Its prompt is below. `<repo>` is the main
checkout, and `<watch>` is the private folder that holds the reports and snapshots,
outside the repository.

```text
Weekly vendor watch for SpeechText (docs/vendor-watch.md). Talk to me in Ukrainian; issues in English.

1. Check out fresh origin/main in a detached worktree. Run git -C <repo> fetch origin and git -C <repo> worktree prune. Then run git -C <repo> worktree add --detach /tmp/vendor-watch origin/main, or, if /tmp/vendor-watch exists, git -C /tmp/vendor-watch checkout --detach origin/main. Never commit anything.
2. Run in /tmp/vendor-watch: SPEECHTEXT_VENDOR_WATCH=<watch> scripts/check-vendor-models.sh --out /tmp/vendor-watch-script.md. Never print or quote an API key.
3. Read every page in docs/vendor-watch.md › "Pages the script cannot read". For each model in the catalogue export (the script's report lists what is gone, going and new) note any deprecation, shutdown date, replacement, price change, or a new model relevant to dictation (speech-to-text) or text rewriting.
4. Read the previous report, the newest <watch>/<date>.md before today.
5. Write <watch>/<today>.md: the script's report, then "Pages", with what the pages say and the URL of each claim, then "New since <previous date>".
6. If something needs action and no open issue covers it yet (a catalogue model deprecated or gone, a shutdown date, a replacement, price drift, a new candidate model, a newer FluidAudio or WhisperKit release with models), first search the open issues: gh issue list --label model-lifecycle --state open. Comment on an existing issue for the same model rather than opening a second one. Otherwise open one with gh issue create --label model-lifecycle: the model, vendor, shutdown date, replacement, the source URL, and what to do in the catalogue (lifecycle state, shutdown date, migration target, price). Then tell me in a few lines what you filed.
7. If nothing needs action beyond the open issues, write the report only and tell me "нічого нового" in one line.
8. If the script exits 3 (a vendor was not checked), say which vendor and why. That week is not an all-clear. If it exits 2, the build failed: say so, with the log's path.
```
