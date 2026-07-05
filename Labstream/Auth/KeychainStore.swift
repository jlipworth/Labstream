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
/// downloads read the token while the headset is locked.
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

    private let service: String
    private let fallbackPolicy: SecretFileFallbackPolicy
    private let fileManager: FileManager

    init(service: String = "com.visionplay.app",
         fallbackPolicy: SecretFileFallbackPolicy = .current,
         fileManager: FileManager = .default) {
        self.service = service
        self.fallbackPolicy = fallbackPolicy
        self.fileManager = fileManager
    }

    /// Insert or update the value for `account`.
    @discardableResult
    func save(_ value: String, for account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = saveToKeychain(data, query: query, attributes: attributes)
        if status == errSecSuccess {
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess,
           let data = result as? Data,
           let value = String(data: data, encoding: .utf8) {
            cleanupFallback(for: account)
            return value
        }

        if status != errSecItemNotFound, !fallbackPolicy.allowsSecretFileFallback {
            NSLog("%@", "KeychainStore: SecItem read failed for \(account) (OSStatus \(status))")
        }
        return readFallbackForMigrationOrDevelopment(account, keychainStatus: status)
    }

    /// Remove the value for `account` (no-op if absent).
    @discardableResult
    func delete(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        cleanupFallback(for: account)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - File fallback (unsigned Simulator / missing-entitlement only)

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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
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
        let canAttemptMigration = keychainStatus == errSecItemNotFound
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
        set { save(newValue.rawValue, for: Self.selectedBackendKey) }
    }

    var selectedPlexServerID: String? {
        get { read(Self.selectedPlexServerIDKey) }
        set { setOptional(newValue, for: Self.selectedPlexServerIDKey) }
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

    private func setOptional(_ value: String?, for key: String) {
        if let value, !value.isEmpty { save(value, for: key) }
        else { delete(key) }
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
        for (key, value) in required {
            guard save(value, for: key) else {
                allKeys.forEach { delete($0) }
                return false
            }
        }
        for (key, value) in optional {
            if let value, !value.isEmpty {
                guard save(value, for: key) else {
                    allKeys.forEach { delete($0) }
                    return false
                }
            } else {
                delete(key)
            }
        }
        return true
    }

    /// Returns the persisted client identifier, generating + storing one on first
    /// access so the value is stable for the lifetime of the install.
    func clientIdentifier() -> String {
        if let existing = read(Self.clientIdentifierKey) { return existing }
        let generated = UUID().uuidString
        save(generated, for: Self.clientIdentifierKey)
        return generated
    }
}
