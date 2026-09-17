// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

private let gb: UInt64 = 1_073_741_824

/// Hardware is constructed, never read: `SystemCapabilities.current()` would make every
/// assertion here a statement about the machine the tests happen to run on.
private func mac(ram: UInt64, disk: UInt64 = 2000, appleSilicon: Bool = true) -> SystemCapabilities {
    SystemCapabilities(chipName: appleSilicon ? "Apple M5" : "Intel Core i7",
                       isAppleSilicon: appleSilicon, cores: 10,
                       memoryBytes: ram * gb, freeDiskBytes: disk * gb)
}

// MARK: - Tiers

final class MacTierTests: XCTestCase {

    /// Every configuration Apple sells lands in the tier the recommendation tables were
    /// written for — including the sizes that sit right at a boundary.
    func testCurrentLineupMapsToTheIntendedTiers() {
        XCTAssertEqual(MacTier(mac(ram: 8)), .entry)        // MacBook Neo
        XCTAssertEqual(MacTier(mac(ram: 16)), .standard)    // MacBook Air M5, iMac, Mac mini
        XCTAssertEqual(MacTier(mac(ram: 18)), .standard)    // older M3 Pro
        XCTAssertEqual(MacTier(mac(ram: 24)), .plus)        // M5 Pro base
        XCTAssertEqual(MacTier(mac(ram: 32)), .plus)
        XCTAssertEqual(MacTier(mac(ram: 36)), .pro)         // M5 Max base
        XCTAssertEqual(MacTier(mac(ram: 64)), .pro)
        XCTAssertEqual(MacTier(mac(ram: 96)), .max)         // Mac Studio M5 Ultra base
        XCTAssertEqual(MacTier(mac(ram: 128)), .max)
        XCTAssertEqual(MacTier(mac(ram: 256)), .ultra)
        XCTAssertEqual(MacTier(mac(ram: 512)), .ultra)
    }

    func testIntelIsItsOwnTierWhateverItsMemory() {
        XCTAssertEqual(MacTier(mac(ram: 64, appleSilicon: false)), .intel)
    }
}

// MARK: - Speech model recommendation

final class LocalSTTRecommendationTests: XCTestCase {

    func testCatalogueIsHeaviestFirstAndEveryPickExists() {
        let sizes = localSTTModels.map(\.downloadBytes)
        XCTAssertEqual(sizes, sizes.sorted(by: >))
        XCTAssertEqual(Set(localSTTModels.map(\.id)).count, localSTTModels.count)
        XCTAssertNotNil(localSTTModel(id: defaultLocalSTTModel))
        // A typo in a tier table would silently skip a candidate rather than fail.
        for tier in MacTier.allCases {
            let picks = localSTTPicks(for: tier)
            for id in picks.recommended + picks.bestQuality {
                XCTAssertNotNil(localSTTModel(id: id), "\(tier): \(id) is not in the catalogue")
            }
        }
    }

    func testAppleSiliconIsRecommendedTurboFromNeoToStudio() {
        for ram: UInt64 in [8, 16, 32, 64, 128, 512] {
            XCTAssertEqual(recommendedLocalSTTModel(for: mac(ram: ram))?.id, defaultLocalSTTModel, "\(ram) GB")
        }
    }

    /// The full model measured no more accurate than Turbo and slower, so no tier is
    /// steered to it — it is only there to be chosen by hand.
    func testNoTierIsSteeredToTheFullModel() {
        for ram: UInt64 in [8, 16, 24, 64, 512] {
            XCTAssertEqual(bestQualityLocalSTTModel(for: mac(ram: ram))?.id, defaultLocalSTTModel, "\(ram) GB")
        }
    }

    func testIntelNeverGetsTheLargeModelsWhateverItsMemory() {
        XCTAssertEqual(recommendedLocalSTTModel(for: mac(ram: 64, appleSilicon: false))?.id, "openai_whisper-base")
        XCTAssertEqual(bestQualityLocalSTTModel(for: mac(ram: 64, appleSilicon: false))?.id, "openai_whisper-small_216MB")
    }

    func testDiskSpaceStepsDownAndKeepsHeadroom() {
        // 1 GB free is all headroom: nothing fits.
        XCTAssertNil(recommendedLocalSTTModel(for: mac(ram: 32, disk: 1)))
        // 1.5 GB free leaves 0.5 GB usable — the 646 MB turbo model must not be offered.
        let tight = SystemCapabilities(chipName: "Apple M5", isAppleSilicon: true, cores: 10,
                                       memoryBytes: 32 * gb, freeDiskBytes: gb + gb / 2)
        XCTAssertEqual(recommendedLocalSTTModel(for: tight)?.id, "openai_whisper-small_216MB")
    }

    func testReasonNamesTheCase() {
        XCTAssertTrue(localSTTRecommendationReason(for: mac(ram: 64, appleSilicon: false)).contains("Neural Engine"))
        XCTAssertTrue(localSTTRecommendationReason(for: mac(ram: 32, disk: 1)).contains("disk"))
        XCTAssertTrue(localSTTRecommendationReason(for: mac(ram: 8)).contains("MacBook Neo"))
    }
}

