import Foundation
import os

private let logger = Logger(subsystem: "com.bbdaniels.topaz.loupe", category: "SecretsVault")

/// In-memory secrets cache backed by one Keychain item (service
/// com.claudehud.vault, account secrets) holding every secret as a JSON blob.
///
/// `unlock()` reads it once at launch; after that every read is an in-memory
/// lookup. Writes update the cache and then the item, in order, on a queue of
/// their own, so the main thread never waits on the keychain. The item is read
/// and written through /usr/bin/security (SecurityTool), whose Apple signature
/// does not change with Loupe's builds, so one "Always Allow" holds across
/// rebuilds (Ben, 2026-11-08).
final class SecretsVault: @unchecked Sendable {
    static let shared = SecretsVault()

    struct Secrets: Codable {
        var anthropicKey: String?
        var claudeAiCookie: String?
        var substackCookie: String?
    }

    private let lock = NSLock()
    private var cached: Secrets?

    /// Kept when the app became Loupe (2026-11-08): the item is read through
    /// /usr/bin/security by this literal name, never by the bundle id, so the
    /// rename leaves it, and its access, where they were.
    private static let service = "com.claudehud.vault"
    private static let account = "secrets"
    private static let migrationKey = "com.claudehud.vault.migrated.v1"
    /// Keychain calls, in order, off the main thread.
    private let io = DispatchQueue(label: "com.bbdaniels.topaz.loupe.vault.io")
    /// Long enough for Ben to answer a keychain dialog; past it the vault
    /// stops waiting and stays locked (the dialog is left alone).
    private static let readTimeout: TimeInterval = 300
    private static let writeTimeout: TimeInterval = 60

    private init() {}

    /// True after `unlock()` has completed.
    var isUnlocked: Bool {
        lock.withLock { cached != nil }
    }

    /// Read a cached secret. Returns nil if the vault has not been unlocked
    /// or the value is unset.
    func read(_ keyPath: KeyPath<Secrets, String?>) -> String? {
        lock.withLock { cached?[keyPath: keyPath] }
    }

    /// Update a secret and persist to Keychain. Refused while the vault is
    /// locked: the Keychain item holds every secret in one blob, so a write
    /// built from an empty cache would erase the others.
    func write(_ keyPath: WritableKeyPath<Secrets, String?>, _ value: String?) {
        let snapshot: Secrets? = lock.withLock {
            guard var s = cached else { return nil }
            s[keyPath: keyPath] = value
            cached = s
            return s
        }
        guard let snapshot else {
            logger.error("Write refused: vault is locked")
            return
        }
        io.async { self.persist(snapshot) }
    }

    /// Unlock the vault by reading its item, off the main thread. On first
    /// run, migrates legacy per-service items into the new vault.
    func unlock() async {
        if isUnlocked { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            io.async {
                self.unlockNow()
                done.resume()
            }
        }
    }

    private func unlockNow() {
        if isUnlocked { return }
        let migrated = UserDefaults.standard.bool(forKey: Self.migrationKey)
        if !migrated {
            NSLog("[SecretsVault] Running one-time migration from legacy keychain items")
            let (legacy, readFailed) = Self.loadLegacySecrets()
            lock.withLock { cached = legacy }
            let persisted = persist(legacy)
            if persisted && !readFailed {
                Self.deleteLegacyItems()
                UserDefaults.standard.set(true, forKey: Self.migrationKey)
                NSLog("[SecretsVault] Migration complete — legacy items deleted")
            } else {
                NSLog("[SecretsVault] Migration incomplete (persisted=\(persisted), readFailed=\(readFailed)) — legacy items kept")
            }
            return
        }
        switch Self.loadFromKeychain() {
        case .found(let loaded):
            lock.withLock { cached = loaded }
        case .notFound:
            lock.withLock { cached = Secrets() }
        case .failed:
            // A refused or unanswered dialog, a keychain error or an
            // undecodable blob: stay locked so no write can replace the
            // stored secrets.
            logger.error("Vault stays locked: Keychain load failed")
        }
    }

    // MARK: - Keychain I/O

    /// Persist the full secrets blob. Returns true once the item holds it.
    @discardableResult
    private func persist(_ secrets: Secrets) -> Bool {
        guard let data = try? JSONEncoder().encode(secrets) else {
            NSLog("[SecretsVault] Failed to encode secrets")
            return false
        }
        let result = SecurityTool.save(service: Self.service, account: Self.account,
                                       secret: data, timeout: Self.writeTimeout)
        guard result == .saved else {
            NSLog("[SecretsVault] Vault item not saved: \(result)")
            return false
        }
        NSLog("[SecretsVault] Vault item saved successfully")
        return true
    }

    private enum LoadResult {
        case found(Secrets)
        case notFound
        case failed
    }

    private static func loadFromKeychain() -> LoadResult {
        switch SecurityTool.read(service: service, account: account, timeout: readTimeout) {
        case .notFound:
            return .notFound
        case .found(let data):
            guard let secrets = try? JSONDecoder().decode(Secrets.self, from: data) else {
                NSLog("[SecretsVault] Vault blob did not decode")
                return .failed
            }
            return .found(secrets)
        case let other:
            NSLog("[SecretsVault] Vault load failed: \(other)")
            return .failed
        }
    }

    // MARK: - Legacy Migration

    private static let legacyItems: [(service: String, account: String)] = [
        ("com.claudehud.api-key", "anthropic"),
        ("com.claudehud.claudeai", "sessionKey"),
        ("com.claudehud.substack", "substack.sid"),
    ]

    /// Reads legacy items. Returns secrets plus `readFailed` flag indicating
    /// whether any existing item could not be read (user canceled prompt, etc.).
    /// A missing item is not a failure.
    private static func loadLegacySecrets() -> (secrets: Secrets, readFailed: Bool) {
        var readFailed = false

        func readLegacy(service: String, account: String) -> String? {
            switch SecurityTool.read(service: service, account: account, timeout: readTimeout) {
            case .notFound:
                return nil
            case .found(let data):
                return String(data: data, encoding: .utf8)
            case let other:
                // Refused, unanswered or another error: do not proceed with deletion.
                logger.warning("Legacy item \(service)/\(account) unreadable: \(String(describing: other))")
                readFailed = true
                return nil
            }
        }
        let secrets = Secrets(
            anthropicKey: readLegacy(service: legacyItems[0].service, account: legacyItems[0].account),
            claudeAiCookie: readLegacy(service: legacyItems[1].service, account: legacyItems[1].account),
            substackCookie: readLegacy(service: legacyItems[2].service, account: legacyItems[2].account)
        )
        return (secrets, readFailed)
    }

    private static func deleteLegacyItems() {
        for item in legacyItems {
            SecurityTool.delete(service: item.service, account: item.account, timeout: writeTimeout)
        }
    }
}
