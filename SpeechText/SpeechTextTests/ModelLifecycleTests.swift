// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// The catalogues' lifecycle (#19): what is offered, what is still known, where a retired
/// model's users go, and that nothing is left behind.
final class ModelLifecycleTests: XCTestCase {

    // MARK: Invariants over the catalogues and the archive

    /// Every speech link the chain can follow, catalogue and archive, by vendor.
    private var speechIDs: [(vendor: Provider, id: String)] {
        sttModelCatalog.map { ($0.vendor, $0.id) } + archivedSpeechModels.map { ($0.vendor, $0.id) }
    }

    private var chatIDs: [(provider: LLMProviderType, id: String)] {
        chatModelCatalog.map { ($0.provider, $0.id) }
            + archivedChatModels.compactMap { row in
                LLMProviderType.allCases.first { $0.vendor == row.vendor }.map { ($0, row.id) }
            }
    }

    /// Every model the vendor retires leads, through its replacements, to a model of the
    /// same vendor that is offered — no cycle, no dead end, no hop to another vendor
    /// (the chain only ever looks inside one vendor, so ending offered proves it).
    func testEveryReplacementChainEndsOnAnOfferedModelOfTheSameVendor() {
        for (vendor, id) in speechIDs {
            let link = { speechLifecycleLink(vendor: vendor, id: $0) }
            let end = resolvedReplacement(of: id, link: link)
            XCTAssertNotNil(end, "\(vendor.rawValue)/\(id) leads nowhere")
            if let end { XCTAssertTrue(offeredSTTModels(of: vendor).contains { $0.id == end }, end) }
        }
        for (provider, id) in chatIDs {
            let end = resolvedReplacement(of: id) { chatLifecycleLink(provider: provider, id: $0) }
            XCTAssertNotNil(end, "\(provider.rawValue)/\(id) leads nowhere")
            if let end { XCTAssertTrue(offeredChatModels(of: provider).contains { $0.id == end }, end) }
        }
    }

    /// A superseded model points at a model of its own vendor that is offered, and is not
    /// itself its successor.
    func testEverySupersededModelPointsAtAnOfferedOne() {
        for model in sttModelCatalog {
            guard case .superseded(let by) = model.lifecycle else { continue }
            XCTAssertNotEqual(by, model.id)
            XCTAssertTrue(offeredSTTModels(of: model.vendor).contains { $0.id == by }, model.id)
        }
        for model in chatModelCatalog {
            guard case .superseded(let by) = model.lifecycle else { continue }
            XCTAssertNotEqual(by, model.id)
            XCTAssertTrue(offeredChatModels(of: model.provider).contains { $0.id == by }, model.id)
        }
    }

    /// A realtime model's fallback upload is a model that is offered: a stream that drops
    /// must not land on a model the vendor is switching off.
    func testEveryUploadTargetIsOffered() {
        for model in sttModelCatalog where model.lifecycle.isOffered {
            guard case .model(let id) = model.batchUpload else { continue }
            XCTAssertTrue(offeredSTTModels(of: model.vendor).contains { $0.id == id }, model.id)
        }
    }

    /// A local model can only be superseded: moving a stored choice to a local model at
    /// launch would point it at files nobody downloaded.
    func testALocalModelIsNeverDeprecated() {
        for model in localSTTModels {
            XCTAssertNil(model.lifecycle.deprecation, model.id)
        }
        for model in knownChatModels(of: .ollama) {
            XCTAssertEqual(model.lifecycle, .current, model.id)
        }
    }

    /// Each ID is in the catalogue or the archive, never both and never twice.
    func testEveryModelIsInOnePlaceOnly() {
        for vendor in Provider.allCases {
            let ids = knownSTTModels(of: vendor).map(\.id) + archivedSpeechModels.filter { $0.vendor == vendor }.map(\.id)
            XCTAssertEqual(ids.count, Set(ids).count, vendor.rawValue)
        }
        for provider in LLMProviderType.allCases {
            let ids = knownChatModels(of: provider).map(\.id)
                + archivedChatModels.filter { $0.vendor == provider.vendor }.map(\.id)
            XCTAssertEqual(ids.count, Set(ids).count, provider.rawValue)
        }
    }

