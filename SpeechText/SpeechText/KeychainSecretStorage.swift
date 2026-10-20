// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Security
import SpeechTextCore

/// The API keys' home in the data-protection keychain — the iOS-style one, where an item
/// belongs to an access group that only code signed with this team's provisioning profile
/// can name. Another app running as the same user cannot read it, with or without the
/// user's click, which is the point: a plist in `~/Library/Preferences` is read silently by
/// anything the user runs.
///
/// App target only, so the test bundle can never reach a real keychain; `APIKeyStore`
/// takes it as a `SecretStorage`.
final class KeychainSecretStorage: SecretStorage {
    /// One generic-password item per key, the key's `SettingsKeys` name as its account.
    /// No access group is named: an item goes to the first group of the signature's
    /// `keychain-access-groups`, which `scripts/keychain-profile.sh` fixes at
    /// `TEAMID.app.speech-text.SpeechText` whatever the bundle identifier becomes.
    private static let service = "app.speech-text.SpeechText.api-keys"

    /// The storage, when this build can use it: only a build signed with the profile
    /// carries the `keychain-access-groups` entitlement (see `scripts/rebuild.sh` and
    /// `scripts/package-release.sh`). Without it every call fails with
    /// `errSecMissingEntitlement`, so the store falls back to UserDefaults. Decided from
    /// the signature rather than from a failed call, so a transient keychain error can
    /// never send a release build's keys back into a plist.
    static func availableForThisBuild() -> KeychainSecretStorage? {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil)
                as? [String], !groups.isEmpty else { return nil }
        return KeychainSecretStorage()
    }

    /// `kSecUseDataProtectionKeychain` is on every call: a query without it goes to the
    /// file-based login keychain, which may prompt and is not where the keys are.
    private func query(_ account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
        ]
    }

    func read(_ account: String) throws -> String? {
        var q = query(account)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    func write(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData: data] as CFDictionary)
        switch update {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = query(account)
            item[kSecValueData] = data
            // Readable once the Mac has been unlocked since boot — a login item starts
            // before anyone dictates — and never carried off this Mac by a backup or a
            // migration: a key is re-entered on a new Mac rather than copied to one.
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let add = SecItemAdd(item as CFDictionary, nil)
            guard add == errSecSuccess else { throw KeychainError(status: add) }
        default:
            throw KeychainError(status: update)
        }
    }

    func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}

struct KeychainError: Error, CustomStringConvertible {
    let status: OSStatus
    var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "\(message) (\(status))"
    }
}

/// Opens `APIKeyStore.shared` at launch: the keychain when this build is signed for it,
/// UserDefaults otherwise, and the pre-rename domains either way. Runs after
/// `adoptPreRenameDefaults()` and before anything reads a key — `decideSetupGate`
/// counts a stored key as a sign of an earlier install.
func openAPIKeyStore() {
    let legacy = preRenameDefaultsDomains.compactMap { UserDefaults(suiteName: $0) }
    let report = APIKeyStore.shared.open(keychain: KeychainSecretStorage.availableForThisBuild(),
                                         defaults: .standard, legacy: legacy)
    var line = "API keys in the \(report.mode == .keychain ? "keychain" : "preferences (no keychain entitlement in this build)")"
    if !report.moved.isEmpty { line += "; moved in: \(report.moved.joined(separator: ", "))" }
    if !report.adopted.isEmpty { line += "; carried over: \(report.adopted.joined(separator: ", "))" }
    if !report.failed.isEmpty { line += "; kept where they were after an error: \(report.failed.joined(separator: ", "))" }
    dlog("Keys", line)
    #if DEBUG
    if let file = E2EMode.keysFile {
        let keys = (try? String(contentsOf: file, encoding: .utf8)).map(E2EMode.parseKeys) ?? [:]
        APIKeyStore.shared.useForThisSession(keys)
        dlog("Keys", "end-to-end run: \(keys.count) key(s) from \(file.lastPathComponent), this session only")
    }
    #endif
}
