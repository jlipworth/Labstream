import Foundation
import PMSKit
import Security

/// Minimal Keychain wrapper for the two long-lived secrets the app persists:
///   - `"token"`: the Plex auth token (cleared on sign-out / 401).
///   - `"clientIdentifier"`: a UUID generated once on first launch and kept
///     forever, so the server sees a stable client identity across relaunches.
///
/// Values are stored as generic passwords keyed by `account`, scoped to this
/// app's service. `kSecAttrAccessibleAfterFirstUnlock` lets background URLSession
/// downloads read the token while the device is locked.
///
/// ## iCloud Keychain sync (shared sign-in across the user's devices)
///
/// Exactly ONE item syncs via iCloud Keychain: the Plex account token. All three app
/// variants (visionOS, iPhone, iPad) share the bundle id and this service string, so a
/// Plex sign-in on any device signs the others in on next launch. This is safe for Plex
/// specifically because the token is account-scoped while each install keeps its OWN
/// `clientIdentifier` (deliberately non-synced): every device still presents a distinct
/// `X-Plex-Client-Identifier` + `X-Plex-Device-Name`, so the server sees truly
/// independent, per-device-identifiable sessions.
///
/// Deliberately NOT synced:
///   - `clientIdentifier` — syncing it would merge all devices into one server-side
///     client identity, breaking per-device session listings and transcode bookkeeping.
///   - Jellyfin/Emby access tokens — those servers bind the token to the device id used
///     at authentication, so a synced token would make every device impersonate one
///     server-side device record instead of holding independent sessions.
///   - Backend/server selection — per-device preference, not a credential.
///
/// Note the flip side: deleting the synced token (manual sign-out or a 401 wipe) signs
/// ALL devices out, which matches how an account-level token actually dies.
/// When a synced Plex token is successfully read, any pre-sync device-local Plex token is
/// deleted so a later synced/global sign-out cannot re-promote stale local credentials.
final class KeychainStore {
    static let tokenKey = "token"
    static let clientIdentifierKey = "clientIdentifier"
    static let selectedBackendKey = "selectedBackend"
    static let selectedPlexServerIDKey = "selectedPlexServerID"
    static let jellyfinServerURLKey = "jellyfinServerURL"
    static let jellyfinAccessTokenKey = "jellyfinAccessToken"
    static let jellyfinUserIDKey = "jellyfinUserID"
    static let jellyfinServerIDKey = "jellyfinServerID"
    static let embyServerURLKey = "embyServerURL"
    static let embyAccessTokenKey = "embyAccessToken"
    static let embyUserIDKey = "embyUserID"
    static let embyServerIDKey = "embyServerID"

    /// Compile-time admission for the explicitly requested macOS development credential
    /// store. PerformanceAudit is nonshipping but otherwise Release-equivalent, so it needs
    /// the same deterministic storage as Debug without opening this path to shipping builds.
    static var supportsDevelopmentFileStorage: Bool {
        #if (DEBUG || PERFORMANCE_AUDIT) && os(macOS)
        true
        #else
        false
        #endif
    }

    /// Accounts stored as iCloud-synchronizable keychain items (see the type doc for the
    /// rationale). Everything else stays device-local.
    private static let synchronizedAccounts: Set<String> = [tokenKey]

    private let service: String
    private let synchronizesPlexToken: Bool
    private let fallbackPolicy: SecretFileFallbackPolicy
    private let fileManager: FileManager
    private let usesDevelopmentFileStorage: Bool
    /// Narrow deterministic seam for secure-write failure tests. Returning nil uses
    /// the real storage implementation; returning a Bool supplies its outcome.
    private let writeInterceptor: ((String, String) -> Bool?)?
    private let deleteInterceptor: ((String) -> Bool?)?

    init(service: String = "com.visionplay.app",
         synchronizesPlexToken: Bool = true,
         fallbackPolicy: SecretFileFallbackPolicy = .current,
         fileManager: FileManager = .default,
         usesDevelopmentFileStorage: Bool = false,
         writeInterceptor: ((String, String) -> Bool?)? = nil,
         deleteInterceptor: ((String) -> Bool?)? = nil) {
        self.service = service
        self.synchronizesPlexToken = synchronizesPlexToken
        self.fallbackPolicy = fallbackPolicy
        self.fileManager = fileManager
        // File-backed credentials are a local Mac development/performance-measurement
        // affordance only. Shipping binaries fail closed on Keychain errors even if a caller
        // accidentally requests it.
        self.usesDevelopmentFileStorage = usesDevelopmentFileStorage
            && Self.supportsDevelopmentFileStorage
        self.writeInterceptor = writeInterceptor
        self.deleteInterceptor = deleteInterceptor
    }

