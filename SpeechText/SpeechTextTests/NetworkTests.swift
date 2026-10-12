// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import AVFoundation

// MARK: - What counts as "no connection" (NetworkFailure.swift)

final class NetworkFailureTests: XCTestCase {

    /// Wi-Fi off: URLSession gives up at once with -1009, and that is the notice's case.
    func testNoInterfaceIsOffline() {
        XCTAssertTrue(NetworkFailure.isOffline(URLError(.notConnectedToInternet)))
        XCTAssertTrue(NetworkFailure.isOffline(URLError(.networkConnectionLost)))
        XCTAssertTrue(NetworkFailure.isOffline(URLError(.cannotFindHost)))
        XCTAssertTrue(NetworkFailure.isOffline(URLError(.cannotConnectToHost)))
    }

    /// A timeout with the network up is a slow provider: it keeps its own wording, and
    /// the network coming back is no reason to retry it.
    func testATimeoutIsNotOffline() {
        XCTAssertFalse(NetworkFailure.isOffline(URLError(.timedOut)))
    }

    /// A provider that answered — however badly — was reached.
    func testAProviderErrorIsNotOffline() {
        XCTAssertFalse(NetworkFailure.isOffline(URLError(.badServerResponse)))
        XCTAssertFalse(NetworkFailure.isOffline(URLError(.userAuthenticationRequired)))
        XCTAssertFalse(NetworkFailure.isOffline(NSError(domain: "GroqError", code: -1009)),
                       "the code alone means nothing outside URLSession's domain")
        XCTAssertFalse(NetworkFailure.isOffline(CancellationError()))
    }

    /// A socket reports the interface going away in POSIX terms, sometimes wrapped.
    func testAWrappedPOSIXNetworkDownIsOffline() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENETDOWN))
        XCTAssertTrue(NetworkFailure.isOffline(posix))
        let wrapped = NSError(domain: "SomeWrapper", code: 1, userInfo: [NSUnderlyingErrorKey: posix])
        XCTAssertTrue(NetworkFailure.isOffline(wrapped))
        XCTAssertFalse(NetworkFailure.isOffline(NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))))
    }
}

// MARK: - A batch upload with no network

private final class ThrowingBatchTranscriber: BatchTranscriber, @unchecked Sendable {
    let error: Error
    init(_ error: Error) { self.error = error }
    func transcribe(audioFileURL: URL, language: String?) async throws -> String { throw error }
}

final class OfflineOutcomeTests: XCTestCase {

    /// Half a second of a sine at 48 kHz: long enough to be uploaded, loud enough to be heard.
    private func audibleWriter() -> AudioBufferWriter {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let writer = AudioBufferWriter()
        writer.prepare(sourceFormat: format)
        for _ in 0 ..< 5 {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
            buffer.frameLength = 4_800
            for frame in 0 ..< 4_800 {
                buffer.floatChannelData![0][frame] = 0.5 * Float(sin(2.0 * .pi * 440 * Double(frame) / 48_000))
            }
            writer.append(buffer)
        }
        return writer
    }

    /// The audio is handed back for the archive, and the outcome says why it failed —
    /// which is what turns "Transcription failed" into "saved to History".
    func testAnUploadWithNoNetworkIsOfflineAndKeepsItsAudio() async throws {
        let session = BatchRecognitionSession(provider: ThrowingBatchTranscriber(URLError(.notConnectedToInternet)),
                                              writer: audibleWriter(), language: nil, languages: [])
        let outcome = await session.finish()
        let file = try XCTUnwrap(outcome.audioFileURL)
        defer { AudioBufferWriter.cleanup(fileURL: file) }

        XCTAssertTrue(outcome.offline)
        XCTAssertNotNil(outcome.error)
        XCTAssertEqual(outcome.text, "")
    }

    func testAProviderErrorIsNotOffline() async throws {
        let session = BatchRecognitionSession(provider: ThrowingBatchTranscriber(URLError(.timedOut)),
                                              writer: audibleWriter(), language: nil, languages: [])
        let outcome = await session.finish()
        outcome.audioFileURL.map(AudioBufferWriter.cleanup(fileURL:))

        XCTAssertFalse(outcome.offline)
        XCTAssertNotNil(outcome.error)
    }
}

// MARK: - When saved dictations are retried (OfflineRetryQueue.swift)

