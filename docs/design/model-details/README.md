# Model languages

Design only. Nothing here is wired to the app. The data the design needs is in [schema.md](schema.md).
[index.html](index.html) is a self-contained mock-up. Its review bar switches:

- the theme;
- *Languages I speak*;
- the selected model;
- the place (on this Mac / online).

## The problem

The owner lifted the "multilingual local models only" rule on 2026-10-16 so that Phonon-2, which
is English-only, can ship. The condition is that a user can see what to expect from a model,
above all whether it takes their language.

Today the rows answer that for one person only. The lines are hard-coded: "Great for English and
Ukrainian", "Makes mistakes in Ukrainian", "not every language works on-device — Ukrainian among
them". A Spanish speaker reads about Ukrainian, and nothing about Spanish.

## Scope, after review (2026-10-17)

The first draft added a full card per model behind a Details button: maker, evaluations with
sources, sizes, licence. **The owner turned it down as too deep and too noisy for now.** What
stays is the language question alone, answered on the row in as few words as possible.

## The rules

1. **A row names no language unless it is one of yours.** Every language a row mentions comes from
   Dictation › Languages I speak. Row lines say what else the model is good at (speed, size, live
   text) and name no language.
2. **Subtitle: the language count.** It sits beside the size, which local rows already show:
   - "25 languages", "English only", "90+ languages", "99 languages";
   - nothing when the vendor publishes no list (OpenAI) or when macOS decides (Apple).

   This is one fact, the same for everyone.
3. **A missing language gets a badge.** When the model's published list lacks one of your
   languages, the row shows a badge in the warning kind, written in words: "No Spanish". If more
   than one is missing, the badge names the first and adds "+1" and so on.
4. **A known weakness joins the row's line, only for you.** Some notes come from our own
   measurement, such as Whisper Small writing Ukrainian in Russian spelling. Each note is stored
   on the model per language. "Makes mistakes in Ukrainian." is added to the line only for someone
   who speaks Ukrainian.
5. **Apple asks macOS.** Which of your languages work on-device on this Mac is read while the app
   runs. Example: "No Ukrainian on-device".
6. **Unknown stays silent.** An unpublished list never warns. With no languages stated, there are
   no badges and no notes.
7. **One more place: the *Languages I speak* caption.** While the selected model can't take one of
   the listed languages, the caption says: "⚠︎ Phonon-2 can't take Ukrainian. Choose another
   model…". That is where a user adds a language, without thinking of the engine.

The same row component is used by setup › Speech, so setup gets all of this with no separate
design.

## Hard-coded languages to remove (for MC)

Every sentence that names a language for everyone, found on 2026-10-17. Each one becomes a
neutral line plus a `weak`/`missing` note driven by the user's languages:

| File | What |
|---|---|
| `SettingsEngines.swift` `speechModelLine` | "Great for English and Ukrainian…" (Parakeet, Turbo), "Makes mistakes in Ukrainian" (Small, Base) |
| `SettingsEngines.swift` `appleDictationLine` | "…not every language works on-device — Ukrainian among them" (also used by setup, with its own suffix) |
| `SettingsEngines.swift` `aiModelLine` | "Many mistakes in Ukrainian" (qwen3.5:2b), "Not recommended for Ukrainian" (qwen3.5:0.8b) |
| `OnboardingScreens.swift` (Speech step, Intel) | "Private and free, but slow on this Mac and English only." |
| `LocalModelCatalog.swift` `summary` | Ukrainian test results in four summaries. These are only the fallback for an unknown ID, but they are UI text, so they get the same treatment. |
| `Ollama.swift` `summary` | "…our Ukrainian test…", "switched Ukrainian to Russian", "Not recommended for Ukrainian" |

These are not affected: examples of what a user may *say* ("a polite reply, in English" on Home,
Prompts and Settings › AI Rewrite), and the keyboard-layout map in `Settings.swift`.

## Questions for the owner

**(a) The "No Spanish" badge.** Recommendation: **show it on every row that lacks one of your
languages**, not only on the selected one. Tapping a local row starts a download, so the warning
has to come before the tap.

**(b) Language count in the subtitle.** Recommendation: **yes**. It costs two words and is the
same for everyone. The alternative is badges only, which says nothing at all to someone who listed
no languages.

**(c) AI Rewrite.** Recommendation: **do it in the same change.** The local AI model lines hard-code
Ukrainian too (table above), and the same `weak` notes fix them. Chat models get no language count,
since vendors publish none worth showing.

**(d) Language codes beyond `spokenLanguageCatalog`.** The catalogue has 31 languages. Parakeet
lists bg, et, lv, lt, mt and sl, which are not among them, and ElevenLabs uses some ISO 639-3
codes (`yue`, `fil`). Recommendation: a model's list takes any BCP-47 language code and is matched
only against the user's list. Then a count like "25 languages" is the true count, not the overlap
with our catalogue.

## Sources for the facts in the mock-up (checked 2026-10-16)

| Fact | Source |
|---|---|
| Parakeet v3 and Ultra: 25 languages | NVIDIA's model card (nvidia/parakeet-tdt-0.6b-v3), Moondream's (moondream/parakeet-ultra) |
| Ultra: fewer mistakes than v3 in every FLEURS language, same speed | FluidAudio Documentation/ASR/ParakeetUltra.md |
| Phonon-2: English only, fastest v3-family encoder on the Neural Engine | FluidAudio Documentation/ASR/Phonon2.md |
| Scribe v2: 90+ languages | elevenlabs.io/docs/overview/models |
| OpenAI publishes no language list for gpt-transcribe | OpenAI's announcement |
| Whisper Small's Ukrainian | our measurement, already in `LocalModelCatalog.swift` (2026-09-17) |
