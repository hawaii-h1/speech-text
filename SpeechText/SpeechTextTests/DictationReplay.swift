// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Foundation
import XCTest

// A dictation replayed without a microphone, a network or an app to paste into.
//
// The provider's events are scripted; everything between them and the document is the
// app's own code: `StreamingRecognitionSession` merges them, `TranscriptSpanLayer` turns
// them into spans, `SpanIssuer` decides what goes out, and `InlineDelivery` pastes,
// records, corrects and computes the stop's remainder. What stands in for the outside
// world is `FakeApp`, a document in memory that can be made to behave like TextEdit, a
// terminal, or an Electron app that accepts a selection and does not keep it.
//
// The glue that `SpeechEngine` and `AppState` put around those pieces cannot be compiled
// here (AVAudioEngine, AppKit), so `DictationReplay.run` repeats it — in the same order,
// with a comment naming where each step comes from. A change to that order in the app
// has to be made here too, or these tests describe a flow the app no longer has.

// MARK: - The app being dictated into

final class FakeApp: InlineDeliveryTarget {
    /// How the app answers the Accessibility API.
    struct Behaviour {
        /// What `PasteService.probeFocusedText` would find — decides the tier.
        var probe: AXTextProbe
        /// What `PasteService.pasteAtCursor` can read back after a paste.
        var landing: Landing
        /// A selection written for the correction reads back as written. Electron apps
        /// accept the write and then report a different range.
        var selectionReadsBack: Bool

        static let textEdit = Behaviour(
            probe: AXTextProbe(valueReadable: true, rangeReadable: true, rangeReadsBack: true),
            landing: .exact, selectionReadsBack: true)
        /// Terminal, cmux: no focused text element at all.
        static let terminal = Behaviour(probe: .unavailable, landing: .unknown, selectionReadsBack: false)
        /// Chromium's `contenteditable`: readable, but the range write does not read back.
        static let chromium = Behaviour(
            probe: AXTextProbe(valueReadable: true, rangeReadable: true, rangeReadsBack: false),
            landing: .exact, selectionReadsBack: false)
        /// T3 Code, 17.09: probes as Tier A, then refuses the correction's selection.
        static let electronThatLies = Behaviour(
            probe: AXTextProbe(valueReadable: true, rangeReadable: true, rangeReadsBack: true),
            landing: .exact, selectionReadsBack: false)
    }

    enum Landing {
        case exact
        /// The caret could not be read, so the landing is nil.
        case unknown
        /// The app stores something other than what was pasted (smart quotes, …).
        case normalised((String) -> String)
    }

    struct Field {
        var text = ""
        /// UTF-16 offset, like every range the app deals in.
        var caret = 0
    }

    let behaviour: Behaviour
    /// The target app's text fields, by name. Dictation starts in `"document"`.
    private(set) var fields: [String: Field] = ["document": Field()]
    private(set) var focusedField = "document"
    /// Text pasted while another app was in front.
    private(set) var elsewhere = ""
    var isInFront = true
    var accessibilityGranted = true
    /// Paste completions are held until `landPendingPastes()` instead of running at once:
    /// a paste still landing when the next thing happens.
    var holdsLandings = false
    private var pendingLandings: [() -> Void] = []
    private var capturedField: String?

    init(_ behaviour: Behaviour) {
        self.behaviour = behaviour
    }

    var document: String { fields["document"]?.text ?? "" }

    // MARK: The user

    /// Types `text` at the caret, or straight after the first occurrence of `anchor`,
    /// leaving the caret after it — as clicking there and typing would.
    func userTypes(_ text: String, after anchor: String? = nil) {
        var field = fields[focusedField] ?? Field()
        let current = field.text as NSString
        var location = field.caret
        if let anchor {
            let found = current.range(of: anchor)
            precondition(found.location != NSNotFound, "“\(anchor)” is not in the field")
            location = NSMaxRange(found)
        }
        field.text = current.replacingCharacters(in: NSRange(location: location, length: 0), with: text)
        field.caret = location + (text as NSString).length
        fields[focusedField] = field
    }

    func moveCaretToEnd() {
        guard var field = fields[focusedField] else { return }
        field.caret = (field.text as NSString).length
        fields[focusedField] = field
    }