    /// Whether `account` is stored as an iCloud-synchronizable item.
    private func isSynchronized(_ account: String) -> Bool {
        synchronizesPlexToken && Self.synchronizedAccounts.contains(account)
    }

    /// Base match query for `account`. A keychain query matches ONLY device-local items
    /// unless `kSecAttrSynchronizable` says otherwise, so synced accounts must carry the
    /// attribute explicitly (and legacy-local lookups omit it).
    private func baseQuery(for account: String, synchronizable: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if synchronizable {
            query[kSecAttrSynchronizable as String] = true
        }
        return query
    }

    /// Insert or update the value for `account`.
    @discardableResult
    func save(_ value: String, for account: String) -> Bool {
        if let outcome = writeInterceptor?(account, value) { return outcome }
        guard let data = value.data(using: .utf8) else { return false }

        if usesDevelopmentFileStorage {
            return saveDevelopmentFileStorage(data, for: account)
        }

        let synced = isSynchronized(account)
        let query = baseQuery(for: account, synchronizable: synced)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = saveToKeychain(data, query: query, attributes: attributes)
        if status == errSecSuccess {
            if synced {
                // Retire any pre-sync local copy so it can't shadow the synced item.
                SecItemDelete(baseQuery(for: account, synchronizable: false) as CFDictionary)
            }
            // Drop any stale fallback so it can't shadow the real value later.
            cleanupFallback(for: account)
            return true
        }

        guard fallbackPolicy.allowsSecretFileFallback else {
            NSLog("%@", "KeychainStore: SecItem save failed for \(account) (OSStatus \(status)); refusing file fallback")
            return false
        }

        NSLog("%@", "KeychainStore: SecItem save failed for \(account) (OSStatus \(status)); using DEBUG simulator file fallback")
        return saveFallback(data, for: account)
    }

    /// Read the value for `account`, or `nil` if absent.
    func read(_ account: String) -> String? {
        if usesDevelopmentFileStorage {
            return readDevelopmentFileStorage(account)
        }

        let synced = isSynchronized(account)
        let primary = readItem(account, synchronizable: synced)
        if let value = primary.value {
            if KeychainSynchronizedCredentialMigrationPolicy.actions(
                isSynchronized: synced,
                primaryValueFound: true,
                legacyLocalValueFound: false).shouldDeleteLegacyLocal {
                // Once this install has observed the synced credential, any pre-sync local
                // copy is stale. Retire it immediately so a later iCloud/global delete can't
                // make `read` fall back to and re-promote the old device-local token.
                deleteLegacyLocalItem(for: account)
            }
            cleanupFallback(for: account)
            return value
        }

        if synced {
            let legacy = readItem(account, synchronizable: false)
            let migration = KeychainSynchronizedCredentialMigrationPolicy.actions(
                isSynchronized: synced,
                primaryValueFound: false,
                legacyLocalValueFound: legacy.value != nil)
            if migration.shouldPromoteLegacyLocal, let legacyValue = legacy.value {
                // Pre-sync install: promote the device-local item to the synchronizable one.
                // The keychain can't flip the attribute in place, so `save` re-adds the item
                // as synced and retires the local copy; the value is good either way.
                _ = save(legacyValue, for: account)
                return legacyValue
            }
        }

        if primary.status != errSecItemNotFound, !fallbackPolicy.allowsSecretFileFallback {
            NSLog("%@", "KeychainStore: SecItem read failed for \(account) (OSStatus \(primary.status))")
        }
        return readFallbackForMigrationOrDevelopment(account, keychainStatus: primary.status)
    }

