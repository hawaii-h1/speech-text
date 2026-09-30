// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import AppKit
import AVFoundation

// MARK: - Helpers

/// A deinterleaved float32 buffer holding a sine, in every channel, at the format's rate.
private func makeSineBuffer(format: AVAudioFormat, frames: AVAudioFrameCount,
                            frequency: Double = 440, amplitude: Float = 0.5) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let channels = buffer.floatChannelData!
    for frame in 0 ..< Int(frames) {
        let sample = amplitude * Float(sin(2.0 * .pi * frequency * Double(frame) / format.sampleRate))
        for ch in 0 ..< Int(format.channelCount) {
            channels[ch][frame] = sample
        }
    }
    return buffer
}

private func mono48k() -> AVAudioFormat {
    AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
}

private func int16Frames(_ data: Data) -> Int { data.count / MemoryLayout<Int16>.size }

private func int16Samples(_ data: Data) -> [Int16] {
    data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
}

// MARK: - PCMDownsampler

final class PCMDownsamplerTests: XCTestCase {

    func testDownsamples48kMonoByThree() throws {
        let downsampler = try XCTUnwrap(PCMDownsampler(sourceFormat: mono48k(), targetRate: 16_000))
        let input = makeSineBuffer(format: mono48k(), frames: 4_800)

        var pcm = try XCTUnwrap(downsampler.convert(input), "converter reported an error")
        if let tail = downsampler.flush() { pcm.append(tail) }

        // 48 kHz → 16 kHz is 3:1; the resampler's priming/delay line costs a few frames.
        let frames = int16Frames(pcm)
        XCTAssertEqual(frames, 1_600, accuracy: 64)

        // The waveform survives: a 0.5-amplitude sine should peak near 0.5 * Int16.max,
        // swinging both ways — not silence, not clipping, not a DC offset.
        let samples = int16Samples(pcm)
        XCTAssertGreaterThan(Int(samples.max() ?? 0), 10_000)
        XCTAssertLessThan(Int(samples.min() ?? 0), -10_000)
        XCTAssertLessThan(Int(samples.max() ?? 0), 22_000)
    }

    func testStereoDownmixesToMono() throws {
        let stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let downsampler = try XCTUnwrap(PCMDownsampler(sourceFormat: stereo, targetRate: 16_000))
        let input = makeSineBuffer(format: stereo, frames: 4_800)

        var pcm = try XCTUnwrap(downsampler.convert(input))
        if let tail = downsampler.flush() { pcm.append(tail) }

        // Mono output: the frame count follows the sample-rate ratio, not the channel
        // count — a channel-interleaving bug would double it.
        XCTAssertEqual(int16Frames(pcm), 1_600, accuracy: 64)
        XCTAssertGreaterThan(Int(int16Samples(pcm).max() ?? 0), 5_000)
    }

    func testConverterKeepsStateAcrossCalls() throws {
        // Two half-buffers through one converter must produce what one full buffer does:
        // the resampler's delay line carries samples across the call boundary.
        let whole = try XCTUnwrap(PCMDownsampler(sourceFormat: mono48k(), targetRate: 16_000))
        var wholePCM = try XCTUnwrap(whole.convert(makeSineBuffer(format: mono48k(), frames: 4_800)))
        if let tail = whole.flush() { wholePCM.append(tail) }

        let halves = try XCTUnwrap(PCMDownsampler(sourceFormat: mono48k(), targetRate: 16_000))
        var halvesPCM = Data()
        for _ in 0 ..< 2 {
            halvesPCM.append(try XCTUnwrap(halves.convert(makeSineBuffer(format: mono48k(), frames: 2_400))))
        }
        if let tail = halves.flush() { halvesPCM.append(tail) }

        XCTAssertEqual(int16Frames(halvesPCM), int16Frames(wholePCM), accuracy: 16)
    }
}

// MARK: - AudioBufferWriter

final class AudioBufferWriterTests: XCTestCase {

    func testWriteProducesReadable16kMonoFileOfExpectedDuration() throws {
        let writer = AudioBufferWriter()
        writer.prepare(sourceFormat: mono48k())

        // 1.0 s of audio, delivered in ten tap-sized buffers.
        for _ in 0 ..< 10 {
            writer.append(makeSineBuffer(format: mono48k(), frames: 4_800))
        }
        XCTAssertEqual(writer.bufferedDuration, 1.0, accuracy: 0.05)

        let url = try writer.writeAudioFile()
        defer { AudioBufferWriter.cleanup(fileURL: url) }
        XCTAssertEqual(url.pathExtension, AudioBufferWriter.preferredUploadCodec.fileExtension)

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        XCTAssertEqual(seconds, 1.0, accuracy: 0.05)
    }

