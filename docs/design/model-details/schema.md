# Model languages: data

Design only. This is what MC adds to the catalogues for the design in [README.md](README.md).

## Fields

Both new fields are required, as `price` is: an entry without them does not build. "Not
published" is a value, never an absent field.

```swift
/// What a model knows, as against `LanguageSupport`, which says what its API *takes*.
enum LanguageCoverage: Hashable {
    /// The vendor's list, as BCP-47 language codes (ISO 639-1 where one exists, else
    /// 639-3: "yue", "fil"), and the source it was read from.
    case listed([String], source: URL, checked: DateComponents)
    /// The vendor publishes no list (OpenAI). Never matched as "not supported".
    case unpublished
    /// Apple: asked of macOS while the app runs (`supportsOnDeviceRecognition` per locale),
    /// never written into the catalogue.
    case decidedBySystem
}

/// A weakness in one language that we measured, shown only to someone who speaks it.
struct LanguageNote: Hashable {
    /// "Makes mistakes in Ukrainian."
    let text: String
    /// The corpus run or measurement it comes from ("2026-09-17, M1 Pro").
    let measured: String
}
```

- `STTModelDescriptor.languages: LanguageCoverage` and `languageNotes: [String: LanguageNote]`.
  A local entry derives both from `LocalSTTModel`, which takes the same two fields, as it already
  does for `price`.
- `LocalLLMModel` gets `languageNotes` too, for the local AI lines (README › Hard-coded languages).
  Chat models get no coverage.
- An unlisted ID (`sttModel(vendor:id:)`) gets `.unpublished` and no notes, so it never warns.
  This mirrors its `.notPriced`.

## Not duplicated

- **The count in the subtitle** is derived: `listed.count` gives "25 languages", and a single code
  gives "<name> only". There is no stored "count" string. The one exception is a vendor that
  publishes "90+" without a list we keep: such a model stores its full list, and the subtitle
  rounds it the way the vendor does.
- **Size** is `LocalSTTModel.downloadSizeDescription`, which is already shown.
- **Lifecycle** (MA) and `minimumMacOS` (MB) stay where those sessions put them. This design adds
  no badge for either.

## The match

```swift
enum LanguageMatch { case supported, unsupported, unknown }

/// Pure, in both targets; `onDevice` is passed in, so Apple's answer is testable.
func languageMatch(spoken: [String], coverage: LanguageCoverage,
                   onDevice: (String) -> Bool) -> [String: LanguageMatch]
```

A code is compared on its language subtag, so `uk` matches `uk-UA`. The badge and the
*Languages I speak* caption show for `.unsupported` only.

A note shows for a spoken code that `languageNotes` has.

## Tests

- Every entry has coverage.
- Every listed code is a valid language subtag.
- Every `.listed` source is `https`.
- Phonon-2 with `uk` is unsupported.
- gpt-transcribe with `uk` is unknown and never warns.
- Apple follows the closure.
- With no languages spoken, every row has no badge and no note.
- No UI line function returns a language name (a test over `speechModelLine`, `aiModelLine` and
  `appleDictationLine` for every catalogue entry against `spokenLanguageCatalog`'s names). This
  keeps the hard-coding from coming back.

## The provider guide and its check

`docs/adding-a-provider.md`:

- the capability vocabulary table gains `LanguageCoverage`'s three cases;
- § 3 says: a new model's `languages`, read from the vendor's page with the date, and a
  `languageNotes` entry for any language our corpus run found weak.

`scripts/check-provider-guide.sh`:

- add `STTModelCatalog.swift|enum LanguageCoverage` to the vocabulary list, so an undocumented
  case fails CI;
- the compiler enforces the field itself.
