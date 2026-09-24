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

final class InstallLocationTests: XCTestCase {
    private let image = MountedDiskImage(imagePath: "/Users/me/Downloads/SpeechText-0.9.0.dmg",
                                         mountPoint: "/Volumes/SpeechText 0.9.0")
    private let other = MountedDiskImage(imagePath: "/Users/me/Downloads/Other.dmg", mountPoint: "/Volumes/Other")

    private func decide(_ path: String, _ images: [MountedDiskImage]) -> InstallLocation {
        InstallLocation.decide(bundlePath: path, appName: "SpeechText", images: images)
    }

    func testOpenedFromTheImageHasToMove() {
        XCTAssertEqual(decide("/Volumes/SpeechText 0.9.0/SpeechText.app", [other, image]), .inDiskImage(image))
    }

    /// A quarantined app runs from a random path that names no volume.
    func testATranslocatedAppIsMatchedToItsImage() {
        let translocated = "/private/var/folders/xy/T/AppTranslocation/8C1E/d/SpeechText.app"
        XCTAssertEqual(decide(translocated, [other, image]), .inDiskImage(image))
        XCTAssertEqual(decide(translocated, [other]), .inDiskImage(nil))
    }

    func testInstalledWithTheImageStillMountedOffersToPutItAway() {
        XCTAssertEqual(decide("/Applications/SpeechText.app", [other, image]), .leftoverImage(image))
        XCTAssertEqual(decide("/Applications/SpeechText.app", [other]), .installed)
    }

    /// Running inside a volume is matched by whole path component: a volume whose name
    /// only begins like the one the app is on does not contain it.
    func testAMountPointIsMatchedByWholeComponent() {
        let shorter = MountedDiskImage(imagePath: "/x.dmg", mountPoint: "/Volumes/SpeechText")
        XCTAssertEqual(decide("/Volumes/SpeechText 0.9.0/SpeechText.app", [shorter]), .leftoverImage(shorter))
    }

    /// An image is this app's by its file's or its volume's name — never by reading it.
    func testAnImageIsKnownByItsName() {
        let renamed = MountedDiskImage(imagePath: "/Users/me/Downloads/download.dmg", mountPoint: "/Volumes/SpeechText")
        XCTAssertEqual(decide("/Applications/SpeechText.app", [renamed]), .leftoverImage(renamed))
        let byFile = MountedDiskImage(imagePath: "/Users/me/Downloads/speechtext-0.9.0.dmg", mountPoint: "/Volumes/Untitled")
        XCTAssertEqual(decide("/Applications/SpeechText.app", [byFile]), .leftoverImage(byFile))
    }

    /// A build run from Xcode is never asked to move.
    func testADevelopmentBuildCountsAsInstalled() {
        let derived = "/Users/me/Library/Developer/Xcode/DerivedData/SpeechText-abc/Build/Products/Debug/SpeechText.app"
        XCTAssertEqual(decide(derived, [other]), .installed)
    }

    func testHdiutilInfoIsRead() throws {
        let plist: [String: Any] = ["images": [
            ["image-path": "/Users/me/Downloads/SpeechText-0.9.0.dmg",
             "system-entities": [["content-hint": "GUID_partition_scheme"],
                                 ["content-hint": "Apple_HFS", "mount-point": "/Volumes/SpeechText 0.9.0"]]],
            ["image-path": "/tmp/raw.dmg", "system-entities": [["content-hint": "Apple_HFS"]]],
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        XCTAssertEqual(MountedDiskImage.parse(hdiutilInfo: data), [image])
        XCTAssertEqual(MountedDiskImage.parse(hdiutilInfo: Data("not a plist".utf8)), [])
    }
}