    /// 0.2 s is 3 200 frames, under one FLAC block: Core Audio's encoder wrote that as a
    /// 42-byte file with no header and no samples (#68). It has to open, and hold the audio.
    func testSegmentShorterThanOneFLACBlockIsWrittenAsADecodableFile() throws {
        let writer = AudioBufferWriter()
        writer.prepare(sourceFormat: mono48k())
        writer.append(makeSineBuffer(format: mono48k(), frames: 4_800))
        writer.append(makeSineBuffer(format: mono48k(), frames: 4_800))

        let url = try writer.writeAudioFile()
        defer { AudioBufferWriter.cleanup(fileURL: url) }
        XCTAssertEqual(url.pathExtension, "wav")

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(Double(file.length), 3_200, accuracy: 64)
    }

    func testSegmentOfOneFLACBlockAndUpStaysFLAC() throws {
        let writer = AudioBufferWriter()
        writer.prepare(sourceFormat: mono48k())
        for _ in 0 ..< 4 {
            writer.append(makeSineBuffer(format: mono48k(), frames: 4_800))
        }

        let url = try writer.writeAudioFile()
        defer { AudioBufferWriter.cleanup(fileURL: url) }
        XCTAssertEqual(url.pathExtension, AudioBufferWriter.preferredUploadCodec.fileExtension)

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(Double(file.length), 6_400, accuracy: 64)
    }

    func testEmptyWriterThrowsNoAudio() {
        let writer = AudioBufferWriter()
        XCTAssertThrowsError(try writer.writeAudioFile()) { error in
            guard case AudioBufferWriter.AudioBufferWriterError.noAudio = error else {
                return XCTFail("expected noAudio, got \(error)")
            }
        }
    }

    func testSilentSegmentHasNoAudibleSignal() {
        let writer = AudioBufferWriter()
        writer.prepare(sourceFormat: mono48k())
        for _ in 0 ..< 10 {
            writer.append(makeSineBuffer(format: mono48k(), frames: 4_800, amplitude: 0.001))
        }
        XCTAssertFalse(writer.hasAudibleSignal, "a −60 dBFS hum is a dead microphone, not speech")

        writer.append(makeSineBuffer(format: mono48k(), frames: 4_800, amplitude: 0.05))
        XCTAssertTrue(writer.hasAudibleSignal, "one quiet syllable is enough to upload")

        writer.reset()
        XCTAssertFalse(writer.hasAudibleSignal)
    }

    func testUnmeasuredNativeAudioCountsAsAudible() {
        // No `prepare`: the native fallback path has no converted samples to measure,
        // and the guard must not turn that into a skipped upload.
        let writer = AudioBufferWriter()
        writer.append(makeSineBuffer(format: mono48k(), frames: 4_800, amplitude: 0.001))
        XCTAssertTrue(writer.hasAudibleSignal)
    }

    func testResetClearsBufferedAudio() {
        // No `prepare` — the native-copy fallback path, where reset() is fully
        // observable (the converter's delay line can't re-materialise frames).
        let writer = AudioBufferWriter()
        writer.append(makeSineBuffer(format: mono48k(), frames: 4_800))
        XCTAssertEqual(writer.bufferedDuration, 0.1, accuracy: 0.001)

        writer.reset()
        XCTAssertEqual(writer.bufferedDuration, 0)
        XCTAssertThrowsError(try writer.writeAudioFile())
    }
}

// MARK: - BatchRecognitionSession

/// Counts uploads instead of making them.
private final class RecordingBatchProvider: BatchSTTProvider, @unchecked Sendable {
    private(set) var uploads: [URL] = []
    func transcribe(audioFileURL: URL, language: String?) async throws -> String {
        uploads.append(audioFileURL)
        return "текст"
    }
}

final class BatchRecognitionSessionTests: XCTestCase {

    private func writer(seconds: Double) -> AudioBufferWriter {
        let writer = AudioBufferWriter()
        writer.prepare(sourceFormat: mono48k())
        for _ in 0 ..< Int((seconds / 0.1).rounded()) {
            writer.append(makeSineBuffer(format: mono48k(), frames: 4_800))
        }
        return writer
    }

