// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// `CatalogueExport` is a contract with `scripts/check-vendor-models.sh`: these pin what
/// the script reads, so a change to the catalogues' types cannot quietly change it.
final class CatalogueExportTests: XCTestCase {
    private let export = CatalogueExport.current()

    func testEveryCatalogueEntryIsExportedOnce() {
        XCTAssertEqual(export.speech.map { "\($0.vendor)/\($0.id)" },
                       sttModelCatalog.map { "\($0.vendor.rawValue)/\($0.id)" })
        XCTAssertEqual(export.chat.map { "\($0.vendor)/\($0.id)" },
                       chatModelCatalog.map { "\($0.provider.vendor.rawValue)/\($0.id)" })
    }

    func testARealtimeModelNamesItsUploadTwin() throws {
        let scribe = try XCTUnwrap(export.speech.first { $0.id == elevenLabsRealtimeModel })
        XCTAssertEqual(scribe.vendor, "elevenLabs")
        XCTAssertEqual(scribe.delivery, "realtime")
        XCTAssertEqual(scribe.uploadModel, "scribe_v2")
        let openAI = try XCTUnwrap(export.speech.first { $0.id == openAIRealtimeSTTModel })
        XCTAssertEqual(openAI.uploadModel, "gpt-transcribe")
        XCTAssertTrue(export.speech.filter { $0.delivery != "realtime" }.allSatisfy { $0.uploadModel == nil })
    }

    func testPricesAreWrittenInTheVendorsOwnUnits() throws {
        let gptOSS = try XCTUnwrap(export.chat.first { $0.id == "openai/gpt-oss-120b" })
        XCTAssertEqual(gptOSS.vendor, "groq")
        XCTAssertEqual(gptOSS.price, CatalogueExport.ChatPrice(kind: "listed", inputPerMillion: 0.15,
                                                                cachedInputPerMillion: 0.075, outputPerMillion: 0.60))
        let scribe = try XCTUnwrap(export.speech.first { $0.id == "scribe_v2" })
        XCTAssertEqual(scribe.price.kind, "listed")
        XCTAssertEqual(try XCTUnwrap(scribe.price.perMinute) * 60, 0.22, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(scribe.price.keytermSurchargePerMinute) * 60, 0.05, accuracy: 1e-6)
        XCTAssertEqual(export.chat.first { $0.id == "minimaxai/minimax-m2.7" }?.price.kind, "notPriced")
        XCTAssertEqual(export.speech.first { $0.vendor == "local" }?.price.kind, "free")
    }

    func testALocalModelSaysWhereItIsDownloadedFrom() throws {
        let parakeet = try XCTUnwrap(export.speech.first { $0.id == parakeetV3ModelID })
        XCTAssertEqual(parakeet.engine, "parakeet")
        XCTAssertEqual(parakeet.source, CatalogueExport.Source(huggingFace: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
                                                               path: nil, requiredFiles: parakeetRequiredBundles))
        for whisper in export.speech where whisper.engine == "whisperKit" {
            XCTAssertEqual(whisper.source, CatalogueExport.Source(huggingFace: "argmaxinc/whisperkit-coreml",
                                                                  path: whisper.id, requiredFiles: []))
        }
        for (id, repository) in [(parakeetUltraModelID, "FluidInference/parakeet-ultra-coreml"),
                                 ("parakeet-redux", "FluidInference/parakeet-redux-coreml"),
                                 ("phonon-2", "FluidInference/phonon-2-coreml")] {
            XCTAssertEqual(export.speech.first { $0.id == id }?.source?.huggingFace, repository, id)
        }
        // Every local model has a source, or the script cannot check it.
        XCTAssertTrue(export.speech.filter { $0.vendor == "local" }.allSatisfy { $0.source != nil })
    }

    func testUntilLifecycleStatesLandEveryModelIsCurrent() {
        XCTAssertTrue((export.speech.map(\.lifecycle) + export.chat.map(\.lifecycle)).allSatisfy { $0 == .current })
    }

    /// The whole shape of one entry of each kind, written out as the script reads it.
    func testTheJSONShapeIsTheOneTheScriptReads() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: export.json()) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["pricesChecked", "speech", "chat"])
        XCTAssertEqual(json["pricesChecked"] as? String, CatalogueExport.day(UsagePrices.checked))
        let speech = try XCTUnwrap(json["speech"] as? [[String: Any]])
        let realtime = try XCTUnwrap(speech.first { $0["id"] as? String == openAIRealtimeSTTModel })
        XCTAssertEqual(Set(realtime.keys), ["vendor", "id", "displayName", "delivery", "uploadModel", "price", "lifecycle"])
        XCTAssertEqual(realtime["vendor"] as? String, "openAI")
        XCTAssertEqual(Set(try XCTUnwrap(realtime["price"] as? [String: Any]).keys),
                       ["kind", "perMinute", "keytermSurchargePerMinute"])
        XCTAssertEqual(try XCTUnwrap(realtime["lifecycle"] as? [String: Any])["state"] as? String, "current")
        let local = try XCTUnwrap(speech.first { $0["id"] as? String == parakeetV3ModelID })
        XCTAssertEqual(Set(local.keys), ["vendor", "id", "displayName", "delivery", "engine", "source", "price", "lifecycle"])
        XCTAssertEqual(Set(try XCTUnwrap(local["source"] as? [String: Any]).keys), ["huggingFace", "requiredFiles"])
        let chat = try XCTUnwrap(json["chat"] as? [[String: Any]])
        let sonnet = try XCTUnwrap(chat.first { $0["id"] as? String == "claude-sonnet-5" })
        XCTAssertEqual(Set(sonnet.keys), ["vendor", "id", "displayName", "price", "lifecycle"])
        XCTAssertEqual(sonnet["vendor"] as? String, "anthropic")
        XCTAssertEqual(Set(try XCTUnwrap(sonnet["price"] as? [String: Any]).keys),
                       ["kind", "inputPerMillion", "cachedInputPerMillion", "outputPerMillion"])
    }
}