    /// One `SecItemCopyMatching` for `account` in the given sync domain.
    private func readItem(_ account: String,
                          synchronizable: Bool) -> (status: OSStatus, value: String?) {
        var query = baseQuery(for: account, synchronizable: synchronizable)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return (status, nil) }
        return (status, value)
    }

    private func deleteLegacyLocalItem(for account: String) {
        SecItemDelete(baseQuery(for: account, synchronizable: false) as CFDictionary)
    }

    /// Remove the value for `account` (no-op if absent). For synced accounts this deletes
    /// BOTH the synchronizable item (propagating the sign-out to the user's other devices
    /// via iCloud Keychain) and any legacy device-local copy.
    @discardableResult
    func delete(_ account: String) -> Bool {
        if let outcome = deleteInterceptor?(account) { return outcome }
        if usesDevelopmentFileStorage {
            cleanupFallback(for: account)
            return true
        }

        var query = baseQuery(for: account, synchronizable: false)
        if isSynchronized(account) {
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        }
        let status = SecItemDelete(query as CFDictionary)
        cleanupFallback(for: account)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - File fallback (unsigned Simulator / missing-entitlement only)

    private func saveDevelopmentFileStorage(_ data: Data, for account: String) -> Bool {
        // macOS per-worktree dev apps are rebuilt/ad-hoc signed constantly. The standard login
        // keychain then prompts once per touched generic-password item (and often again after the
        // next rebuild), which makes real backend testing unusable. This path is deliberately
        // opt-in from AppRuntime for non-canonical macOS dev bundle IDs only; production and all
        // canonical production and all non-macOS paths continue to use Keychain.
        saveFallback(data, for: account)
    }

    private func readDevelopmentFileStorage(_ account: String) -> String? {
        let url = fallbackURL(for: account)
        guard let data = try? Data(contentsOf: url),
              let value = String(data: data, encoding: .utf8) else { return nil }
        try? CredentialArtifactStorage.applyProtectionAndBackupExclusion(
            to: url,
            protection: CredentialArtifactStorage.credentialFallbackProtection,
            fileManager: fileManager)
        try? CredentialArtifactStorage.applyProtectionAndBackupExclusion(
            to: url.deletingLastPathComponent(),
            protection: CredentialArtifactStorage.credentialFallbackProtection,
            fileManager: fileManager)
        return value
    }

    private func saveToKeychain(_ data: Data,
                                query: [String: Any],
                                attributes: [String: Any]) -> OSStatus {
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        return status
    }

    private func saveFallbackDataToKeychain(_ data: Data, for account: String) -> Bool {
        let query = baseQuery(for: account, synchronizable: isSynchronized(account))
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = saveToKeychain(data, query: query, attributes: attributes)
        if status == errSecSuccess {
            cleanupFallback(for: account)
            return true
        }
        NSLog("%@", "KeychainStore: fallback migration failed for \(account) (OSStatus \(status))")
        return false
    }

    private func fallbackDirectory() -> URL {
        fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LabstreamSecrets", isDirectory: true)
    }

    private func fallbackURL(for account: String) -> URL {
        fallbackDirectory().appendingPathComponent("\(service).\(account)")
    }

    @discardableResult
    private func saveFallback(_ data: Data, for account: String) -> Bool {
        let url = fallbackURL(for: account)
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try CredentialArtifactStorage.applyProtectionAndBackupExclusion(
                to: url.deletingLastPathComponent(),
                protection: CredentialArtifactStorage.credentialFallbackProtection,
                fileManager: fileManager)
            try CredentialArtifactStorage.writeCredentialFallback(data, to: url, fileManager: fileManager)
            return true
        } catch {
            NSLog("%@", "KeychainStore: file fallback save failed for \(account): \(error)")
            return false
        }
    }

    private func readFallbackForMigrationOrDevelopment(_ account: String,
                                                       keychainStatus: OSStatus) -> String? {
        let canUseDevelopmentFallback = fallbackPolicy.allowsSecretFileFallback
        // Release must not even discover/import a credential file left behind by a Debug
        // development build. Legacy fallback migration is a Debug-only bridge; shipping
        // binaries fail closed when Keychain has no item.
        let canAttemptMigration = fallbackPolicy.buildConfiguration == .debug
            && keychainStatus == errSecItemNotFound
        guard canUseDevelopmentFallback || canAttemptMigration else { return nil }

        let url = fallbackURL(for: account)
        guard let data = try? Data(contentsOf: url),
              let value = String(data: data, encoding: .utf8) else { return nil }

        // Harden any legacy fallback file before deciding whether it may be used.
        try? CredentialArtifactStorage.applyProtectionAndBackupExclusion(
            to: url,
            protection: CredentialArtifactStorage.credentialFallbackProtection,
            fileManager: fileManager)
        try? CredentialArtifactStorage.applyProtectionAndBackupExclusion(
            to: url.deletingLastPathComponent(),
            protection: CredentialArtifactStorage.credentialFallbackProtection,
            fileManager: fileManager)

        if canAttemptMigration, saveFallbackDataToKeychain(data, for: account) {
            return value
        }

        return canUseDevelopmentFallback ? value : nil
    }

    private func cleanupFallback(for account: String) {
        try? fileManager.removeItem(at: fallbackURL(for: account))
    }

    // MARK: Convenience for the two well-known keys

    var token: String? {
        get { read(Self.tokenKey) }
        set {
            if let newValue { saveToken(newValue) }
            else { delete(Self.tokenKey) }
        }
    }

    @discardableResult
    func saveToken(_ token: String) -> Bool {
        save(token, for: Self.tokenKey)
    }

    var selectedBackend: MediaBackendKind {
        get { read(Self.selectedBackendKey).flatMap(MediaBackendKind.init(rawValue:)) ?? .plex }
        set { _ = saveSelectedBackend(newValue) }
    }

    /// Persist the user-facing backend choice. Authentication code must use this
    /// result-bearing API rather than the convenience property setter so a failed
    /// Keychain write cannot be followed by publishing a backend that will silently
    /// change again on next launch.
    @discardableResult
    func saveSelectedBackend(_ backend: MediaBackendKind) -> Bool {
        save(backend.rawValue, for: Self.selectedBackendKey)
    }

    /// Remove backend restoration/selection state. The read-side default is Plex, so a
    /// coordinated sign-out returns to a deterministic login surface without persisting
    /// a backend choice that could silently restore a retired session.
    @discardableResult
    func resetSelectedBackend() -> Bool {
        delete(Self.selectedBackendKey)
    }

    var selectedPlexServerID: String? {
        get { read(Self.selectedPlexServerIDKey) }
        set { _ = saveSelectedPlexServerID(newValue) }
    }

    @discardableResult
    func saveSelectedPlexServerID(_ serverID: String?) -> Bool {
        setOptional(serverID, for: Self.selectedPlexServerIDKey)
    }

    var jellyfinServerURLString: String? {
        get { read(Self.jellyfinServerURLKey) }
        set { setOptional(newValue, for: Self.jellyfinServerURLKey) }
    }

    var jellyfinAccessToken: String? {
        get { read(Self.jellyfinAccessTokenKey) }
        set { setOptional(newValue, for: Self.jellyfinAccessTokenKey) }
    }

    var jellyfinUserID: String? {
        get { read(Self.jellyfinUserIDKey) }
        set { setOptional(newValue, for: Self.jellyfinUserIDKey) }
    }

    var jellyfinServerID: String? {
        get { read(Self.jellyfinServerIDKey) }
        set { setOptional(newValue, for: Self.jellyfinServerIDKey) }
    }

    var embyServerURLString: String? {
        get { read(Self.embyServerURLKey) }
        set { setOptional(newValue, for: Self.embyServerURLKey) }
    }

    var embyAccessToken: String? {
        get { read(Self.embyAccessTokenKey) }
        set { setOptional(newValue, for: Self.embyAccessTokenKey) }
    }

    var embyUserID: String? {
        get { read(Self.embyUserIDKey) }
        set { setOptional(newValue, for: Self.embyUserIDKey) }
    }

    var embyServerID: String? {
        get { read(Self.embyServerIDKey) }
        set { setOptional(newValue, for: Self.embyServerIDKey) }
    }

    @discardableResult
    private func setOptional(_ value: String?, for key: String) -> Bool {
        if let value, !value.isEmpty { return save(value, for: key) }
        return delete(key)
    }

    @discardableResult
    func saveJellyfinSession(serverURLString: String,
                             accessToken: String,
                             userID: String,
                             serverID: String?) -> Bool {
        saveCredentialSet(
            required: [
                (Self.jellyfinServerURLKey, serverURLString),
                (Self.jellyfinAccessTokenKey, accessToken),
                (Self.jellyfinUserIDKey, userID),
            ],
            optional: [(Self.jellyfinServerIDKey, serverID)])
    }

    @discardableResult
    func saveEmbySession(serverURLString: String,
                         accessToken: String,
                         userID: String,
                         serverID: String?) -> Bool {
        saveCredentialSet(
            required: [
                (Self.embyServerURLKey, serverURLString),
                (Self.embyAccessTokenKey, accessToken),
                (Self.embyUserIDKey, userID),
            ],
            optional: [(Self.embyServerIDKey, serverID)])
    }

    private func saveCredentialSet(required: [(String, String)],
                                   optional: [(String, String?)]) -> Bool {
        let allKeys = required.map(\.0) + optional.map(\.0)
        let previous = Dictionary(uniqueKeysWithValues: allKeys.map { ($0, read($0)) })
        func rollback() {
            var succeeded = true
            for key in allKeys {
                if let value = previous[key] ?? nil {
                    succeeded = save(value, for: key) && succeeded
                } else {
                    succeeded = delete(key) && succeeded
                }
            }
            if !succeeded {
                NSLog("%@", "KeychainStore: credential-set rollback was incomplete")
            }
        }
        for (key, value) in required {
            guard save(value, for: key) else {
                rollback()
                return false
            }
        }
        for (key, value) in optional {
            if let value, !value.isEmpty {
                guard save(value, for: key) else {
                    rollback()
                    return false
                }
            } else {
                guard delete(key) else {
                    rollback()
                    return false
                }
            }
        }
        return true
    }

    /// Returns the persisted client identifier, generating + storing one on first
    /// access so the value is stable for the lifetime of the install.
    func clientIdentifier() -> String? {
        if let existing = read(Self.clientIdentifierKey) { return existing }
        let generated = UUID().uuidString
        return save(generated, for: Self.clientIdentifierKey) ? generated : nil
    }
}