    /// A deprecated entry outlives the vendor's shutdown by `ModelRetirement.termMonths`,
    /// then moves to the archive (docs/adding-a-provider.md › Retiring a model). This test
    /// starts failing on the day that is due, so the move is not forgotten.
    func testNoDeprecatedEntryHasOutlivedItsTerm() {
        let deprecations = sttModelCatalog.compactMap { m in m.lifecycle.deprecation.map { (m.id, $0) } }
            + chatModelCatalog.compactMap { m in m.lifecycle.deprecation.map { (m.id, $0) } }
        for (id, deprecation) in deprecations {
            let due = try? XCTUnwrap(ModelRetirement.archiveBy(deprecation), id)
            XCTAssertNotNil(due, id)
            if let due {
                XCTAssertLessThan(Date(), due, "\(id) is due for the archive (archivedSpeechModels / archivedChatModels)")
            }
            XCTAssertNotNil(deprecation.announced.date, id)
            if let announced = deprecation.announced.date, let shutdown = deprecation.shutdown.date {
                XCTAssertLessThan(announced, shutdown, id)
            }
        }
        XCTAssertEqual(ModelRetirement.termMonths, 6)
    }

    /// The day the vendors' deprecation pages were last read; change it with the check.
    func testTheDeprecationCheckHasItsDate() {
        XCTAssertEqual(UsagePrices.deprecationsChecked.date,
                       DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 10, day: 16).date)
    }

    // MARK: The first case

    func testGPT4oMiniTranscribeIsRetiringIntoGPTTranscribe() throws {
        let model = sttModel(vendor: .openAI, id: "gpt-4o-mini-transcribe")
        let deprecation = try XCTUnwrap(model.lifecycle.deprecation)
        XCTAssertEqual(deprecation.replacement, "gpt-transcribe")
        XCTAssertEqual(deprecation.announced.date, ModelRetirement.day(2026, 8, 26).date)
        XCTAssertEqual(deprecation.shutdown.date, ModelRetirement.day(2027, 2, 26).date)
        XCTAssertEqual(deprecation.source.host, "developers.openai.com")
        // Still priced, so History records made with it keep their cost.
        XCTAssertEqual(model.price, .listed(SpeechRates(perMinute: 0.003)))
        XCTAssertEqual(UsagePrices.speech(vendor: .openAI, model: "gpt-4o-mini-transcribe"),
                       .listed(SpeechRates(perMinute: 0.003)))
        XCTAssertEqual(UsagePrices.speechName(vendor: .openAI, model: "gpt-4o-mini-transcribe"), "GPT-4o mini Transcribe")
        XCTAssertFalse(offeredSTTModels(of: .openAI).contains { $0.id == model.id })
    }

    /// A History record made with the retiring model still costs what it cost.
    func testARecordOfADeprecatedModelIsStillPriced() {
        let price = UsagePrices.speech(provider: "openai", model: "gpt-4o-mini-transcribe")
        guard case .listed(let rates) = price else { return XCTFail("not priced: \(price)") }
        XCTAssertEqual(rates.perMinute, 0.003, accuracy: 1e-9)
    }

    /// An archived model is still named and priced from its one line.
    func testAnArchivedModelKeepsItsNameAndPrice() {
        for row in archivedSpeechModels {
            let model = sttModel(vendor: row.vendor, id: row.id)
            XCTAssertEqual(model.displayName, row.displayName)
            XCTAssertEqual(model.price, row.price)
            XCTAssertEqual(model.lifecycle.status(on: Date()), "Retired")
        }
        for row in archivedChatModels {
            guard let provider = LLMProviderType.allCases.first(where: { $0.vendor == row.vendor }) else { continue }
            XCTAssertEqual(chatModel(provider: provider, id: row.id).price, row.price)
            XCTAssertEqual(knownChatModelName(id: row.id), row.displayName)
        }
    }

    // MARK: What a picker row says

    func testAPickerSaysRetiringOnTheDateThenRetired() {
        let lifecycle = sttModel(vendor: .openAI, id: "gpt-4o-mini-transcribe").lifecycle
        XCTAssertEqual(lifecycle.status(on: ModelRetirement.day(2026, 10, 16).date!), "Retiring on 26 Feb 2027")
        XCTAssertEqual(lifecycle.status(on: ModelRetirement.day(2027, 2, 26).date!), "Retired")
        XCTAssertNil(ModelLifecycle.current.status(on: Date()))
        XCTAssertNil(ModelLifecycle.superseded(by: "x").status(on: Date()))
    }

    /// A deprecated model still selected is listed after the offered ones, so the picker
    /// is never blank; an offered one adds nothing.
    func testAPickerListsTheSelectedModelEvenWhenItIsNotOffered() {
        let ids = pickerSTTModels(of: .openAI, selected: "gpt-4o-mini-transcribe").map(\.id)
        XCTAssertEqual(ids, ["gpt-transcribe", openAIRealtimeSTTModel, "gpt-4o-mini-transcribe"])
        XCTAssertEqual(pickerSTTModels(of: .openAI, selected: "gpt-transcribe").map(\.id),
                       offeredSTTModels(of: .openAI).map(\.id))
        XCTAssertEqual(pickerSTTModels(of: .openAI, selected: "whisper-9").last?.id, "whisper-9")
        XCTAssertEqual(pickerChatModels(of: .openai, selected: "gpt-4.1").map(\.id),
                       offeredChatModels(of: .openai).map(\.id) + ["gpt-4.1"])
        XCTAssertEqual(pickerChatModels(of: .ollama, selected: "").map(\.id), offeredChatModels(of: .ollama).map(\.id))
    }

    // MARK: Following a chain

    private func links(_ table: [String: LifecycleLink]) -> (String) -> LifecycleLink? { { table[$0] } }

    func testAChainIsFollowedToTheFirstOfferedModel() {
        let table: [String: LifecycleLink] = [
            "a": LifecycleLink(offered: false, successor: "b"),
            "b": LifecycleLink(offered: false, successor: "c"),
            "c": LifecycleLink(offered: true, successor: nil),
        ]
        XCTAssertEqual(resolvedReplacement(of: "a", link: links(table)), "c")
        XCTAssertEqual(storedModelVerdict("a", link: links(table)), .move(to: "c"))
        XCTAssertEqual(storedModelVerdict("c", link: links(table)), .keep)
    }

    func testACycleADeadEndAndAnUnknownIDAreCleared() {
        let cycle: [String: LifecycleLink] = [
            "a": LifecycleLink(offered: false, successor: "b"),
            "b": LifecycleLink(offered: false, successor: "a"),
        ]
        XCTAssertEqual(storedModelVerdict("a", link: links(cycle)), .clear)
        let deadEnd: [String: LifecycleLink] = ["a": LifecycleLink(offered: false, successor: nil)]
        XCTAssertEqual(storedModelVerdict("a", link: links(deadEnd)), .clear)
        XCTAssertEqual(storedModelVerdict("zzz", link: links([:])), .clear)
    }

    /// A superseded model is still offered and is the user's to keep.
    func testASupersededModelIsKept() {
        let table = ["old": LifecycleLink(offered: true, successor: nil), "new": LifecycleLink(offered: true, successor: nil)]
        XCTAssertEqual(storedModelVerdict("old", link: links(table)), .keep)
    }

    // MARK: The launch, on an isolated store

    private var suites: [String] = []

    private func suite() -> UserDefaults {
        let name = "ModelLifecycleTests-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    override func tearDown() {
        suites.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
        suites = []
        super.tearDown()
    }

    /// The first launch of the release that marks a model deprecated moves its users to
    /// the replacement, records the move once, and leaves every other choice alone.
    func testTheLaunchMovesARetiringModelToItsReplacement() throws {
        let defaults = suite()
        defaults.set("openai", forKey: SettingsKeys.sttProvider)
        defaults.set("gpt-4o-mini-transcribe", forKey: SettingsKeys.openAISTTModel)
        defaults.set("scribe_v2_realtime", forKey: SettingsKeys.elevenLabsModel)
        defaults.set("claude-opus-5", forKey: SettingsKeys.anthropicModel)

        normalizeStoredProviders(in: defaults, localModelOnDisk: { _ in false })

        XCTAssertEqual(defaults.string(forKey: SettingsKeys.openAISTTModel), "gpt-transcribe")
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.elevenLabsModel), "scribe_v2_realtime")
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.anthropicModel), "claude-opus-5")
        let moves = storedModelMigrations(in: defaults)
        XCTAssertEqual(moves.count, 1)
        let move = try XCTUnwrap(moves.first)
        XCTAssertEqual(move.settingsKey, SettingsKeys.openAISTTModel)
        XCTAssertEqual(move.from, "gpt-4o-mini-transcribe")
        XCTAssertEqual(move.to, "gpt-transcribe")
        XCTAssertEqual(move.reason, .deprecated)

        // The next launch has nothing left to move and records nothing more.
        normalizeStoredProviders(in: defaults, localModelOnDisk: { _ in false })
        XCTAssertEqual(storedModelMigrations(in: defaults).count, 1)
    }

    /// An ID that leads nowhere — a model deleted before lifecycles existed — is cleared,
    /// not moved to the default, and not pinned back over: the user picks.
    func testAModelThatLeadsNowhereIsClearedAndNotPinned() {
        let defaults = suite()
        defaults.set("groq", forKey: SettingsKeys.llmProvider)
        defaults.set("llama-3.3-70b-versatile", forKey: SettingsKeys.groqLLMModel)

        normalizeStoredProviders(in: defaults, localModelOnDisk: { _ in false })

        XCTAssertNil(defaults.string(forKey: SettingsKeys.groqLLMModel))
        let move = storedModelMigrations(in: defaults).last
        XCTAssertEqual(move?.reason, .unavailable)
        XCTAssertNil(move?.to)
    }

    /// An install that never picked a model has the one it runs written down, so a later
    /// change of our default reaches only new installs — and only the engine and AI
    /// provider in use are pinned.
    func testAnUntouchedChoiceIsPinnedForTheProvidersInUseOnly() {
        let defaults = suite()
        defaults.set("groq", forKey: SettingsKeys.sttProvider)
        defaults.set("anthropic", forKey: SettingsKeys.llmProvider)

        normalizeStoredProviders(in: defaults, localModelOnDisk: { _ in false })

        XCTAssertEqual(defaults.string(forKey: SettingsKeys.groqModel), Provider.groq.defaultSpeechModel)
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.anthropicModel), Provider.anthropic.defaultChatModel)
        XCTAssertNil(defaults.string(forKey: SettingsKeys.openAISTTModel))
        XCTAssertNil(defaults.string(forKey: SettingsKeys.groqLLMModel))
        XCTAssertNil(defaults.string(forKey: SettingsKeys.localSTTModel), "nothing on disk to keep")
        XCTAssertNil(defaults.string(forKey: SettingsKeys.ollamaModel))
        XCTAssertTrue(storedModelMigrations(in: defaults).isEmpty)
    }

    /// A choice the user made is never overwritten by pinning.
    func testAStoredChoiceIsNotPinnedOver() {
        let defaults = suite()
        defaults.set("groq", forKey: SettingsKeys.sttProvider)
        defaults.set("whisper-large-v3", forKey: SettingsKeys.groqModel)
        normalizeStoredProviders(in: defaults, localModelOnDisk: { _ in false })
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.groqModel), "whisper-large-v3")
    }

    /// The local tier is pinned to a model on disk whichever engine is in use: the old
    /// default first, then today's, then the heaviest installed.
    func testTheLocalModelIsPinnedOnlyToOneOnDisk() {
        let turbo = "openai_whisper-large-v3-v20240930_turbo_632MB"
        let defaults = suite()
        normalizeStoredProviders(in: defaults, localModelOnDisk: { $0 == turbo || $0 == parakeetV3ModelID })
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.localSTTModel), turbo)

        let other = suite()
        normalizeStoredProviders(in: other, localModelOnDisk: { $0 == parakeetV3ModelID })
        XCTAssertEqual(other.string(forKey: SettingsKeys.localSTTModel), parakeetV3ModelID)

        let lightest = try! XCTUnwrap(localSTTModels.last)
        let third = suite()
        normalizeStoredProviders(in: third, localModelOnDisk: { $0 == lightest.id })
        XCTAssertEqual(third.string(forKey: SettingsKeys.localSTTModel), lightest.id)
    }

    /// The two new keys describe this Mac, and stay out of `portable`.
    func testTheLifecycleKeysAreMachineLocal() {
        XCTAssertEqual(SettingsKeys.modelMigrations, "modelMigrations")
        XCTAssertEqual(SettingsKeys.modelNoticesShown, "modelNoticesShown")
        XCTAssertFalse(SettingsKeys.portable.contains(SettingsKeys.modelMigrations))
        XCTAssertFalse(SettingsKeys.portable.contains(SettingsKeys.modelNoticesShown))
    }
}