final class OfflineRetryQueueTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()

    /// The monitor's first report is the current state, not the network coming back.
    func testTheFirstReportIsNoEdge() {
        var fresh = OfflineRetryQueue()
        XCTAssertFalse(fresh.enqueue(a), "nothing is known about the network yet")
        XCTAssertFalse(fresh.networkChanged(isUp: true), "a first report of 'up' is not a return")
    }

    /// Wi-Fi off, dictate twice, Wi-Fi on: one drain, oldest first.
    func testTheNetworkComingBackDrainsOldestFirst() {
        var queue = OfflineRetryQueue()
        XCTAssertFalse(queue.networkChanged(isUp: false))
        XCTAssertFalse(queue.enqueue(a))
        XCTAssertFalse(queue.enqueue(b))
        XCTAssertTrue(queue.networkChanged(isUp: true))

        XCTAssertEqual(queue.beginDrain(), a)
        XCTAssertNil(queue.beginDrain(), "one drain at a time")
        XCTAssertEqual(queue.finished(a, .succeeded), b)
        XCTAssertNil(queue.finished(b, .succeeded))
        XCTAssertTrue(queue.pending.isEmpty)
        XCTAssertFalse(queue.isDraining)
    }

    /// Nothing waiting: the network coming back does nothing.
    func testAnEmptyQueueIgnoresTheNetwork() {
        var queue = OfflineRetryQueue()
        _ = queue.networkChanged(isUp: false)
        XCTAssertFalse(queue.networkChanged(isUp: true))
    }

    /// Still no network for the first: it and everything behind it wait for the next return.
    func testFindingNoNetworkAgainStopsTheDrainAndKeepsEverything() {
        var queue = OfflineRetryQueue()
        _ = queue.networkChanged(isUp: false)
        _ = queue.enqueue(a); _ = queue.enqueue(b)
        _ = queue.networkChanged(isUp: true)
        XCTAssertEqual(queue.beginDrain(), a)
        XCTAssertNil(queue.finished(a, .offline))
        XCTAssertEqual(queue.pending, [a, b])
        XCTAssertFalse(queue.isDraining)

        _ = queue.networkChanged(isUp: false)
        XCTAssertTrue(queue.networkChanged(isUp: true))
        XCTAssertEqual(queue.beginDrain(), a)
    }

    /// Any other failure — or a record the user retried or deleted — leaves the queue,
    /// and the drain goes on to the next.
    func testADroppedRecordLeavesAndTheDrainGoesOn() {
        var queue = OfflineRetryQueue()
        _ = queue.networkChanged(isUp: false)
        _ = queue.enqueue(a); _ = queue.enqueue(b)
        _ = queue.networkChanged(isUp: true)
        XCTAssertEqual(queue.beginDrain(), a)
        XCTAssertEqual(queue.finished(a, .dropped), b)
        XCTAssertEqual(queue.pending, [b])
    }

    /// The link dropped mid-upload and was back before the failure was written: no edge
    /// will come, so the record is tried at once.
    func testARecordQueuedWhileTheNetworkIsUpIsTriedAtOnce() {
        var queue = OfflineRetryQueue()
        _ = queue.networkChanged(isUp: true)
        XCTAssertTrue(queue.enqueue(a))
        XCTAssertFalse(queue.enqueue(a), "queued once")
    }

    /// One the user is retrying right now is passed over, not dropped: should their
    /// retry find no network, the next return still owes it one.
    func testARecordTheUserIsRetryingIsPassedOverAndKept() {
        var queue = OfflineRetryQueue()
        _ = queue.networkChanged(isUp: false)
        _ = queue.enqueue(a); _ = queue.enqueue(b)
        _ = queue.networkChanged(isUp: true)
        XCTAssertEqual(queue.beginDrain(), a)
        XCTAssertEqual(queue.finished(a, .busy), b)
        XCTAssertNil(queue.finished(b, .succeeded), "the busy one is not retried again in this drain")
        XCTAssertEqual(queue.pending, [a])
        XCTAssertFalse(queue.isDraining)
        XCTAssertEqual(queue.beginDrain(), a, "a later drain takes it")
    }

    /// A dictation saved during a drain joins it rather than starting another.
    func testARecordQueuedDuringADrainJoinsIt() {
        var queue = OfflineRetryQueue()
        _ = queue.networkChanged(isUp: false)
        _ = queue.enqueue(a)
        _ = queue.networkChanged(isUp: true)
        XCTAssertEqual(queue.beginDrain(), a)
        XCTAssertFalse(queue.enqueue(c), "the running drain picks it up")
        XCTAssertEqual(queue.finished(a, .succeeded), c)
    }
}

// MARK: - When a stream is reopened (NetworkFailure.swift › StreamReconnectPolicy)

final class StreamReconnectPolicyTests: XCTestCase {

