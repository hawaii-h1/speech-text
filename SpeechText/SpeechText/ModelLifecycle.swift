// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where a catalogue model is in its vendor's life (#19).
///
/// A model is never simply deleted from a catalogue any more: deleting it moved whoever
/// had it to the provider's default without a word, and turned every History record made
/// with it "Not priced", since records are priced from the current table. Instead a model
/// is marked, its users are moved to its *own* replacement with our release, and it stays
/// listed — for History's prices and names — until `ModelRetirement.term` after the
/// vendor switched it off, when its ID, name and price move to the archive.
///
/// "Needs a newer macOS" is not a lifecycle state: that is a property of this Mac, not of
/// the vendor, and is a separate input to the same *offered* filter.
enum ModelLifecycle: Hashable {
    /// Offered, nothing better to suggest.
    case current
    /// Still works and is still offered, but this model (same vendor) is better — or is
    /// the default now. Whoever has it is offered the switch; nothing moves by itself.
    case superseded(by: String)
    /// The vendor is switching it off. It is no longer offered, and the first launch of
    /// the release that marks it moves every stored choice to `replacement`.
    case deprecated(Deprecation)

    /// Whether a picker, setup or a recommendation may offer the model.
    var isOffered: Bool {
        if case .deprecated = self { false } else { true }
    }

    var deprecation: Deprecation? {
        if case .deprecated(let deprecation) = self { deprecation } else { nil }
    }

    /// The model this one points to, whatever the reason.
    var successor: String? {
        switch self {
        case .current: nil
        case .superseded(let id): id
        case .deprecated(let deprecation): deprecation.replacement
        }
    }

    /// What a picker row says about the model on `day`, or nil for one that needs no note.
    func status(on day: Date) -> String? {
        guard let deprecation else { return nil }
        // An archived model's dates are not kept: it is past them by definition.
        guard let shutdown = deprecation.shutdown.date else { return "Retired" }
        return day < shutdown ? "Retiring on \(ModelRetirement.dayText(shutdown))" : "Retired"
    }
}

/// A vendor's announcement that a model will be switched off.
struct Deprecation: Hashable {
    /// The day the vendor announced it.
    let announced: DateComponents
    /// The day the vendor stops answering — the vendor's own word for it is OpenAI's
    /// "shutdown date". Shown, never a trigger: users move with our release.
    let shutdown: DateComponents
    /// The same vendor's model its users are moved to. A chain (A → B → C) is followed.
    let replacement: String
    /// The vendor's page that says so.
    let source: URL
}

extension Deprecation {
    /// How an archived model reads when it is looked up: switched off, dates not kept.
    static func archived(replacement: String?) -> Deprecation {
        Deprecation(announced: DateComponents(), shutdown: DateComponents(),
                    replacement: replacement ?? "", source: URL(string: "about:blank")!)
    }
}

/// A model past its retirement term, kept as one line so History can still name and
/// price records made with it. Never deleted. `replacement` lets an install that skipped
/// releases still follow the chain to a model that is offered.
struct ArchivedModel<Rates: Hashable>: Hashable {
    let vendor: Provider
    let id: String
    let displayName: String
    let price: ListPrice<Rates>
    let replacement: String?
}

enum ModelRetirement {
    /// How long a deprecated model's full catalogue entry outlives the vendor's shutdown
    /// date before it moves to the archive. `ModelLifecycleTests` fails once an entry is
    /// past it, so the move is not forgotten.
    static let termMonths = 6

    /// The day an entry deprecated with this shutdown date must leave the catalogue.
    static func archiveBy(_ deprecation: Deprecation) -> Date? {
        deprecation.shutdown.date.flatMap {
            calendar.date(byAdding: .month, value: termMonths, to: $0)
        }
    }

    static let calendar = Calendar(identifier: .gregorian)

    static func day(_ year: Int, _ month: Int, _ day: Int) -> DateComponents {
        DateComponents(calendar: calendar, timeZone: TimeZone(identifier: "UTC"), year: year, month: month, day: day)
    }

    /// "26 Feb 2027".
    static func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.calendar = calendar
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }
}

/// Speech models past their term: ID, name, price and replacement only.
let archivedSpeechModels: [ArchivedModel<SpeechRates>] = []

/// Chat models past their term.
let archivedChatModels: [ArchivedModel<ChatRates>] = []

// MARK: - Following a replacement

/// One model as the chain sees it: whether it is offered and where it points.
struct LifecycleLink: Equatable {
    let offered: Bool
    let successor: String?
}

/// The offered model a chain of replacements starting at `id` ends on, or nil when it
/// ends nowhere (an ID nobody lists, an archived model with no replacement, a cycle).
/// Only `deprecated` and archived links are followed: a superseded model is still offered
/// and is the user's to keep.
func resolvedReplacement(of id: String, link: (String) -> LifecycleLink?) -> String? {
    var current = id
    var seen: Set<String> = []
    while seen.insert(current).inserted {
        guard let node = link(current) else { return nil }
        if node.offered { return current }
        guard let next = node.successor else { return nil }
        current = next
    }
    return nil
}

/// A speech model's link: the catalogue first, then the archive.
func speechLifecycleLink(vendor: Provider, id: String) -> LifecycleLink? {
    if let model = knownSTTModels(of: vendor).first(where: { $0.id == id }) {
        return LifecycleLink(offered: model.lifecycle.isOffered,
                             successor: model.lifecycle.deprecation?.replacement)
    }
    if let archived = archivedSpeechModels.first(where: { $0.vendor == vendor && $0.id == id }) {
        return LifecycleLink(offered: false, successor: archived.replacement)
    }
    return nil
}

