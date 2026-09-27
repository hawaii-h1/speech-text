// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Who serves a speech model — the company behind a cloud endpoint, Apple's own
/// recogniser, or the user's Mac.
///
/// One-to-one with `STTProviderType` today, and still a separate type on purpose:
/// `STTProviderType` is the user's pick in a picker, `STTVendor` is where a model comes
/// from and whose key it needs. The two part ways once the chat side joins (#55), where
/// Groq and OpenAI serve both tiers.
enum STTVendor: String, CaseIterable, Hashable {
    case apple
    case groq
    case elevenLabs
    case openAI
    case local

    var displayName: String {
        switch self {
        case .apple: "Apple"
        case .groq: "Groq"
        case .elevenLabs: "ElevenLabs"
        case .openAI: "OpenAI"
        case .local: "Local"
        }
    }

    /// The phrase the retry notice uses — "a Groq API key", "an OpenAI API key".
    var apiKeyPhrase: String {
        switch self {
        case .elevenLabs, .openAI: "an \(displayName) API key"
        case .apple, .groq, .local: "a \(displayName) API key"
        }
    }
}

extension STTProviderType {
    var vendor: STTVendor {
        switch self {
        case .apple: .apple
        case .groq: .groq
        case .elevenlabs: .elevenLabs
        case .openai: .openAI
        case .local: .local
        }
    }
}

/// One speech model and what it can do, as data.
///
/// Capabilities belong to the *model*, not the provider: Scribe v2 and Scribe v2 Realtime
/// share a vendor, a key and an enum case, and differ on whether text appears while the
/// user speaks. Modelled on `LocalSTTModel`, which already worked this way; every field
/// below used to be a switch branch, a global constant or a comment.
///
/// Vendor-protocol quirks — OpenAI's deltas, Scribe's echo, the pre-session buffer, the
/// commit padding — stay inside each provider. A descriptor says *what* a model does,
/// never how its socket is spoken to.
struct STTModelDescriptor: Identifiable, Hashable {
    /// The ID the vendor's API takes and the settings store. Unique within a vendor only:
    /// a model is always looked up by vendor *and* ID (`sttModel(vendor:id:)`), because a
    /// realtime ID stored for one engine must not make another engine stream.
    let id: String
    let vendor: STTVendor
    let displayName: String
    let delivery: Delivery
    let language: LanguageSupport
    /// Where a file of this session's audio is transcribed: the stream's fallback, and
    /// History retries.
    let batchUpload: BatchUpload
    /// What must be in place before the model can run.
    let requirement: Requirement

    enum Delivery: Hashable {
        /// A file POSTed after the segment ends.
        case upload
        /// A WebSocket that returns text while the user speaks.
        case realtime(RealtimeShape)
        /// A model downloaded to the Mac and run by one of the local engines.
        case onDevice(LocalSTTEngine)
        /// Apple's `SFSpeechRecognizer`: on-device, with partials while the user speaks,
        /// and nothing behind an upload endpoint.
        case systemRecognizer
    }

    /// How a realtime model's socket behaves, as far as the rest of the app can tell.
    struct RealtimeShape: Hashable {
        /// The only rate the socket takes — 16 kHz for Scribe, exactly 24 kHz for
        /// OpenAI (which calls 16 kHz "below minimum").
        let sampleRate: Double
        let transcripts: TranscriptForm
        /// Whether the server commits a segment on a pause by itself. OpenAI's rejects
        /// `turn_detection` outright, so one item grows until `finish()` commits it.
        let serverVAD: Bool
    }

    enum TranscriptForm: Hashable {
        /// Each message restates the segment so far — what `TranscriptMerge` is written
        /// against.
        case cumulative
        /// Each message carries only newly decoded text; the provider accumulates it
        /// before anything leaves it.
        case incremental
    }

    enum LanguageSupport: Hashable {
        /// Must be handed a locale and cannot detect one: Apple's recogniser. History
        /// records the locale it was given even when that locale was a guess.
        case localeRequired
        /// Takes one language or none, detecting it when none is sent.
        case single
        /// Takes a set of candidate languages and detects within it — only
        /// `gpt-live-transcribe` (checked 2026-09-21).
        case set
    }

    enum BatchUpload: Hashable {
        /// The model is its own upload model.
        case itself
        /// A realtime model: the same vendor's upload model with this ID, since the
        /// realtime ID exists only behind the WebSocket.
        case model(String)
        /// No upload of its own: whatever model the user picked for that vendor. Apple's
        /// recogniser has no batch API, so its uploads go to the stored Groq model.
        case selectedModel(of: STTVendor)
    }

    enum Requirement: Hashable {
        case none
        /// An API key stored under this `SettingsKeys` name.
        case apiKey(String)
        /// The model's files on disk (`isLocalModelInstalled`).
        case installedModel
    }

    var isRealtime: Bool {
        if case .realtime = delivery { true } else { false }
    }
}

/// Apple's recogniser in the catalogue. Never stored — `sttProvider == "apple"` selects
/// it — so it only has to be unique among Apple's entries, of which it is the one.
let appleSpeechModelID = "apple-speech"