    /// Clicks into another field of the same app (a second TextEdit document).
    func focus(_ name: String) {
        if fields[name] == nil { fields[name] = Field() }
        focusedField = name
    }

    func landPendingPastes() {
        while !pendingLandings.isEmpty {
            let landing = pendingLandings.removeFirst()
            landing()
        }
    }

    // MARK: InlineDeliveryTarget

    var acceptsDeliveryNow: Bool { accessibilityGranted && isInFront }

    func paste(_ text: String, completion: @escaping (PasteLanding?) -> Void) {
        let landed = insertAtCaret(text)
        let answer: () -> Void = { [behaviour] in
            switch behaviour.landing {
            case .unknown: completion(nil)
            case .exact, .normalised: completion(landed)
            }
        }
        if holdsLandings {
            pendingLandings.append(answer)
        } else {
            answer()
        }
    }

    /// The stop's ordinary paste (`AppState.deliver`): bring the app forward, then ⌘V.
    func activateAndPaste(_ text: String) {
        isInFront = true
        _ = insertAtCaret(text)
    }

    func captureFocusedField() { capturedField = focusedField }
    func releaseFocusedField() { capturedField = nil }

    var isStillFocused: Bool {
        guard let capturedField else { return false }
        return accessibilityGranted && isInFront && focusedField == capturedField
    }

    /// `PasteService.replaceLastInsertions`, over the fake document, with its refusals in
    /// the same order and logged in the same words.
    func replaceDelivered(ledger: inout InsertionLedger, with text: String) -> Bool {
        guard accessibilityGranted, isInFront, var field = fields[focusedField] else {
            dlog("Span", "correction refused: no focused element")
            return false
        }
        guard let plan = FinalizePass.plan(ledger: ledger, document: field.text, replacement: text) else {
            dlog("Span", "correction refused: the delivered text is not all there, untouched, in one place")
            return false
        }
        guard behaviour.selectionReadsBack else {
            dlog("Span", "correction refused: selecting \(plan.range.location)+\(plan.range.length) did not read back")
            return false
        }
        field.text = (field.text as NSString).replacingCharacters(in: plan.range, with: plan.text)
        field.caret = plan.range.location + (plan.text as NSString).length
        fields[focusedField] = field
        dlog("Span", "correction: replaced \(plan.range.location)+\(plan.range.length) through AX")
        ledger.collapse(into: plan, landed: plan.text)
        dlog("Span", "correction applied: \"\(plan.text.prefix(60))\"")
        return true
    }

    private func insertAtCaret(_ text: String) -> PasteLanding? {
        guard isInFront else {
            elsewhere += text
            return nil
        }
        var stored = text
        if case .normalised(let normalise) = behaviour.landing { stored = normalise(text) }
        var field = fields[focusedField] ?? Field()
        let range = NSRange(location: field.caret, length: (stored as NSString).length)
        field.text = (field.text as NSString).replacingCharacters(in: NSRange(location: field.caret, length: 0), with: stored)
        field.caret = NSMaxRange(range)
        fields[focusedField] = field
        return PasteLanding(range: range, text: stored)
    }
}

// MARK: - The recogniser

/// Hands the session whatever the test scripts, the way `ElevenLabsRealtimeProvider`
/// would have received it from the server.
final class ScriptedStreamingProvider: StreamingSTTProvider {
    let sampleRate = AudioBufferWriter.uploadSampleRate
    let events: AsyncStream<StreamingSTTEvent>
    private let continuation: AsyncStream<StreamingSTTEvent>.Continuation
    /// What the server sends in answer to the stop's final commit.
    var eventsAtFinish: [StreamingSTTEvent] = []

    init() {
        var continuation: AsyncStream<StreamingSTTEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func emit(_ event: StreamingSTTEvent) { continuation.yield(event) }

    func connect(language: String?) {}
    func send(pcm16: Data) {}
    func finish() async {
        eventsAtFinish.forEach { continuation.yield($0) }
        continuation.finish()
    }
    func cancel() { continuation.finish() }
}

/// The batch upload the stream falls back to, with its answer decided in advance.
final class ScriptedSegment: RecognitionSession {
    var onEvent: ((RecognitionEvent) -> Void)?
    private let outcome: RecognitionOutcome

