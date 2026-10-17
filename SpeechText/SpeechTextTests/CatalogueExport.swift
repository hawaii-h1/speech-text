// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// The catalogues as JSON, for `scripts/check-vendor-models.sh` (#20), which compares them
// with what each vendor serves. Written by `SpeechTextEvaluation --export-catalogue`, so
// the script reads the catalogues the app is built from and keeps no list of its own.
// Pure logic, shared by that tool and `CatalogueExportTests`, which pin the shape: the
// script depends on it.

struct CatalogueExport: Encodable, Equatable {
    /// `UsagePrices.checked`, as `yyyy-MM-dd`: the prices below are the vendors' as of then.
    let pricesChecked: String
    let speech: [SpeechModel]
    let chat: [ChatModel]

    struct SpeechModel: Encodable, Equatable {
        /// `Provider`'s raw value — the one History stores.
        let vendor: String
        let id: String
        let displayName: String
        /// `upload`, `realtime`, `onDevice` or `systemRecognizer`.
        let delivery: String
        /// A realtime model's upload twin, which must exist at the vendor as well.
        let uploadModel: String?
        /// `whisperKit` or `parakeet`, for a model on the Mac.
        let engine: String?
        /// Where a model on the Mac is downloaded from.
        let source: Source?
        let price: SpeechPrice
        let lifecycle: Lifecycle
    }

    struct ChatModel: Encodable, Equatable {
        let vendor: String
        let id: String
        let displayName: String
        let price: ChatPrice
        let lifecycle: Lifecycle
    }

    /// A Hugging Face model repository, the folder inside it (nil for the whole
    /// repository) and the files that folder must hold for the model to install.
    struct Source: Encodable, Equatable {
        let huggingFace: String
        let path: String?
        let requiredFiles: [String]
    }

    struct SpeechPrice: Encodable, Equatable {
        /// `free`, `listed` or `notPriced`.
        let kind: String
        let perMinute: Double?
        let keytermSurchargePerMinute: Double?
    }

    struct ChatPrice: Encodable, Equatable {
        let kind: String
        let inputPerMillion: Double?
        let cachedInputPerMillion: Double?
        let outputPerMillion: Double?
    }

    /// Where a model stands with its vendor: `current`, `superseded`, `deprecated` or
    /// `retired`, and the vendor's shutdown date (`yyyy-MM-dd`) once one is announced.
    struct Lifecycle: Encodable, Equatable {
        let state: String
        let shutdownDate: String?

        static let current = Lifecycle(state: "current", shutdownDate: nil)
    }
}

extension CatalogueExport {
    /// The catalogues as they are compiled into this build.
    static func current() -> CatalogueExport {
        CatalogueExport(
            pricesChecked: day(UsagePrices.checked),
            speech: sttModelCatalog.map(speechModel),
            chat: chatModelCatalog.map(chatModel)
        )
    }

    func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// The model-lifecycle work (current / superseded / deprecated / retired, with the
    /// vendor's shutdown date) is being added to the catalogues in parallel. Until it
    /// lands every model is current; whichever change merges second points these two at
    /// the descriptors' own fields.
    static func lifecycle(of model: STTModelDescriptor) -> Lifecycle { .current }
    static func lifecycle(of model: ChatModelDescriptor) -> Lifecycle { .current }

    static func speechModel(_ model: STTModelDescriptor) -> SpeechModel {
        var delivery = ""
        var engine: LocalSTTEngine?
        switch model.delivery {
        case .upload: delivery = "upload"
        case .realtime: delivery = "realtime"
        case .onDevice(let local): delivery = "onDevice"; engine = local
        case .systemRecognizer: delivery = "systemRecognizer"
        }
        var uploadModel: String?
        if case .model(let id) = model.batchUpload { uploadModel = id }
        let price: SpeechPrice = switch model.price {
        case .free: SpeechPrice(kind: "free", perMinute: nil, keytermSurchargePerMinute: nil)
        case .notPriced: SpeechPrice(kind: "notPriced", perMinute: nil, keytermSurchargePerMinute: nil)
        case .listed(let rates):
            SpeechPrice(kind: "listed", perMinute: rounded(rates.perMinute),
                        keytermSurchargePerMinute: rounded(rates.keytermSurchargePerMinute))
        }
        return SpeechModel(vendor: model.vendor.rawValue, id: model.id, displayName: model.displayName,
                           delivery: delivery, uploadModel: uploadModel, engine: engine?.rawValue,
                           source: engine.flatMap { source(of: model.id, engine: $0) },
                           price: price, lifecycle: lifecycle(of: model))
    }

    static func chatModel(_ model: ChatModelDescriptor) -> ChatModel {
        let price: ChatPrice = switch model.price {
        case .free: ChatPrice(kind: "free", inputPerMillion: nil, cachedInputPerMillion: nil, outputPerMillion: nil)
        case .notPriced: ChatPrice(kind: "notPriced", inputPerMillion: nil, cachedInputPerMillion: nil, outputPerMillion: nil)
        case .listed(let rates):
            ChatPrice(kind: "listed", inputPerMillion: rounded(rates.inputPerToken * 1e6),
                      cachedInputPerMillion: rounded(rates.cachedInputPerToken * 1e6),
                      outputPerMillion: rounded(rates.outputPerToken * 1e6))
        }
        return ChatModel(vendor: model.provider.vendor.rawValue, id: model.id, displayName: model.displayName,
                         price: price, lifecycle: lifecycle(of: model))
    }

    /// Where each local engine's models come from: WhisperKit's are folders of
    /// `argmaxinc/whisperkit-coreml` named by the catalogue ID (`LocalWhisperRuntime.swift`),
    /// Parakeet v3 is FluidAudio's `FluidInference/parakeet-tdt-0.6b-v3-coreml`
    /// (`LocalParakeetRuntime.swift`). A Parakeet model added without a repository here
    /// exports none, and the script says so rather than checking the wrong one.
    static func source(of id: String, engine: LocalSTTEngine) -> Source? {
        switch engine {
        case .whisperKit:
            Source(huggingFace: "argmaxinc/whisperkit-coreml", path: id, requiredFiles: [])
        case .parakeet:
            id == parakeetV3ModelID
                ? Source(huggingFace: "FluidInference/parakeet-tdt-0.6b-v3-coreml", path: nil,
                         requiredFiles: parakeetRequiredBundles)
                : nil
        }
    }

    /// Prices are stored per token or per minute; written back per million or per minute
    /// they would carry binary noise (0.15000000000000002) into the comparison.
    static func rounded(_ value: Double) -> Double {
        (value * 1e9).rounded() / 1e9
    }

    static func day(_ components: DateComponents) -> String {
        String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