    /// A shortcut pressed and let go at once: no upload, no error, and an outcome the
    /// engine writes no History row for.
    func testASegmentTooShortToBeSpeechIsDroppedWithoutATrace() async {
        let provider = RecordingBatchProvider()
        let session = BatchRecognitionSession(provider: provider, writer: writer(seconds: 0.2), language: nil)

        let outcome = await session.finish()

        XCTAssertTrue(provider.uploads.isEmpty)
        XCTAssertEqual(outcome.text, "")
        XCTAssertNil(outcome.error)
        XCTAssertNil(outcome.audioFileURL)
        XCTAssertTrue(outcome.cancelled, "the one outcome the engine records nothing for")
    }

    func testASegmentLongEnoughToBeSpeechIsUploaded() async {
        let provider = RecordingBatchProvider()
        let session = BatchRecognitionSession(provider: provider, writer: writer(seconds: 0.4), language: nil)

        let outcome = await session.finish()
        defer { outcome.audioFileURL.map(AudioBufferWriter.cleanup(fileURL:)) }

        XCTAssertEqual(provider.uploads.count, 1)
        XCTAssertEqual(outcome.text, "текст")
        XCTAssertFalse(outcome.cancelled)
    }
}

private final class AnsweringBatchProvider: BatchSTTProvider, @unchecked Sendable {
    let answer: String
    init(_ answer: String) { self.answer = answer }
    func transcribe(audioFileURL: URL, language: String?) async throws -> String { answer }
}

/// The upload's and the stream's guards against text nobody said (#74).
final class HallucinationGuardTests: XCTestCase {

    private func writer(seconds: Double, amplitude: Float = 0.5) -> AudioBufferWriter {
        let writer = AudioBufferWriter()
        writer.prepare(sourceFormat: mono48k())
        for _ in 0 ..< Int((seconds / 0.1).rounded()) {
            writer.append(makeSineBuffer(format: mono48k(), frames: 4_800, amplitude: amplitude))
        }
        return writer
    }

    private func upload(_ answer: String, seconds: Double) async -> RecognitionOutcome {
        let session = BatchRecognitionSession(provider: AnsweringBatchProvider(answer),
                                              writer: writer(seconds: seconds), language: nil)
        return await session.finish()
    }

    /// The whole answer for a short segment is a subtitle sign-off: nothing to paste, the
    /// audio kept for a History retry.
    func testAnUploadAnsweredWithAKnownHallucinationIsEmptyAndKeepsItsAudio() async {
        let outcome = await upload("Thank you for watching!", seconds: 1)
        defer { outcome.audioFileURL.map(AudioBufferWriter.cleanup(fileURL:)) }

        XCTAssertEqual(outcome.text, "")
        XCTAssertNil(outcome.error)
        XCTAssertNotNil(outcome.audioFileURL)
        XCTAssertFalse(outcome.cancelled, "an empty result, which History records")
    }

    func testTheSameAnswerForALongerSegmentIsKept() async {
        let outcome = await upload("Thank you for watching!", seconds: 2.5)
        defer { outcome.audioFileURL.map(AudioBufferWriter.cleanup(fileURL:)) }

        XCTAssertEqual(outcome.text, "Thank you for watching!")
    }

    private func stream(_ text: String, writer: AudioBufferWriter) async -> RecognitionOutcome {
        let provider = ScriptedStreamingProvider()
        provider.eventsAtFinish = [.committed(text)]
        let session = StreamingRecognitionSession(provider: provider, writer: writer, languages: [],
                                                  fallback: ScriptedSegment(error: "no fallback expected"))
        try! session.start()
        return await session.finish()
    }

    /// A stream is answered by the server whatever the microphone heard, so the upload's
    /// guards now apply to its text too.
    func testAStreamAnsweredWithAKnownHallucinationIsEmpty() async {
        let outcome = await stream("Evet.", writer: writer(seconds: 1))

        XCTAssertEqual(outcome.text, "")
        XCTAssertNil(outcome.error)
        XCTAssertFalse(outcome.cancelled)
    }

    func testAStreamOverASilentSegmentIsEmpty() async {
        let outcome = await stream("Hello there.", writer: writer(seconds: 1, amplitude: 0.001))

        XCTAssertEqual(outcome.text, "")
        XCTAssertFalse(outcome.cancelled, "an empty result, archived by the engine")
    }

    func testAStreamOverASegmentTooShortToBeSpeechLeavesNoTrace() async {
        let outcome = await stream("Hello.", writer: writer(seconds: 0.2))

        XCTAssertEqual(outcome.text, "")
        XCTAssertTrue(outcome.cancelled, "the one outcome the engine records nothing for")
    }

