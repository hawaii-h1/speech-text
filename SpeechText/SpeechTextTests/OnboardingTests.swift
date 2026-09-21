// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

final class OnboardingGateTests: XCTestCase {
    func testANewInstallSeesSetup() {
        XCTAssertEqual(OnboardingGate.decide(completed: nil, hasUsedTheAppBefore: false), .show)
    }

    /// There was no marker before setup existed: an install that already stored settings
    /// has done its setup, and is marked done rather than walked through it again.
    func testAnExistingInstallIsMarkedDone() {
        XCTAssertEqual(OnboardingGate.decide(completed: nil, hasUsedTheAppBefore: true), .markCompleted)
    }

    /// Setup closed half-way stores `false`, and opens again even though settings exist.
    func testAnUnfinishedSetupOpensAgain() {
        XCTAssertEqual(OnboardingGate.decide(completed: false, hasUsedTheAppBefore: true), .show)
        XCTAssertEqual(OnboardingGate.decide(completed: true, hasUsedTheAppBefore: false), .skip)
    }

    func testStepsKeepTheirOrderAndStoredNames() {
        XCTAssertLessThan(OnboardingStep.speech, OnboardingStep.ai)
        XCTAssertLessThan(OnboardingStep.tryIt, OnboardingStep.done)
        XCTAssertEqual(OnboardingStep(rawValue: "try"), .tryIt)
        XCTAssertEqual(OnboardingStep.named.count, 5)
    }
}

final class SetupServiceTests: XCTestCase {
    private let long = String(repeating: "a1B2", count: 8)

    func testKeyShapesTellTheServicesApart() {
        XCTAssertTrue(SetupService.groq.looksLikeKey("gsk_\(long)"))
        XCTAssertTrue(SetupService.elevenLabs.looksLikeKey("  sk_\(long)\n"))
        XCTAssertTrue(SetupService.anthropic.looksLikeKey("sk-ant-api03-\(long)"))
        XCTAssertTrue(SetupService.openAI.looksLikeKey("sk-proj-\(long)"))
        // An Anthropic key is not an OpenAI one, though both begin "sk-".
        XCTAssertFalse(SetupService.openAI.looksLikeKey("sk-ant-api03-\(long)"))
        XCTAssertFalse(SetupService.elevenLabs.looksLikeKey("gsk_\(long)"))
    }

    /// Whatever else is on the clipboard is never taken for a key.
    func testClipboardTextThatIsNotAKeyIsIgnored() {
        XCTAssertFalse(SetupService.groq.looksLikeKey("gsk_short"))
        XCTAssertFalse(SetupService.groq.looksLikeKey("gsk_\(long) and some words"))
        XCTAssertFalse(SetupService.groq.looksLikeKey("Meeting notes for Tuesday"))
    }

    func testVerdicts() {
        XCTAssertEqual(SetupService.verdict(statusCode: 200, body: "{}"), .valid)
        XCTAssertEqual(SetupService.verdict(statusCode: 429, body: "slow down"), .valid)
        XCTAssertEqual(SetupService.verdict(statusCode: 401, body: #"{"error":"invalid_api_key"}"#), .invalid)
        XCTAssertEqual(SetupService.verdict(statusCode: 500, body: ""), .unreachable)
    }

    /// A key scoped to Speech to Text only is refused the model list, and still works.
    func testAScopedKeyIsValid() {
        let body = #"{"detail":{"status":"missing_permissions","message":"The API key you used is missing the permission models_read"}}"#
        XCTAssertEqual(SetupService.verdict(statusCode: 401, body: body), .valid)
        XCTAssertEqual(SetupService.verdict(statusCode: 403, body: "You have insufficient permissions for this operation."), .valid)
    }

    func testVerificationRequestsAuthenticate() {
        let groq = SetupService.groq.verificationRequest(key: " gsk_x ")
        XCTAssertEqual(groq.value(forHTTPHeaderField: "Authorization"), "Bearer gsk_x")
        let anthropic = SetupService.anthropic.verificationRequest(key: "k")
        XCTAssertEqual(anthropic.value(forHTTPHeaderField: "x-api-key"), "k")
        XCTAssertNotNil(anthropic.value(forHTTPHeaderField: "anthropic-version"))
        XCTAssertEqual(SetupService.elevenLabs.verificationRequest(key: "k").value(forHTTPHeaderField: "xi-api-key"), "k")
    }
}