// MARK: - Chat model recommendation

final class LocalLLMRecommendationTests: XCTestCase {

    func testCatalogueIsHeaviestFirstAndEveryPickExists() {
        let sizes = localLLMModels.map(\.downloadBytes)
        XCTAssertEqual(sizes, sizes.sorted(by: >))
        for tier in MacTier.allCases {
            let picks = localLLMPicks(for: tier)
            for id in picks.recommended + picks.bestQuality {
                XCTAssertNotNil(localLLMModel(id: id), "\(tier): \(id) is not in the catalogue")
            }
        }
    }

    /// The approved table, one row per tier: (RAM, recommended, best quality).
    func testEachTierGetsItsPair() {
        let table: [(UInt64, String, String)] = [
            (8, "qwen3.5:4b", "qwen3.5:4b"),                   // MacBook Neo
            (16, "gemma4:12b", "gemma4:12b"),                  // MacBook Air M5
            (32, "gemma4:12b", "qwen3.8:27b"),                 // 32 GB Air / Pro
            (64, "gemma4:26b", "qwen3.8:27b"),                 // M5 Pro / Max
            (128, "gpt-oss:120b", "qwen3.5:122b"),             // M5 Max 128 GB
            (512, "gpt-oss:120b", "qwen3.5:122b"),             // Mac Studio M5 Ultra
        ]
        for (ram, recommended, best) in table {
            XCTAssertEqual(recommendedLocalLLMModel(for: mac(ram: ram))?.id, recommended, "\(ram) GB recommended")
            XCTAssertEqual(bestQualityLocalLLMModel(for: mac(ram: ram))?.id, best, "\(ram) GB best quality")
        }
    }

    func testBottomOfATierStepsDownRatherThanOverfilling() {
        // 24 GB is the "plus" tier, but Qwen3.8 27B wants 32 GB.
        XCTAssertEqual(bestQualityLocalLLMModel(for: mac(ram: 24))?.id, "gemma4:12b")
        // 96 GB is the "max" tier, but Qwen3.5 122B wants 128 GB.
        XCTAssertEqual(bestQualityLocalLLMModel(for: mac(ram: 96))?.id, "gpt-oss:120b")
    }

    func testIntelIsNotExcludedFromLocalLLMs() {
        // Ollama runs on Metal, which Intel Macs have — unlike the Neural Engine.
        XCTAssertEqual(recommendedLocalLLMModel(for: mac(ram: 16, appleSilicon: false))?.id, "qwen3.5:4b")
    }

    func testDiskSpaceStepsDown() {
        // 18 GiB free is 17 GiB (18.25 GB) usable: Gemma 4 26B (18.6 GB) no longer fits, and
        // neither does Qwen3.6 35B, so the 64 GB Mac steps down to Gemma 4 12B.
        XCTAssertEqual(recommendedLocalLLMModel(for: mac(ram: 64, disk: 18))?.id, "gemma4:12b")
    }

    func testVersionComparisonIsNumericPerComponent() {
        XCTAssertTrue(ollamaVersion("0.34.1", isAtLeast: "0.32.12"))
        XCTAssertTrue(ollamaVersion("0.32.12", isAtLeast: "0.32.12"))
        // A string comparison gets this one backwards.
        XCTAssertFalse(ollamaVersion("0.32.6", isAtLeast: "0.32.12"))
        // The case that prompted the check: 0.18.1 cannot load Qwen3.8.
        XCTAssertFalse(ollamaVersion("0.18.1", isAtLeast: "0.32.12"))
        XCTAssertTrue(ollamaVersion("0.35", isAtLeast: "0.34.1"))
        XCTAssertTrue(ollamaVersion("0.34.1-rc2", isAtLeast: "0.34.1"))
        // Unparseable counts as new enough rather than locking the user out.
        XCTAssertTrue(ollamaVersion("dev", isAtLeast: "0.32.12"))
    }

    func testEveryModelDeclaresAParseableMinimumVersion() {
        for model in localLLMModels {
            XCTAssertFalse(ollamaVersion("0.0.1", isAtLeast: model.minimumOllamaVersion), model.id)
        }
    }

    func testReasoningIsTurnedDownAsFarAsEachModelAllows() {
        XCTAssertEqual(ollamaReasoningEffort(for: "gpt-oss:120b"), "low")
        XCTAssertEqual(ollamaReasoningEffort(for: "qwen3.5:9b"), "none")
        XCTAssertEqual(ollamaReasoningEffort(for: "gemma4:26b"), "none")
    }
}

// MARK: - Reasoning stripping

final class ReasoningStripTests: XCTestCase {