/// Every speech model the app offers, grouped by vendor, each vendor's in picker order.
/// The Settings pickers' tuples (`groqModels`, `elevenLabsModels`, `openAISTTModels`) are
/// derived from it, so a model and its capabilities are written down once.
let sttModelCatalog: [STTModelDescriptor] = {
    let groqKey = STTModelDescriptor.Requirement.apiKey(SettingsKeys.groqAPIKey)
    let elevenLabsKey = STTModelDescriptor.Requirement.apiKey(SettingsKeys.elevenLabsAPIKey)
    let openAIKey = STTModelDescriptor.Requirement.apiKey(SettingsKeys.openAIAPIKey)

    let cloud: [STTModelDescriptor] = [
        STTModelDescriptor(
            id: appleSpeechModelID, vendor: .apple, displayName: "Apple on-device",
            delivery: .systemRecognizer, language: .localeRequired,
            batchUpload: .selectedModel(of: .groq), requirement: .none
        ),

        STTModelDescriptor(
            id: "whisper-large-v3-turbo", vendor: .groq, displayName: "Whisper Large V3 Turbo",
            delivery: .upload, language: .single, batchUpload: .itself, requirement: groqKey
        ),
        STTModelDescriptor(
            id: "whisper-large-v3", vendor: .groq, displayName: "Whisper Large V3",
            delivery: .upload, language: .single, batchUpload: .itself, requirement: groqKey
        ),

        // The batch (upload) model IDs are exactly what the API's `unsupported_model`
        // error lists, minus the two that are gone: scribe_v1 is deprecated in favour of
        // scribe_v2 and scribe_v1_experimental no longer appears in the documentation
        // (checked 2026-09-16) — stored values for either are normalised to scribe_v2.
        STTModelDescriptor(
            id: defaultElevenLabsModel, vendor: .elevenLabs, displayName: "Scribe v2",
            delivery: .upload, language: .single, batchUpload: .itself, requirement: elevenLabsKey
        ),
        // Scribe's `language_code` is one value, so the realtime query string carries it
        // only when the user named exactly one language.
        STTModelDescriptor(
            id: elevenLabsRealtimeModel, vendor: .elevenLabs, displayName: "Scribe v2 Realtime — live text",
            delivery: .realtime(.init(sampleRate: 16_000, transcripts: .cumulative, serverVAD: true)),
            language: .single, batchUpload: .model(defaultElevenLabsModel), requirement: elevenLabsKey
        ),

        // Checked against `GET /v1/models` on 2026-09-21 rather than against the docs.
        //
        // Two of the models the account can see are deliberately left out.
        // `gpt-4o-transcribe-diarize` answers in `diarized_json`, a different shape from
        // the `{text}` this app decodes, and dictation has one speaker. `whisper-1` is
        // the one that matters: handed two seconds of near-silence it answered
        // "MBC 뉴스 이덕영입니다." — the classic Whisper silence hallucination, which would
        // be pasted into the user's document. `gpt-transcribe` answered `{"text":""}` to
        // the same audio, which is why it is the default. `AudioBufferWriter`'s silence
        // floor catches most of this, but a model that invents sentences from room noise
        // should not be offered at all.
        STTModelDescriptor(
            id: defaultOpenAISTTModel, vendor: .openAI, displayName: "GPT Transcribe",
            delivery: .upload, language: .single, batchUpload: .itself, requirement: openAIKey
        ),
        STTModelDescriptor(
            id: "gpt-4o-mini-transcribe", vendor: .openAI, displayName: "GPT-4o mini Transcribe — cheaper",
            delivery: .upload, language: .single, batchUpload: .itself, requirement: openAIKey
        ),
        STTModelDescriptor(
            id: openAIRealtimeSTTModel, vendor: .openAI, displayName: "GPT Live Transcribe — live text",
            delivery: .realtime(.init(sampleRate: 24_000, transcripts: .incremental, serverVAD: false)),
            language: .set, batchUpload: .model(defaultOpenAISTTModel), requirement: openAIKey
        ),
    ]

    // Derived, not retyped: `localSTTModels` stays the one list of local models, with
    // their sizes and memory floors. WhisperKit takes `language` or detects; Parakeet
    // takes a script hint or none.
    let local = localSTTModels.map { model in
        STTModelDescriptor(
            id: model.id, vendor: .local, displayName: model.displayName,
            delivery: .onDevice(model.engine), language: .single,
            batchUpload: .itself, requirement: .installedModel
        )
    }
    return cloud + local
}()

/// A vendor's models in picker order.
func sttModels(of vendor: STTVendor) -> [STTModelDescriptor] {
    sttModelCatalog.filter { $0.vendor == vendor }
}

/// The descriptor for a stored model ID. An ID the catalogue does not list — a
/// configuration built by hand, or a stored value normalisation has not reached yet —
/// is taken for its vendor's plain model: it uploads (or runs on the Mac) under its own
/// ID and needs what the vendor's models need. That is how every such ID behaved before
/// the catalogue existed: no stream, no mapping, the vendor's key.
func sttModel(vendor: STTVendor, id: String) -> STTModelDescriptor {
    if let listed = sttModelCatalog.first(where: { $0.vendor == vendor && $0.id == id }) {
        return listed
    }
    let template = sttModels(of: vendor).first { !$0.isRealtime } ?? sttModels(of: vendor)[0]
    return STTModelDescriptor(
        id: id, vendor: vendor, displayName: id,
        delivery: template.delivery, language: template.language,
        batchUpload: template.batchUpload, requirement: template.requirement
    )
}