    func testAnAudibleStreamIsKept() async {
        let outcome = await stream("Hello there.", writer: writer(seconds: 1))

        XCTAssertEqual(outcome.text, "Hello there.")
    }
}

/// The stream's guards seen where they matter: the stop pastes the span layer, not the
/// session's outcome, so the words the overlay already drew must be taken back too.
@MainActor
final class HallucinationGuardReplayTests: XCTestCase {

    private func writer(seconds: Double, amplitude: Float) -> AudioBufferWriter {
        let writer = AudioBufferWriter()
        writer.prepare(sourceFormat: mono48k())
        for _ in 0 ..< Int((seconds / 0.1).rounded()) {
            writer.append(makeSineBuffer(format: mono48k(), frames: 4_800, amplitude: amplitude))
        }
        return writer
    }

    private func replay(over writer: AudioBufferWriter) async -> DictationReplay.Result {
        var setup = DictationReplay.Setup()
        setup.writer = writer
        return await DictationReplay.run(setup, in: FakeApp(), [
            .partial("Hello"),
            .committed("Hello there."),
        ])
    }

    func testWordsAStreamInventedOverSilenceAreDrawnThenTakenBack() async {
        let run = await replay(over: writer(seconds: 1, amplitude: 0.001))

        XCTAssertTrue(run.overlay.contains { $0.text == "Hello there." })
        XCTAssertEqual(run.overlay.last?.text, "")
        XCTAssertEqual(run.document, "")
        XCTAssertEqual(run.stop, .noSpeech)
    }

    func testWordsOverASegmentTooShortToBeSpeechAreTakenBack() async {
        let run = await replay(over: writer(seconds: 0.2, amplitude: 0.5))

        XCTAssertEqual(run.overlay.last?.text, "")
        XCTAssertEqual(run.document, "")
        XCTAssertEqual(run.stop, .noSpeech)
    }

    func testAnAudibleSegmentIsPasted() async {
        let run = await replay(over: writer(seconds: 1, amplitude: 0.5))

        XCTAssertEqual(run.document, "Hello there. ")
    }
}

// MARK: - Recogniser failures (RecognitionSession.swift)

final class RecognitionFailureTests: XCTestCase {

    private func apple(domain: String = "kLSRErrorDomain", code: Int = 102,
                       description: String = "Failed to access assets",
                       hasText: Bool = false, permissionDenied: Bool = false,
                       locale: String = "en") -> RecognitionFailure? {
        RecognitionFailure.apple(domain: domain, code: code, description: description,
                                 hasText: hasText, permissionDenied: permissionDenied,
                                 locale: locale)
    }

    /// #69: the on-device recogniser failed 44 ms in, and the overlay listened for 12 s.
    func testAFailureBeforeAnyTextEndsTheRecording() throws {
        let failure = try XCTUnwrap(apple())

        XCTAssertTrue(failure.endsRecording)
        XCTAssertEqual(failure.message,
                       "Couldn't load the English speech model. Add it to Dictation in System Settings › Keyboard.")
    }

    /// Nothing that was already recognised is thrown away, and Apple's 50 s rotation
    /// opens a fresh task: the recording goes on, as before.
    func testAFailureAfterTextLetsTheRecordingGoOn() throws {
        let failure = try XCTUnwrap(apple(hasText: true))

        XCTAssertFalse(failure.endsRecording)
        XCTAssertTrue(failure.message.contains("English speech model"), "still explained at the stop")
    }

    /// A rotation, a stop and `cancel()` all cancel a task — in whichever domain.
    func testACancellationIsNotAFailure() {
        XCTAssertNil(apple(domain: "kAFAssistantErrorDomain", code: 216, description: "Canceled"))
        XCTAssertNil(apple(domain: "kLSRErrorDomain", code: 216, description: "Canceled"))
        XCTAssertNil(apple(domain: "kAFAssistantErrorDomain", code: 216, hasText: true))
    }

    /// Only a cause the error names is explained; anything else keeps the recogniser's
    /// own words — and still ends a recording that has no text.
    func testAnotherErrorKeepsItsOwnWords() throws {
        let noSpeech = try XCTUnwrap(apple(domain: "kAFAssistantErrorDomain", code: 1110,
                                           description: "No speech detected"))
        XCTAssertEqual(noSpeech.message, "No speech detected")
        XCTAssertTrue(noSpeech.endsRecording)

        let sameCodeOtherDomain = try XCTUnwrap(apple(domain: "kAFAssistantErrorDomain", code: 102,
                                                      description: "Something else"))
        XCTAssertEqual(sameCodeOtherDomain.message, "Something else")
    }

