# Audio corpus

Real recordings played through every speech engine, so that a change to recognition,
or a vendor's model update, shows up as numbers rather than as a feeling after a manual
pass. Traces (`SpeechTextTests/Traces/`) replay what a provider *said*; the corpus
produces that from audio.

## What is where

| | Where | In git |
|---|---|---|
| Clip descriptions: expected text, language, tags, bounds | `SpeechText/SpeechTextTests/Audio/<clip>.json` | yes |
| The recordings, `<clip>.wav` and `<clip>@<variant>.wav` | a folder of your own, passed as `<corpus-dir>` | **no** — it is someone's voice |
| A run: `summary.md`, `results-*.json`, `traces/` | `docs/testing-runs/<date>/` | yes |
| The run's `xcodebuild` logs | the same folder | no (`.gitignore`) |

A description:

```json
{
  "expected": "Завтра ми поїдемо до моря, якщо погода буде теплою і сонячною.",
  "language": "uk",
  "tags": ["pause"],
  "maxWER": 0.15,
  "forcedLanguages": ["uk"],
  "note": "Two seconds of silence after «до моря,»."
}
```

- `expected` is what was said, as it should be written. Empty for a clip that must
  produce nothing (silence, a press shorter than a word).
- `language`: `uk`, `en` or `mixed` — what the output's alphabet is checked against.
- `maxWER` is optional. Without it the word error rate is reported, not judged; set it
  from a baseline run on the real recording.
- Every clip runs with Auto. `forcedLanguages` adds a pass per language, as if the user
  had named exactly that one. A pass forced to another language than the clip's (English
  forced to Ukrainian) is reported only — the checklist's L4, "note what comes out".
- `vocabulary` (optional) lists the words a user would put in the Dictionary. A clip
  that has one gets one more pass, `auto + dictionary`, with those words as the
  Dictionary: sent to every engine that takes them, as the app sends them (Groq's
  `prompt`, a term list), and correcting the stop's text — the measurement #74 asked for
  before trusting Groq's `prompt`.

One description may have several recordings. `<clip>@<variant>.wav` is played against
`<clip>.json` and reported as its own row, `<clip>@<variant>`: another microphone
(`@builtin`, the MacBook's own), or another way of saying it (`@english`, `@casual`,
`@drawn`). A description may have no `<clip>.wav` at all, only variants.
`SPEECHTEXT_CLIPS=uk-pause` takes every recording of it; `uk-pause@builtin` takes one.

## Running

```sh
ELEVENLABS_API_KEY=… OPENAI_API_KEY=… GROQ_API_KEY=… scripts/evaluate.sh ~/path/to/corpus
```

Keys come from the environment only, never from the app's settings, and may be other
keys than the app's; an engine without its key is a `no key` row. `--cloud` or `--local`
runs one half; `SPEECHTEXT_ENGINES=openAI/gpt-live-transcribe,local/parakeet-tdt-0.6b-v3`
and `SPEECHTEXT_CLIPS=uk-pause,uk-names` narrow it. The cloud half costs cents.
`SPEECHTEXT_RUN_DIR=docs/testing-runs/<date>` adds to an earlier run instead of starting
a new one: the clips run now replace their own rows and every other row stays, so a clip
recorded — or re-recorded — after a run needs no second full run.

The two halves:

- **`LiveProviderTests`** (the test bundle) — the cloud engines. Skipped unless
  `SPEECHTEXT_LIVE=1`; `scripts/evaluate.sh` sets it, passing each variable through as
  `TEST_RUNNER_<NAME>`, since an unhosted test bundle does not inherit the shell's
  environment.
- **`SpeechTextEvaluation`** (a command-line target with its own scheme) — the local
  engines, which the test bundle cannot import. Every local model in the catalogue is a
  row; one that is not installed says `not installed`. A model's first load after a
  build can take minutes (Core ML specialises it for the Mac) and is reported as
  `load`, apart from the stop-to-text time.

Apple's recogniser is not in the matrix: its permission prompt would hang a headless
run, so T9 stays manual.

## What a run does with a clip

The WAV is converted once to what the microphone tap delivers — Float32 mono at 48 kHz,
in ~20 ms buffers — and fed to the real `AudioBufferWriter` and the session the app
would build (`StreamingRecognitionSession` wrapping `BatchRecognitionSession`, or the
upload alone). A streaming engine gets the buffers at the tap's pace; an upload or local
engine gets them at once, since its answer does not depend on it. The stop goes through
`InlineDictationFlow`, the same span layer and `InlineDelivery.stopResult` the app and
`DictationReplay` use, and what would have been pasted is judged:

- nothing pasted for a clip that should produce nothing, or is shorter than 0.3 s;
- something pasted for speech;
- no run of four words appearing more often than it was said (the #67 doubling);
- the word error rate within `maxWER`, when set;
- Ukrainian without Russian letters, English without Cyrillic. This catches an answer
  written in the wrong alphabet, not one Russian-spelled word inside Ukrainian — which
  is why each result also lists what it *misheard* (`привіт → привет`), for a reader;
- no two sentences glued at a segment boundary (`перевірка.Закінчую` — a letter straight
  after `.!?,` that `expected` does not hold that way);
- no known hallucination (`HallucinationFilter`) anywhere in the text that `expected`
  does not hold (`Перевірка. Дякую за перегляд.`): the filter drops only a short segment
  that is nothing but one.

Both runners register the spell-checked segment joins the app registers at launch
(`registerSpellCheckedJoins`), without which no word cut in two is ever glued and
`uk-cut-word` measures nothing.

Each cell of `summary.md` is `WER · first text on the overlay · stop to text`; ↩ marks a
streaming engine whose upload answered instead (the stream broke or came back empty),
❌ a failed check. A streaming run also writes its `DictationTrace` to `traces/`: a
regression found live becomes an offline test by copying that file into
`SpeechTextTests/Traces/` and setting `expectedDocument`.

## Recording a clip

- A quiet room, the microphone you dictate with, your normal voice.
- One file per clip, named after its description (`uk-pause.wav`; another recording of
  it `uk-pause@builtin.wav`). Start about half a
  second before speaking and stop half a second after — except the `uk-stop-on-…` clips,
  which stop *on* the last word, with no breath after it: that is what they test.
- A pause the `note` asks for lasts **2 s**. Scribe closes a segment only after 1.5 s of
  silence (`STTTuning.vadSilenceThresholdSeconds`), so a shorter pause tests nothing a
  segment boundary would.
- Noise clips (`noise-…`) hold no speech at all: no voices, no TV, no singing.
- Plus `room-tone.wav`: about three seconds of the room with nobody speaking. The
  silence clips name it as their `source` and take their `seconds` from its start, so
  none of them is a fraction of a second recorded by hand, which would hold nothing but
  the click of stopping.
- Say exactly the description's text; the `note` says where to pause, stumble or hurry.
- 16 kHz mono WAV. Anything else converts with
  `afconvert -f WAVE -d LEI16@16000 -c 1 in.m4a uk-pause.wav` (QuickTime Player's
  File › New Audio Recording saves `.m4a`).
- A new clip is a description plus a recording; the tables grow a row.