    init(text: String) {
        outcome = RecognitionOutcome(text: text, error: nil, audioFileURL: nil, cancelled: false)
    }

    init(error: String) {
        outcome = RecognitionOutcome(text: "", error: error, audioFileURL: nil, cancelled: false)
    }

    func start() throws {}
    func feed(native: AVAudioPCMBuffer, pcm16: Data?) {}
    func pause() -> String? { nil }
    func finish() async -> RecognitionOutcome { outcome }
    func cancel() {}
}

struct StreamBroke: LocalizedError {
    var errorDescription: String? { "the connection dropped" }
}

// MARK: - The replay

@MainActor
final class DictationReplay {
    struct Setup {
        var aiMode = false
        var aiDraft = false
        var messageSending = false
        var removesDisfluencies = true
    }

    enum Step {
        case partial(String)
        case committed(String)
        /// The socket dropped (`StreamingSTTEvent.failed`).
        case streamBreaks
        case userTypes(String, after: String?)
        case caretToEnd
        /// The user switched to another app.
        case switchAway
        case switchBack
        /// The user clicked into another field of the same app.
        case focus(String)
        case holdLandings
        case landPendingPastes
    }

    enum LLM {
        case rewrites(String)
        case fails
    }

    struct Result {
        let app: FakeApp
        let stop: InlineDelivery.StopResult?
        /// What History's `correctionApplied` would say.
        let correctionApplied: Bool?
        /// Every Debug Log line the replay produced, as "[Category] message".
        let log: [String]

        var document: String { app.document }

        func logged(_ fragment: String) -> Bool {
            log.contains { $0.contains(fragment) }
        }
    }

    let setup: Setup
    let app: FakeApp
    private let delivery = InlineDelivery()
    private var layer = TranscriptSpanLayer()
    private var issuer = SpanIssuer()
    private let provider = ScriptedStreamingProvider()
    private var session: StreamingRecognitionSession!
    private var isRecording = true
    /// `SpeechEngine.onSpansCommitted` is set.
    private var offersSpans = false
    private var handledEvents = 0

    private init(setup: Setup, app: FakeApp) {
        self.setup = setup
        self.app = app
    }

    /// One dictation from hotkey to paste. `atStop` is what the server sends once the
    /// stop commits; `fallback` is what the batch upload returns if the stream broke or
    /// came back empty.
    static func run(_ setup: Setup = Setup(),
                    in app: FakeApp,
                    _ steps: [Step],
                    atStop: [StreamingSTTEvent] = [],
                    fallback: ScriptedSegment = ScriptedSegment(error: "no fallback was scripted"),
                    llm: LLM = .fails,
                    cancelInsteadOfStopping: Bool = false) async -> Result {
        DebugLog.shared.clear()
        let replay = DictationReplay(setup: setup, app: app)
        replay.provider.eventsAtFinish = atStop
        replay.start(fallback: fallback)
        for step in steps {
            await replay.perform(step)
        }
        let result: (InlineDelivery.StopResult?, Bool?)
        if cancelInsteadOfStopping {
            replay.cancel()
            result = (nil, nil)
        } else {
            result = await replay.stop(llm: llm)
        }
        // Lines logged off the main thread arrive through the main queue.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        let log = DebugLog.shared.entries.map { "[\($0.category)] \($0.message)" }
        return Result(app: app, stop: result.0, correctionApplied: result.1, log: log)
    }

    private func cleaned(_ text: String) -> String {
        setup.removesDisfluencies ? cleanedTranscript(text) : text
    }

    /// `AppState.startRecording` → `beginDeliveryPlan`, then `SpeechEngine.startRecording`
    /// → `setupRecordingSession`.
    private func start(fallback: ScriptedSegment) {
        let tier = DeliveryTier.resolve(isMessageDelivery: setup.aiMode && setup.messageSending,
                                        isOwnSurface: false,
                                        probe: app.accessibilityGranted ? app.behaviour.probe : .unavailable)
        offersSpans = delivery.begin(tier: tier, aiMode: setup.aiMode, aiDraft: setup.aiDraft,
                                     target: app, targetName: "FakeApp")

        layer.reset()
        issuer.reset()
        layer.beginSegment()

        session = StreamingRecognitionSession(provider: provider, writer: AudioBufferWriter(),
                                              language: nil, fallback: fallback)
        // Sessions deliver events on the main thread, which is where this replay runs.
        session.onEvent = { [unowned self] event in
            MainActor.assumeIsolated { self.handle(event) }
        }
        try! session.start()
    }