    /// The permission is read, not inferred — and when it is off, that is the remedy,
    /// whatever the error said.
    func testADeniedPermissionIsWhatTheUserIsTold() throws {
        let failure = try XCTUnwrap(apple(permissionDenied: true))

        XCTAssertEqual(failure.message, RecognitionFailure.speechPermissionMessage)
        XCTAssertTrue(failure.endsRecording)
        XCTAssertEqual(RecognitionSessionError.speechPermissionDenied.errorDescription,
                       RecognitionFailure.speechPermissionMessage,
                       "the start refuses with the same words")
    }

    /// Apple is handed a regional locale; the notice names the language, in English
    /// whatever the Mac's own language is.
    func testTheLanguageIsNamedInEnglishFromAnyLocaleSpelling() {
        XCTAssertEqual(RecognitionFailure.languageName("en"), "English")
        XCTAssertEqual(RecognitionFailure.languageName("en-US"), "English")
        XCTAssertEqual(RecognitionFailure.languageName("en_GB"), "English")
        XCTAssertEqual(RecognitionFailure.languageName("uk-UA"), "Ukrainian")
    }

    /// The status notice's detail is two lines (`StatusOverlayView`: `lineLimit(2)`, 11 pt,
    /// 340 pt panel less 2 × 16 padding, the 24 pt icon and 12 spacing): past them the
    /// remedy is what gets cut. Measured as laid out, not counted in characters. And
    /// `AppState.friendlySTTError` rewrites a message containing an HTTP status or a
    /// network word, so none may appear in these.
    func testEveryExplanationFitsTheNoticeAndPassesThroughUnchanged() throws {
        var messages = [RecognitionFailure.speechPermissionMessage]
        for language in spokenLanguageCatalog {
            messages.append(try XCTUnwrap(apple(locale: language.localeIdentifier)).message)
        }
        func laidOutHeight(_ text: String) -> CGFloat {
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11)])
                .boundingRect(with: NSSize(width: 272, height: CGFloat.greatestFiniteMagnitude),
                              options: .usesLineFragmentOrigin).height
        }
        // Two lines as the same layout measures them, rather than a font metric that
        // rounds differently.
        let twoLines = laidOutHeight("Ag\nAg")
        XCTAssertLessThan(twoLines, laidOutHeight("Ag\nAg\nAg"))
        for message in messages {
            XCTAssertLessThanOrEqual(laidOutHeight(message), twoLines, message)
            for token in ["413", "429", "401", "403", "-1001", "-1009", "too large", "timed out", "offline"] {
                XCTAssertFalse(message.localizedCaseInsensitiveContains(token), message)
            }
        }
    }
}

// MARK: - Provider error text

final class ProviderErrorMessageTests: XCTestCase {

    /// The reply that reached the user whole in #68.
    func testOpenAIsMessageIsKeptAndTheJSONIsNot() {
        let body = """
        {"error":{"message":"Audio file might be corrupted or unsupported","type":"invalid_request_error","param":"file","code":"invalid_value"}}
        """
        XCTAssertEqual(OpenAISTTError.httpError(400, body).errorDescription,
                       "OpenAI couldn't transcribe the recording: Audio file might be corrupted or unsupported. (HTTP 400)")
    }

    func testElevenLabsDetailShapes() {
        XCTAssertEqual(providerErrorMessage(vendor: "ElevenLabs", status: 401,
                                            body: #"{"detail":{"status":"invalid_api_key","message":"Invalid API key"}}"#),
                       "ElevenLabs couldn't transcribe the recording: Invalid API key. (HTTP 401)")
        XCTAssertEqual(providerErrorMessage(vendor: "ElevenLabs", status: 422,
                                            body: #"{"detail":[{"loc":["body","file"],"msg":"field required"}]}"#),
                       "ElevenLabs couldn't transcribe the recording: field required. (HTTP 422)")
    }

    func testABodyThatSaysNothingFallsBackToTheStatus() {
        XCTAssertEqual(GroqError.httpError(502, "<html>Bad Gateway</html>").errorDescription,
                       "Groq couldn't transcribe the recording: the service is having problems. (HTTP 502)")
        XCTAssertEqual(providerErrorMessage(vendor: "Groq", status: 429, body: ""),
                       "Groq couldn't transcribe the recording: too many requests — try again in a moment. (HTTP 429)")
    }
}
