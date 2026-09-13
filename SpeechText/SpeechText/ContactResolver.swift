// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Contacts
import Foundation

/// Turns the name the user said out loud into concrete addresses.
///
/// The LLM is never asked for an address — it only passes the recipient through as
/// spoken. Everything here is deterministic lookup against the user's own address book,
/// so a wrong number is a wrong *match* the user can see and correct in the confirmation
/// panel, not a plausible-looking invention.
enum ContactResolver {

    enum ResolveError: LocalizedError {
        case accessDenied
        case noMatch(String)
        case noAddressForChannel(String, DeliveryChannel)

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "SpeechText can't read Contacts. Allow it in System Settings › Privacy & Security › Contacts."
            case .noMatch(let name):
                return "No contact matching “\(name)”."
            case .noAddressForChannel(let name, let channel):
                switch channel {
                case .telegram:
                    return "\(name) has no Telegram username or phone number on their card."
                case .whatsapp:
                    return "\(name) has no phone number on their card."
                case .mail:
                    return "\(name) has no email address on their card."
                case .imessage:
                    return "\(name) has no phone number or email on their card."
                }
            }
        }
    }

    // MARK: - Entry point

    /// Every way of reaching `spoken` on `channel`, best match first. Throws rather than
    /// returning an empty list so the caller can tell the user *why* nothing came back.
    static func resolve(spoken: String, channel: DeliveryChannel) async throws -> [RecipientCandidate] {
        let name = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ResolveError.noMatch(spoken) }

        // Dictated an address outright — nothing to look up.
        if let literal = literalCandidate(name, channel: channel) { return [literal] }

        guard try await ensureAccess() else { throw ResolveError.accessDenied }

        let matches = try await matchingContacts(name)
        guard !matches.isEmpty else { throw ResolveError.noMatch(name) }

        let resolved = matches.flatMap { candidates(from: $0, channel: channel) }
        guard !resolved.isEmpty else {
            throw ResolveError.noAddressForChannel(displayName(for: matches[0]), channel)
        }
        return resolved
    }

    /// A phone number, email or @handle the user spoke directly, if that's what this is.
    private static func literalCandidate(_ value: String, channel: DeliveryChannel) -> RecipientCandidate? {
        guard AddressFormat.isLiteralAddress(value) else { return nil }

        let usable: Bool
        switch channel.addressKind {
        case .phoneOrEmail: usable = AddressFormat.isEmail(value) || AddressFormat.phoneDigits(value) != nil
        case .email:        usable = AddressFormat.isEmail(value)
        case .handleOrPhone: usable = AddressFormat.telegramHandle(value) != nil || AddressFormat.phoneDigits(value) != nil
        case .phone:        usable = AddressFormat.phoneDigits(value) != nil
        }
        guard usable else { return nil }

        return RecipientCandidate(displayName: value, address: value,
                                  addressLabel: nil, source: .literal)
    }

    // MARK: - Permission

    static var isAuthorized: Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .denied, .restricted, .notDetermined: return false
        default: return true // .authorized, and .limited on newer systems
        }
    }

    @discardableResult
    static func ensureAccess() async throws -> Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .denied, .restricted:
            return false
        case .notDetermined:
            return (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
        default:
            return true
        }
    }

    // MARK: - Lookup

    private static let keysToFetch: [CNKeyDescriptor] = [
        CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
        CNContactOrganizationNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
        CNContactInstantMessageAddressesKey, CNContactSocialProfilesKey,
    ].map { $0 as CNKeyDescriptor }

    /// Contacts' own name predicate only matches from the start of a name component,
    /// which misses every inflected form — dictating "Оксані" or "Петренку" in Ukrainian
    /// never matches the card that says "Оксана Петренко". So a miss falls through to a
    /// fuzzy pass over the whole address book.
    private static func matchingContacts(_ name: String) async throws -> [CNContact] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let store = CNContactStore()
                do {
                    let exact = try store.unifiedContacts(
                        matching: CNContact.predicateForContacts(matchingName: name),
                        keysToFetch: keysToFetch
                    )
                    if !exact.isEmpty {
                        dlog("Contacts", "“\(name)” → \(exact.count) exact match(es)")
                        continuation.resume(returning: exact)
                        return
                    }
                    let fuzzy = try fuzzyMatches(name, store: store)
                    dlog("Contacts", "“\(name)” → \(fuzzy.count) fuzzy match(es)")
                    continuation.resume(returning: fuzzy)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func fuzzyMatches(_ name: String, store: CNContactStore) throws -> [CNContact] {
        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        var scored: [(contact: CNContact, score: Double)] = []

        try store.enumerateContacts(with: request) { contact, _ in
            let score = similarity(of: name, to: contact)
            if score >= 0.62 { scored.append((contact, score)) }
        }

        return scored
            .sorted { $0.score > $1.score }
            .prefix(5)
            .map(\.contact)
    }

    // MARK: - Fuzzy name matching

    /// Best score across the whole-name comparison and a token-by-token one, so both
    /// "Оксані" and "Оксані Петренко" find "Оксана Петренко".
    private static func similarity(of spoken: String, to contact: CNContact) -> Double {
        let components = [contact.givenName, contact.familyName, contact.nickname,
                          contact.organizationName].filter { !$0.isEmpty }
        guard !components.isEmpty else { return 0 }

        let full = [contact.givenName, contact.familyName]
            .filter { !$0.isEmpty }.joined(separator: " ")
        let variants = (components + [full]).map(normalize).filter { !$0.isEmpty }
        let target = normalize(spoken)
        guard !target.isEmpty else { return 0 }

        let whole = variants.map { score(target, $0) }.max() ?? 0

        let tokens = target.split(separator: " ").map(String.init)
        let perToken: Double
        if tokens.count > 1 {
            let best = tokens.map { token in variants.map { score(token, $0) }.max() ?? 0 }
            perToken = best.reduce(0, +) / Double(best.count)
        } else {
            perToken = 0
        }

        return max(whole, perToken)
    }

    /// Lowercased, diacritic-folded, punctuation-stripped — "Ковальов-Сидір" and
    /// "kovalov sydir" should compare on equal footing.
    private static func normalize(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                      locale: nil)
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// 1.0 for equal, a small bonus band for prefixes (covers truncated dictation), and
    /// edit distance otherwise — one or two letters of Slavic case ending cost little.
    private static func score(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        if a.count >= 3, b.hasPrefix(a) || a.hasPrefix(b) { return 0.9 }
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 0 }
        return 1 - Double(levenshtein(a, b)) / Double(longest)
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    // MARK: - Contact → addresses

    private static func displayName(for contact: CNContact) -> String {
        let full = [contact.givenName, contact.familyName]
            .filter { !$0.isEmpty }.joined(separator: " ")
        if !full.isEmpty { return full }
        if !contact.nickname.isEmpty { return contact.nickname }
        if !contact.organizationName.isEmpty { return contact.organizationName }
        return "Unnamed contact"
    }

    private static func candidates(from contact: CNContact, channel: DeliveryChannel) -> [RecipientCandidate] {
        let name = displayName(for: contact)

        func phones() -> [RecipientCandidate] {
            contact.phoneNumbers.map { entry in
                RecipientCandidate(displayName: name,
                                   address: entry.value.stringValue,
                                   addressLabel: label(entry.label),
                                   source: .contacts)
            }
        }

        func emails() -> [RecipientCandidate] {
            contact.emailAddresses.map { entry in
                RecipientCandidate(displayName: name,
                                   address: entry.value as String,
                                   addressLabel: label(entry.label),
                                   source: .contacts)
            }
        }

        switch channel {
        case .mail:
            return emails()
        case .whatsapp:
            return phones()
        case .imessage:
            // A mobile number is the likeliest iMessage handle, so it leads.
            return phones().sorted { isMobile($0.addressLabel) && !isMobile($1.addressLabel) } + emails()
        case .telegram:
            // A username resolves far more reliably than a phone, so it wins when present.
            return handles(from: contact, matching: "telegram", name: name) + phones()
        }
    }

    /// Telegram usernames live on the contact card as an instant-message address or a
    /// social profile, which is why no separate alias book is needed.
    private static func handles(from contact: CNContact, matching service: String,
                                name: String) -> [RecipientCandidate] {
        let instant = contact.instantMessageAddresses.compactMap { entry -> RecipientCandidate? in
            guard entry.value.service.localizedCaseInsensitiveContains(service) else { return nil }
            return RecipientCandidate(displayName: name, address: entry.value.username,
                                      addressLabel: entry.value.service, source: .contacts)
        }
        let social = contact.socialProfiles.compactMap { entry -> RecipientCandidate? in
            guard entry.value.service.localizedCaseInsensitiveContains(service),
                  !entry.value.username.isEmpty else { return nil }
            return RecipientCandidate(displayName: name, address: entry.value.username,
                                      addressLabel: entry.value.service, source: .contacts)
        }
        return instant + social
    }

    private static func isMobile(_ label: String?) -> Bool {
        guard let label else { return false }
        return label.localizedCaseInsensitiveContains("mobile")
            || label.localizedCaseInsensitiveContains("iphone")
    }

    private static func label(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return CNLabeledValue<NSString>.localizedString(forLabel: raw)
    }
}
