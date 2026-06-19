import Foundation
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

    private let service: String

    init(service: String = "com.visionplay.app") {
        self.service = service
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

        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        if status == errSecSuccess {
            // Drop any stale fallback so it can't shadow the real value later.
            try? FileManager.default.removeItem(at: fallbackURL(for: account))
            return true
        }

        NSLog("%@", "KeychainStore: SecItem save failed for \(account) (OSStatus \(status)); using file fallback")
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
            return value
        }
        return readFallback(account)
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
        try? FileManager.default.removeItem(at: fallbackURL(for: account))
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - File fallback (unsigned Simulator / missing-entitlement only)

    private func fallbackURL(for account: String) -> URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VisionPlaySecrets", isDirectory: true)
        return dir.appendingPathComponent("\(service).\(account)")
    }

    @discardableResult
    private func saveFallback(_ data: Data, for account: String) -> Bool {
        let url = fallbackURL(for: account)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return true
        } catch {
            NSLog("%@", "KeychainStore: file fallback save failed for \(account): \(error)")
            return false
        }
    }

    private func readFallback(_ account: String) -> String? {
        guard let data = try? Data(contentsOf: fallbackURL(for: account)) else { return nil }
        return String(data: data, encoding: .utf8)
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

    private func setOptional(_ value: String?, for key: String) {
        if let value, !value.isEmpty { save(value, for: key) }
        else { delete(key) }
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
