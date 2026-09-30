// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Foundation
import XCTest

// A dictation replayed without a microphone, a network or an app to paste into.
//
// The provider's events are scripted; everything between them and the document is the
// app's own code: `StreamingRecognitionSession` merges them, `TranscriptSpanLayer` turns
// them into the spans the overlay draws, and `InlineDelivery` decides what the stop does.
// What stands in for the outside world is `FakeApp`, a document in memory — as many of
// them as the user switches between, since the dictation is pasted into the one in front
// at the stop (`InlineDelivery.destination`).
//
// Nothing reaches any app before the stop: the harness asserts it on every replay, so a
// change that brought pasting-while-speaking back would fail all of them at once.
//
// The glue that `SpeechEngine` and `AppState` put around those pieces cannot be compiled
// here (AVAudioEngine, AppKit), so `DictationReplay.run` repeats it — in the same order,
// with a comment naming where each step comes from. A change to that order in the app
// has to be made here too, or these tests describe a flow the app no longer has.

// MARK: - The app being dictated into

final class FakeApp {
    struct Field {
        var text = ""
        /// UTF-16 offset, like every range the app deals in.
        var caret = 0
    }

    let name: String
    let bundleID: String
    /// Its focused window's title, for the AI prompt's `<context>`.
    var windowTitle: String?
    /// The target app's text fields, by name. Dictation starts in `"document"`.
    private(set) var fields: [String: Field] = ["document": Field()]
    private(set) var focusedField = "document"
    /// Every paste, in order.
    private(set) var pastes: [String] = []