    func testLeadingThinkBlockIsRemovedSoTheModeMarkerLeads() {
        let raw = "<think>\nThe user wants an email.\n</think>\n\n<<mode:Email>>\nHi Oksana,"
        XCTAssertEqual(strippingReasoning(raw), "<<mode:Email>>\nHi Oksana,")
        let parsed = TextRefinementService.parse(strippingReasoning(raw))
        XCTAssertEqual(parsed.presetName, "Email")
        XCTAssertEqual(parsed.text, "Hi Oksana,")
    }

    func testTextWithoutABlockIsOnlyTrimmed() {
        XCTAssertEqual(strippingReasoning("  plain text \n"), "plain text")
    }

    func testAMidTextTagIsNotStripped() {
        let raw = "Use the <think> tag in HTML </think> examples."
        XCTAssertEqual(strippingReasoning(raw), raw)
    }

    func testAnUnterminatedBlockIsLeftAlone() {
        // A cut-off reply, not a finished deliberation — nothing is safe to remove.
        let raw = "<think>still going"
        XCTAssertEqual(strippingReasoning(raw), raw)
    }
}

// MARK: - Loose mode markers

/// Forms Qwen3.5 2B and 4B actually produced through the app's own prompt.
final class LooseModeMarkerTests: XCTestCase {
    private let presets = ["Clean-up", "Email", "Translate", "Technical / Prompt"]

    func testDoubleBracketsWithoutModePrefix() {
        let r = TextRefinementService.parse("<<Email>>\nВітаю!", presetNames: presets)
        XCTAssertEqual(r.presetName, "Email")
        XCTAssertEqual(r.text, "Вітаю!")
    }

    func testSingleBracketsWithModePrefixAndClosingTag() {
        let r = TextRefinementService.parse("<mode:Translate>\nI received your letter.\n</mode:Translate>", presetNames: presets)
        XCTAssertEqual(r.presetName, "Translate")
        XCTAssertEqual(r.text, "I received your letter.")
    }

    func testNameWithSpacesAndDifferentCase() {
        let r = TextRefinementService.parse("<<technical / prompt>>\nfix it", presetNames: presets)
        XCTAssertEqual(r.presetName, "Technical / Prompt")
        XCTAssertEqual(r.text, "fix it")
    }

    func testAngleBracketsThatAreNotAPresetStay() {
        let raw = "<div>Hello</div>"
        XCTAssertEqual(TextRefinementService.parse(raw, presetNames: presets).text, raw)
        XCTAssertNil(TextRefinementService.parse(raw, presetNames: presets).presetName)
    }

    func testWithoutPresetNamesTheStrictParserIsUnchanged() {
        XCTAssertEqual(TextRefinementService.parse("<<Email>>\nHi").text, "<<Email>>\nHi")
    }
}

// MARK: - RecordingConfiguration for the local tier

final class LocalRecordingConfigurationTests: XCTestCase {

    private func config(_ provider: STTProviderType, groqKey: String = "gk", elevenKey: String = "ek",
                        localModel: String = "openai_whisper-base") -> RecordingConfiguration {
        RecordingConfiguration(provider: provider, locale: "uk-UA", localeIsAutomatic: true,
                               groqAPIKey: groqKey, groqModel: "whisper-large-v3-turbo",
                               elevenLabsAPIKey: elevenKey, elevenLabsModel: "scribe_v2",
                               localModel: localModel)
    }

    func testLocalUsesItsModelAndNoKey() {
        let c = config(.local)
        XCTAssertEqual(c.batchModel, "openai_whisper-base")
        XCTAssertEqual(c.batchAPIKey, "")
        XCTAssertFalse(c.streams)
        // Auto leaves detection to Whisper, exactly like the cloud tiers.
        XCTAssertNil(c.cloudLanguage)
        XCTAssertEqual(c.historyLocale, autoLanguageID)
    }

    func testRetryReadinessAsksForAModelNotAKey() {
        let c = config(.local, groqKey: "", elevenKey: "")
        XCTAssertNil(c.batchUnavailableReason(modelInstalled: { _ in true }))
        let reason = c.batchUnavailableReason(modelInstalled: { _ in false })
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("Whisper Base"))
        XCTAssertFalse(reason!.contains("API key"))
    }

    func testRetryReadinessForCloudTiersIsUnchanged() {
        XCTAssertNil(config(.groq).batchUnavailableReason(modelInstalled: { _ in false }))
        XCTAssertNotNil(config(.groq, groqKey: "").batchUnavailableReason())
        XCTAssertNotNil(config(.apple, groqKey: "").batchUnavailableReason())
        XCTAssertTrue(config(.elevenlabs, elevenKey: "").batchUnavailableReason()!.contains("ElevenLabs"))
    }

    func testUnregisteredLocalProviderFailsLoudly() async {
        // The test target never registers WhisperKit — which is exactly the state that
        // must produce an error rather than an empty "successful" transcript.
        let provider = makeBatchProvider(configuration: config(.local))
        do {
            _ = try await provider.transcribe(audioFileURL: URL(fileURLWithPath: "/dev/null"), language: nil)
            XCTFail("expected the unregistered local tier to throw")
        } catch {
            XCTAssertTrue(error is LocalModelError)
        }
    }
}