    func testANetworkDropIsReopened() {
        XCTAssertTrue(StreamReconnectPolicy.isReconnectable(URLError(.networkConnectionLost)))
        XCTAssertTrue(StreamReconnectPolicy.isReconnectable(URLError(.notConnectedToInternet)))
        XCTAssertTrue(StreamReconnectPolicy.isReconnectable(URLError(.timedOut)))
        XCTAssertTrue(StreamReconnectPolicy.isReconnectable(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTCONN))))
        XCTAssertTrue(StreamReconnectPolicy.isReconnectable(NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))))
    }

    /// Held audio filled up with no session to send it to: the server never answered.
    func testNoSessionIsReopened() {
        XCTAssertTrue(StreamReconnectPolicy.isReconnectable(TranscriptionError.realtime(.elevenLabs, "no_session", "…")))
        XCTAssertTrue(StreamReconnectPolicy.isReconnectable(TranscriptionError.realtime(.openAI, "no_session", "…")))
    }

    /// A refusal would only be heard again from a new socket.
    func testARefusalIsNotReopened() {
        XCTAssertFalse(StreamReconnectPolicy.isReconnectable(TranscriptionError.realtime(.elevenLabs, "auth_error", "…")))
        XCTAssertFalse(StreamReconnectPolicy.isReconnectable(TranscriptionError.realtime(.elevenLabs, "quota_exceeded", "…")))
        XCTAssertFalse(StreamReconnectPolicy.isReconnectable(TranscriptionError.realtime(.openAI, "invalid_api_key", "…")))
        XCTAssertFalse(StreamReconnectPolicy.isReconnectable(TranscriptionError.realtime(.openAI, "transcription_failed", "…")))
        XCTAssertFalse(StreamReconnectPolicy.isReconnectable(URLError(.userAuthenticationRequired)))
    }

    /// About 26 s of trying per outage, and three outages per segment.
    func testTheAttemptsAndOutagesAreBounded() {
        let policy = StreamReconnectPolicy()
        XCTAssertEqual(policy.delay(attempt: 0, outage: 1), 0.5)
        XCTAssertNotNil(policy.delay(attempt: 7, outage: 1))
        XCTAssertNil(policy.delay(attempt: 8, outage: 1))
        XCTAssertNotNil(policy.delay(attempt: 0, outage: 3))
        XCTAssertNil(policy.delay(attempt: 0, outage: 4))
        XCTAssertEqual(policy.delays.reduce(0, +), 26.5, accuracy: 0.01)
    }
}

/// The rate-limit headers each vendor answers with, read into what is left of each window.
final class RateLimitTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testGroqsAndOpenAIsHeadersAreReadWithTheirDurations() throws {
        let snapshot = try XCTUnwrap(RateLimits.parse(vendor: .groq, model: "openai/gpt-oss-120b", headers: [
            "x-ratelimit-limit-requests": "14400", "x-ratelimit-remaining-requests": "14370",
            "x-ratelimit-reset-requests": "2m59.56s",
            "X-RateLimit-Limit-Tokens": "18000", "x-ratelimit-remaining-tokens": "17997",
            "x-ratelimit-reset-tokens": "7.66s", "content-type": "application/json",
        ], now: now))
        XCTAssertEqual(snapshot.windows.map(\.name), ["requests", "tokens"])
        let requests = snapshot.windows[0]
        XCTAssertEqual(requests.limit, 14400)
        XCTAssertEqual(requests.remaining, 14370)
        XCTAssertEqual(try XCTUnwrap(requests.resetsAt).timeIntervalSince(now), 179.56, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(requests.used), 30.0 / 14400, accuracy: 1e-9)
        XCTAssertEqual(snapshot.windows[1].resetsAt?.timeIntervalSince(now) ?? 0, 7.66, accuracy: 0.001)
        XCTAssertEqual(RateLimits.logLine(snapshot), "requests 14370 of 14400 · tokens 17997 of 18000")
    }

    func testAnthropicsHeadersAreReadWithTheirTimes() throws {
        let snapshot = try XCTUnwrap(RateLimits.parse(vendor: .anthropic, model: "claude-sonnet-5", headers: [
            "anthropic-ratelimit-requests-limit": "50", "anthropic-ratelimit-requests-remaining": "49",
            "anthropic-ratelimit-requests-reset": "2027-01-15T08:00:30Z",
            "anthropic-ratelimit-input-tokens-limit": "30000", "anthropic-ratelimit-input-tokens-remaining": "27000",
        ], now: now))
        XCTAssertEqual(snapshot.windows.map(\.name), ["input-tokens", "requests"])
        XCTAssertEqual(snapshot.windows[1].remaining, 49)
        XCTAssertEqual(snapshot.windows[1].resetsAt, ISO8601DateFormatter().date(from: "2027-01-15T08:00:30Z"))
    }

    func testAWindowAVendorAddsLaterIsKeptAndAReplyWithNoneHasNoSnapshot() {
        let audio = RateLimits.parse(vendor: .groq, model: "whisper-large-v3-turbo",
                                     headers: ["x-ratelimit-remaining-audio-seconds": "7100"], now: now)
        XCTAssertEqual(audio?.windows, [RateLimitWindow(name: "audio-seconds", remaining: 7100)])
        XCTAssertNil(RateLimits.parse(vendor: .elevenLabs, model: "scribe_v2", headers: ["request-id": "x"], now: now))
    }

    func testResetDurationsInGosNotation() {
        XCTAssertEqual(RateLimits.duration("1h2m3.5s"), 3723.5)
        XCTAssertEqual(RateLimits.duration("120ms"), 0.12)
        XCTAssertEqual(RateLimits.duration("6m0s"), 360)
        XCTAssertNil(RateLimits.duration("soon"))
        XCTAssertNil(RateLimits.duration(""))
    }
}
