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

    private let service: String

    init(service: String = "com.plexavp.app") {
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

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return false
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
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
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
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: Convenience for the two well-known keys

    var token: String? {
        get { read(Self.tokenKey) }
        set {
            if let newValue { save(newValue, for: Self.tokenKey) }
            else { delete(Self.tokenKey) }
        }
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