    init(_ name: String = "TextEdit", bundleID: String? = nil, windowTitle: String? = nil) {
        self.name = name
        self.bundleID = bundleID ?? "test.\(name.lowercased().replacingOccurrences(of: " ", with: ""))"
        self.windowTitle = windowTitle
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

    // MARK: The stop's paste

    /// The stop's paste (`AppState.deliver`): bring the app forward, then ⌘V at the caret.
    /// The trailing space is `deliver`'s, so a dictation continued into the same field
    /// does not start glued to this one.
    func activateAndPaste(_ text: String) {
        let pasted = text + " "
        pastes.append(pasted)
        var field = fields[focusedField] ?? Field()
        field.text = (field.text as NSString).replacingCharacters(in: NSRange(location: field.caret, length: 0), with: pasted)
        field.caret += (pasted as NSString).length
        fields[focusedField] = field
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

    func connect(languages: [String]) {}
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
        var removesDisfluencies = true
        var dashStyle = DashStyle.default
        /// The segment's audio, for the guards that measure it. nil is an empty writer:
        /// nothing measured, so only the text decides.
        var writer: AudioBufferWriter?
    }

    enum Step {
        case partial(String)
        case committed(String)
        /// The socket dropped (`StreamingSTTEvent.failed`).
        case streamBreaks
        /// The network went away under the socket, and the session opened a fresh one
        /// (`StreamReconnectPolicy`). Every event after it is the new socket's.
        case connectionDrops
        case userTypes(String, after: String?)
        case caretToEnd
        /// The user clicked into another field of the same app.
        case focus(String)
        /// The other mode's shortcut, pressed mid-dictation (`AppState.switchMode`).
        case switchMode(ai: Bool)
        /// The user brought another app to the front.
        case switchTo(FakeApp)
        /// The user brought one of SpeechText's own windows (Settings, History) to the front.
        case openSpeechTextWindow
    }

    enum LLM {
        case rewrites(String)
        case fails
    }

    /// What the overlay showed after one provider event: `RecordingOverlayView`'s
    /// `settledText` and `movingText`.
    struct OverlayFrame: Equatable {
        let settled: String
        let moving: String

        var text: String { joinedTranscript(settled, moving) }
    }

    struct Result {
        /// The app the dictation started in.
        let app: FakeApp
        let stop: InlineDelivery.StopResult?
        /// The app the stop chose to paste into — nil for the Record Window.
        let destination: FakeApp?
        /// What an AI rewrite was told about where the text is going.
        let context: FocusContext?
        /// What went to the Record Window instead of an app.
        let recordWindow: String?
        /// The overlay after every provider event, in order.
        let overlay: [OverlayFrame]
        /// Every Debug Log line the replay produced, as "[Category] message".
        let log: [String]

        /// The origin's document.
        var document: String { app.document }

        func logged(_ fragment: String) -> Bool {
            log.contains { $0.contains(fragment) }
        }
    }

    let setup: Setup
    let app: FakeApp
    /// `AppState.isAIMode`: the mode the dictation started in, until a switch.
    private var aiMode: Bool
    /// The app in front, and whether it is SpeechText's own window instead.
    private var front: FakeApp?
    private var speechTextInFront = false
    private var destination: FakeApp?
    private var context: FocusContext?
    private var recordWindow: String?
    private var layer = TranscriptSpanLayer()
    /// The socket in use: the first one, or the one the latest reconnect opened.
    private var provider = ScriptedStreamingProvider()
    private var providersOpened = 1
    private var eventsAtFinish: [StreamingSTTEvent] = []
    private var session: StreamingRecognitionSession!
    private var overlay: [OverlayFrame] = []
    private var handledEvents = 0

    private init(setup: Setup, app: FakeApp) {
        self.setup = setup
        self.app = app
        self.aiMode = setup.aiMode
        self.front = app
    }

    /// One dictation from hotkey to paste, started in `app`. `atStop` is what the server
    /// sends once the stop commits; `fallback` is what the batch upload returns if the
    /// stream broke or came back empty; `whileRewriting` is what the user does between the
    /// stop and the AI rewrite's answer.
    static func run(_ setup: Setup = Setup(),
                    in app: FakeApp,
                    _ steps: [Step],
                    atStop: [StreamingSTTEvent] = [],
                    fallback: ScriptedSegment = ScriptedSegment(error: "no fallback was scripted"),
                    llm: LLM = .fails,
                    whileRewriting: [Step] = [],
                    cancelInsteadOfStopping: Bool = false,
                    file: StaticString = #filePath, line: UInt = #line) async -> Result {
        DebugLog.shared.clear()
        let replay = DictationReplay(setup: setup, app: app)
        replay.eventsAtFinish = atStop
        replay.provider.eventsAtFinish = atStop
        var apps = [app]
        for case .switchTo(let other) in steps + whileRewriting where !apps.contains(where: { $0 === other }) {
            apps.append(other)
        }
        let pastedBefore = apps.map(\.pastes.count)
        replay.start(fallback: fallback)
        for step in steps {
            await replay.perform(step)
        }
        // Nothing reaches any app while the user speaks, in any mode: the text is on the
        // overlay until the stop.
        XCTAssertEqual(apps.map(\.pastes.count), pastedBefore, "something was pasted before the stop",
                       file: file, line: line)
        var stop: InlineDelivery.StopResult?
        if cancelInsteadOfStopping {
            replay.cancel()
        } else {
            stop = await replay.stop(llm: llm, whileRewriting: whileRewriting)
        }
        // Lines logged off the main thread arrive through the main queue.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        let log = DebugLog.shared.entries.map { "[\($0.category)] \($0.message)" }
        return Result(app: app, stop: stop, destination: replay.destination, context: replay.context,
                      recordWindow: replay.recordWindow, overlay: replay.overlay, log: log)
    }

    private func cleaned(_ text: String) -> String {
        setup.dashStyle.applied(to: setup.removesDisfluencies ? cleanedTranscript(text) : text)
    }

    /// A recorded `DictationTrace`, replayed into apps of the same names.
    static func run(_ trace: DictationTrace) async -> Result {
        let setup = Setup(aiMode: trace.setup.aiMode,
                          removesDisfluencies: trace.setup.removesDisfluencies,
                          dashStyle: trace.setup.dashStyle ?? .emDash)

        var steps: [Step] = []
        var atStop: [StreamingSTTEvent] = []
        var fallback = ScriptedSegment(error: "no fallback was recorded")
        var llm = LLM.fails
        var stopped = false

        for event in trace.events {
            switch event.kind {
            case .partial, .committed, .streamFailed:
                let text = event.text ?? ""
                let (providerEvent, step): (StreamingSTTEvent, Step) = switch event.kind {
                case .partial: (.partial(text), .partial(text))
                case .committed: (.committed(text), .committed(text))
                default: (.failed(StreamBroke()), .streamBreaks)
                }
                if stopped {
                    atStop.append(providerEvent)
                } else {
                    steps.append(step)
                }
            case .streamReconnected where !stopped:
                // The failure before it was a drop the session rode out.
                if case .streamBreaks = steps.last {
                    steps[steps.count - 1] = .connectionDrops
                }
            case .modeSwitch where !stopped:
                steps.append(.switchMode(ai: event.text == "ai"))
            case .stop:
                stopped = true
            case .fallback:
                fallback = event.error.map { ScriptedSegment(error: $0) } ?? ScriptedSegment(text: event.text ?? "")
            case .refinement:
                if let text = event.text { llm = .rewrites(text) }
            default:
                break
            }
        }
        // The user was somewhere else when they stopped (#77). When they switched is not
        // recorded, and it does not matter: nothing is pasted before the stop.
        if let destination = trace.setup.destination, destination != trace.setup.app {
            steps.append(.switchTo(FakeApp(destination)))
        }
        return await run(setup, in: FakeApp(trace.setup.app ?? "TextEdit"), steps,
                         atStop: atStop, fallback: fallback, llm: llm)
    }

    /// What the app pasted when the trace was recorded, in order.
    static func recordedPastes(_ trace: DictationTrace) -> [String] {
        trace.events.filter { $0.kind == .stopPaste }.compactMap(\.text)
    }

    /// `SpeechEngine.startRecording` → `setupRecordingSession`.
    private func start(fallback: ScriptedSegment) {
        layer.reset()
        layer.beginSegment()

        // A reconnect opens a fresh scripted socket, at once: the policy's waits are
        // real time, and what they pace is not what a replay is about.
        session = StreamingRecognitionSession(
            provider: provider, writer: setup.writer ?? AudioBufferWriter(), languages: [], fallback: fallback,
            reconnect: { [unowned self] in
                MainActor.assumeIsolated {
                    let next = ScriptedStreamingProvider()
                    next.eventsAtFinish = self.eventsAtFinish
                    self.provider = next
                    self.providersOpened += 1
                    return next
                }
            },
            policy: StreamReconnectPolicy(delays: [0, 0, 0, 0, 0, 0, 0, 0]))
        // Sessions deliver events on the main thread, which is where this replay runs.
        session.onEvent = { [unowned self] event in
            MainActor.assumeIsolated { self.handle(event) }
        }
        try! session.start()
    }

    /// `SpeechEngine.setupRecordingSession`'s `onEvent`, and what the overlay then draws
    /// (`ObservedOverlay`: `spanLayer.stableText` and `segmentProvisionalText`).
    private func handle(_ event: RecognitionEvent) {
        handledEvents += 1
        switch event {
        case .live(let committed, let partial):
            layer.ingest(committed: cleaned(committed), partial: cleaned(partial))
            overlay.append(OverlayFrame(settled: layer.stableText, moving: layer.segmentProvisionalText))
        case .failure:
            break
        }
    }

    private func perform(_ step: Step) async {
        switch step {
        case .partial(let text): await emit(.partial(text))
        case .committed(let text): await emit(.committed(text))
        case .streamBreaks: await emit(.failed(StreamBroke()))
        case .connectionDrops:
            let opened = providersOpened
            await emit(.failed(URLError(.networkConnectionLost)))
            for _ in 0..<2000 where providersOpened == opened {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            if providersOpened == opened { XCTFail("the session never reconnected") }
        case .userTypes(let text, let anchor): app.userTypes(text, after: anchor)
        case .caretToEnd: app.moveCaretToEnd()
        case .focus(let field): app.focus(field)
        case .switchMode(let ai): aiMode = ai
        case .switchTo(let other):
            front = other
            speechTextInFront = false
        case .openSpeechTextWindow:
            speechTextInFront = true
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

    /// `AppState.stopRecording` → `SpeechEngine.stopRecording` →
    /// `AppState.handleTranscriptionResult` (→ `refine` → `deliver`).
    private func stop(llm: LLM, whileRewriting: [Step]) async -> InlineDelivery.StopResult {
        // AppState.choosePasteDestination: fixed now, before anything else.
        destination = InlineDelivery.destination(front: front, frontIsSpeechText: speechTextInFront, origin: app)
        // SpeechEngine.stopRecording: the tap is removed, the phase leaves `.recording`.
        _ = session.pause()
        // AppState.stopRecording → readFocusContext, from the destination, AI mode only.
        if aiMode, let destination {
            context = FocusContext.capture(appName: destination.name, bundleID: destination.bundleID,
                                           windowTitle: destination.windowTitle, fieldLabels: [],
                                           isSecureField: false)
        }
        var outcome = await session.finish()
        outcome.text = cleaned(outcome.text)

        let finalText = outcome.text
        layer.commitSegment(outcome.text)
        layer.settleSegment()

        let result = InlineDelivery.stopResult(finalText: finalText, failed: outcome.error != nil,
                                               aiMode: aiMode, recordingText: layer.text)
        switch result {
        case .paste(let text):
            deliver(text)
        case .refine(let input):
            // The model takes seconds, and the user may move meanwhile.
            for step in whileRewriting { await perform(step) }
            var output = input
            if case .rewrites(let rewrite) = llm { output = rewrite }
            deliver(output)
        case .failed(let partial):
            recordWindow = partial
        case .noSpeech:
            break
        }
        return result
    }

    /// `AppState.deliver`: the destination is brought forward and pasted into, or the text
    /// goes to the Record Window when there is none.
    private func deliver(_ text: String) {
        guard let destination else {
            recordWindow = text + " "
            return
        }
        destination.activateAndPaste(text)
        front = destination
        speechTextInFront = false
    }

    /// `AppState.cancelInlineFlow` → `SpeechEngine.cancelRecording`.
    private func cancel() {
        layer.reset()
        session.cancel()
    }
}