/// A chat model's link: the catalogue first, then the archive.
func chatLifecycleLink(provider: LLMProviderType, id: String) -> LifecycleLink? {
    if let model = knownChatModels(of: provider).first(where: { $0.id == id }) {
        return LifecycleLink(offered: model.lifecycle.isOffered,
                             successor: model.lifecycle.deprecation?.replacement)
    }
    if let archived = archivedChatModels.first(where: { $0.vendor == provider.vendor && $0.id == id }) {
        return LifecycleLink(offered: false, successor: archived.replacement)
    }
    return nil
}

// MARK: - Moving stored choices

/// One stored model choice the launch changed, kept so the first dictation after the
/// update can say so (`SettingsKeys.modelMigrations`). Machine-local.
struct ModelMigration: Codable, Equatable {
    enum Reason: String, Codable {
        /// The vendor is switching the model off; `to` is its replacement.
        case deprecated
        /// The stored ID leads to no model that is offered; the choice was cleared and the
        /// user picks.
        case unavailable
    }

    /// The `SettingsKeys` name of the model setting.
    let settingsKey: String
    let from: String
    /// The model now stored, or nil when the choice was cleared.
    let to: String?
    let reason: Reason
    let date: Date
}

/// What one stored model setting comes to.
enum StoredModelVerdict: Equatable {
    case keep
    case move(to: String)
    case clear
}

/// The rule, apart from any store: an offered model stays (superseded included); anything
/// else follows its replacements to an offered model, and is cleared when they lead
/// nowhere — never moved to the provider's default, which may be another kind of model.
func storedModelVerdict(_ id: String, link: (String) -> LifecycleLink?) -> StoredModelVerdict {
    if link(id)?.offered == true { return .keep }
    if let target = resolvedReplacement(of: id, link: link) { return .move(to: target) }
    return .clear
}

/// Applies `storedModelVerdict` to every normalised model setting in `defaults` and
/// appends what changed to `SettingsKeys.modelMigrations`. Takes the store, so the tests
/// run it against an isolated suite.
@discardableResult
func migrateStoredModels(in defaults: UserDefaults, now: Date = Date()) -> [ModelMigration] {
    var settings: [(key: String, link: (String) -> LifecycleLink?)] = []
    for engine in STTProviderType.allCases {
        guard let setting = engine.vendor.descriptor.speechModel, setting.normalized,
              let key = setting.settingsKey else { continue }
        settings.append((key, { speechLifecycleLink(vendor: engine.vendor, id: $0) }))
    }
    for type in LLMProviderType.allCases {
        guard let setting = type.vendor.descriptor.chatModel, setting.normalized,
              let key = setting.settingsKey else { continue }
        settings.append((key, { chatLifecycleLink(provider: type, id: $0) }))
    }

    var moved: [ModelMigration] = []
    for (key, link) in settings {
        guard let raw = defaults.string(forKey: key) else { continue }
        switch storedModelVerdict(raw, link: link) {
        case .keep:
            continue
        case .move(let target):
            dlog("Settings", "\(key)=\"\(raw)\" is being retired by its vendor — moved to \(target)")
            defaults.set(target, forKey: key)
            moved.append(ModelMigration(settingsKey: key, from: raw, to: target, reason: .deprecated, date: now))
        case .clear:
            dlog("Settings", "\(key)=\"\(raw)\" leads to no model on offer — cleared")
            defaults.removeObject(forKey: key)
            moved.append(ModelMigration(settingsKey: key, from: raw, to: nil, reason: .unavailable, date: now))
        }
    }
    if !moved.isEmpty {
        let earlier = storedModelMigrations(in: defaults)
        // The newest 20 are plenty: each is told once, at the next dictation.
        let all = Array((earlier + moved).suffix(20))
        defaults.set(try? JSONEncoder().encode(all), forKey: SettingsKeys.modelMigrations)
    }
    return moved
}

/// The moves recorded so far, oldest first.
func storedModelMigrations(in defaults: UserDefaults) -> [ModelMigration] {
    guard let data = defaults.data(forKey: SettingsKeys.modelMigrations) else { return [] }
    return (try? JSONDecoder().decode([ModelMigration].self, from: data)) ?? []
}

// MARK: - Pinning a default nobody chose

/// Writes down the model an untouched install is running, so a later change of our
/// default does not move it: only new installs get a new default, and everyone else is
/// *offered* it (`ModelLifecycle.superseded`).
///
/// Only the speech engine and AI provider in use are pinned. Writing every provider's
/// default would hand a Groq user `localSTTModel = <today's default>`, and once that
/// default moved, switching to the local tier would point at a model they never
/// downloaded. The local tier is not pinned here at all: `preserveInstalledLocalModel`
/// pins it to a model on disk, whichever engine is in use, and with none installed there
/// is nothing to keep.
func pinUntouchedModelChoices(in defaults: UserDefaults, except skipped: Set<String> = []) {
    let engine = defaults.string(forKey: SettingsKeys.sttProvider).flatMap(STTProviderType.init(rawValue:)) ?? .apple
    if engine != .local, let setting = engine.vendor.descriptor.speechModel, setting.normalized,
       let key = setting.settingsKey, !skipped.contains(key), defaults.string(forKey: key) == nil {
        dlog("Settings", "\(key) was never set — pinning \(setting.defaultID)")
        defaults.set(setting.defaultID, forKey: key)
    }
    let ai = defaults.string(forKey: SettingsKeys.llmProvider).flatMap(LLMProviderType.init(rawValue:)) ?? .groq
    if let setting = ai.vendor.descriptor.chatModel, setting.normalized,
       let key = setting.settingsKey, !skipped.contains(key), defaults.string(forKey: key) == nil {
        dlog("Settings", "\(key) was never set — pinning \(setting.defaultID)")
        defaults.set(setting.defaultID, forKey: key)
    }
}
