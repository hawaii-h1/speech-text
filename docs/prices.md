# Updating the list prices

Usage and Home show what dictation cost as an **estimate**: "≈ $1.20 · estimated from known
prices", with the date the prices were checked under How this is counted. The prices are written into the app, checked by hand
against each vendor's page, and refreshed now and then with a release (#155). There is no
price feed and no price history: every History record is priced again at the current
table from the units its ledger keeps (audio seconds, billed seconds, tokens, keyterms),
so a refresh reprices everything without a migration.

## Where the prices are

| What | Where |
|---|---|
| Speech models, a minute of audio and the keyterm surcharge (`SpeechRates`) | `price:` on each entry of `sttModelCatalog`, `SpeechText/SpeechText/STTModelCatalog.swift` |
| Chat models, input / cached input / output per token (`ChatRates`, written `.perMillion(…)`) | `price:` on each entry of `chatModelCatalog`, `SpeechText/SpeechText/ChatClients.swift` |
| The date the table was checked | `UsagePrices.checked`, `SpeechText/SpeechText/HomeSummary.swift` |
| The same table, written out for review | `ListPriceTests`, `SpeechText/SpeechTextTests/HomeSummaryTests.swift` |

A price is one of `ListPrice`'s cases: `.free` (a model on the Mac, Ollama, Apple),
`.listed(rates)`, or `.notPriced` for a model whose vendor publishes no price. The
field is required, so a new model cannot be added without one. An unpriced model is
named in Usage and Home, never charged at another model's rate.

## Where to check

The pay-as-you-go, standard-tier price, in US dollars:

- **Groq:** the models page, console.groq.com/docs/models (speech by the hour, chat per
  million tokens). Cached input: the prompt-caching page lists the models it covers and
  the discount (50 % on gpt-oss as of 14 October 2026). Every other model's cached price
  is its input price.
- **ElevenLabs:** elevenlabs.io/pricing/api. Scribe v2 and Scribe v2 Realtime by the hour,
  and *keyterm prompting* as a separate line per model. Use the pricing page's figure,
  not the API reference's percentage.
- **OpenAI:** developers.openai.com/api/docs/pricing. Chat in the standard tier. For
  transcription, use the *estimated cost* per minute, which is the only figure given for
  every model.
- **Anthropic:** platform.claude.com/docs/en/about-claude/pricing. The cached price is
  *Cache hits and refreshes*. Cache writes are not priced apart, because the app sends no
  `cache_control`.

## Steps

1. Open each page above and compare every model in both catalogues.
2. Change each `price:` that moved. Change `.notPriced` to `.listed(…)` once the vendor
   publishes a price.
3. Set `UsagePrices.checked` to today, even if nothing moved: the date says when the
   table was checked, not when it last changed.
4. Change the same figures in `ListPriceTests`, and the date in
   `testTheTableSaysWhenItWasChecked`.
5. Run the tests. A model added to a catalogue without a row in `ListPriceTests` fails
   there.
6. Add a line to `CHANGELOG.md` under *Changed* if any price moved.

A new model gets its price when it is added (docs/adding-a-provider.md, section 3).