    /// `SpeechEngine.setupRecordingSession`'s `onEvent`.
    private func handle(_ event: RecognitionEvent) {
        handledEvents += 1
        switch event {
        case .live(let committed, let partial):
            layer.ingest(committed: cleaned(committed), partial: cleaned(partial))
            // `SpeechEngine.emitCommittedSpans`.
            guard isRecording, offersSpans else { return }
            let ready = issuer.take(from: layer)
            if !ready.isEmpty { delivery.enqueue(ready) }
        case .failure:
            break
        }
    }

    private func perform(_ step: Step) async {
        switch step {
        case .partial(let text): await emit(.partial(text))
        case .committed(let text): await emit(.committed(text))
        case .streamBreaks: await emit(.failed(StreamBroke()))
        case .userTypes(let text, let anchor): app.userTypes(text, after: anchor)
        case .caretToEnd: app.moveCaretToEnd()
        case .switchAway: app.isInFront = false
        case .switchBack: app.isInFront = true
        case .focus(let field): app.focus(field)
        case .holdLandings: app.holdsLandings = true
        case .landPendingPastes:
            app.holdsLandings = false
            app.landPendingPastes()
        }
    }

    /// Sends one event and waits until the session has handed it on: every provider event
    /// becomes exactly one `.live` event.
    private func emit(_ event: StreamingSTTEvent) async {
        let expected = handledEvents + 1
        provider.emit(event)
        for _ in 0..<2000 where handledEvents < expected {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        if handledEvents < expected { XCTFail("the session never handled \(event)") }
    }

    /// `AppState.stopRecording` → `SpeechEngine.stopRecording` → `runFinalizePass` →
    /// `AppState.handleTranscriptionResult` (→ `deliverAIResult`).
    private func stop(llm: LLM) async -> (InlineDelivery.StopResult?, Bool?) {
        // AppState.stopRecording: no more spans, the ledger stays.
        offersSpans = false
        delivery.stopOffering()
        // SpeechEngine.stopRecording: the tap is removed, the phase leaves `.recording`.
        isRecording = false
        _ = session.pause()
        var outcome = await session.finish()
        outcome.text = cleaned(outcome.text)

        let finalText = outcome.text
        layer.commitSegment(outcome.text)
        layer.settleSegment()
        var correctionApplied: Bool?
        let hasFrozenSpans = layer.spans.contains { $0.state == .frozen }
        // runFinalizePass → AppState.finalizeDelivery, which AI mode skips.
        if !setup.aiMode {
            correctionApplied = delivery.finalize(text: layer.text, hasFrozenSpans: hasFrozenSpans)
        }

        // AppState.waitForTranscription: the result waits for a paste still landing.
        var idle = false
        delivery.whenIdle { idle = true }
        app.holdsLandings = false
        app.landPendingPastes()
        if !idle { XCTFail("the stop is still waiting for a paste to land") }

        let result = delivery.stopResult(finalText: finalText, failed: outcome.error != nil,
                                         aiMode: setup.aiMode, recordingText: layer.text)
        switch result {
        case .paste(let remainder):
            app.activateAndPaste(remainder)
        case .refine(let input):
            var output = input
            if case .rewrites(let rewrite) = llm { output = rewrite }
            let (paste, applied) = delivery.deliverAIResult(output, hasFrozenSpans: hasFrozenSpans)
            correctionApplied = applied
            if let paste { app.activateAndPaste(paste) }
        case .failed, .noSpeech, .alreadyDelivered, .notPasted, .nothingLeft:
            break
        }
        return (result, correctionApplied)
    }

    /// `AppState.cancelInlineFlow` → `endInlineDelivery`, then `SpeechEngine.cancelRecording`.
    private func cancel() {
        offersSpans = false
        delivery.end()
        isRecording = false
        layer.reset()
        issuer.reset()
        session.cancel()
        app.holdsLandings = false
        app.landPendingPastes()
    }
}
