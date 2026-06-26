import Foundation

/// Token-free identities for scoping UI/session state and server-user preferences.
///
/// `stableServerUserKey` is deterministic across re-authentication for the same backend,
/// server, and user, so it is suitable for preference keys. `browseSessionKey` layers a
/// caller-owned auth/session revision on top, so SwiftUI `.id` / `.task(id:)` caches can
/// invalidate on re-auth without ever embedding raw access tokens.
public enum SessionIdentity {
    /// Stable, token-free key for preferences that belong to one backend + server + user.
    ///
    /// The server component prefers the backend's own server id. Legacy/unidentified
    /// sessions fall back to a canonical base-URL shape, but only a deterministic hash is
    /// stored in the key — never the raw hostname/base URL.
    public static func stableServerUserKey(backend: MediaBackendChoice,
                                           serverID: String?,
                                           baseURL: URL?,
                                           userID: String?) -> String? {
        guard let server = serverComponent(serverID: serverID, baseURL: baseURL) else { return nil }
        return "\(backend.rawValue):\(server):\(userComponent(userID))"
    }

    /// Runtime browse/session key for view identity and in-memory cache invalidation.
    ///
    /// This key is token-free but intentionally changes when the caller increments
    /// `authRevision`, e.g. after a sign-in, sign-out, or token/session replacement.
    public static func browseSessionKey(backend: MediaBackendChoice,
                                        serverID: String?,
                                        baseURL: URL?,
                                        userID: String?,
                                        authRevision: Int) -> String {
        let stable = stableServerUserKey(backend: backend,
                                         serverID: serverID,
                                         baseURL: baseURL,
                                         userID: userID)
            ?? "\(backend.rawValue):server#unresolved:\(userComponent(userID))"
        return "\(stable):rev#\(max(0, authRevision))"
    }

    /// Old library-visibility keys used raw server ids or hostnames directly. New code
    /// should not write these, but callers can use them to migrate existing preferences.
    public static func legacyRawBackendKey(backend: MediaBackendChoice,
                                           serverID: String?,
                                           baseURLHost: String?) -> String? {
        let resolved = nonEmpty(serverID) ?? nonEmpty(baseURLHost)
        guard let resolved else { return nil }
        return "\(backend.rawValue):\(resolved)"
    }

    /// Canonical URL material used only as hash input. Exposed for tests.
    public static func canonicalBaseURLIdentity(_ url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard let scheme = nonEmpty(components.scheme)?.lowercased() else { return nil }
        let host = nonEmpty(components.host)?.lowercased()
            ?? nonEmpty(url.host(percentEncoded: false))?.lowercased()
        guard let host else { return nil }

        components.scheme = scheme
        components.host = host
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil

        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        if path == "/" { path = "" }

        var identity = "\(scheme)://\(host)"
        if let port = components.port {
            identity += ":\(port)"
        }
        identity += path
        return identity
    }

    private static func serverComponent(serverID: String?, baseURL: URL?) -> String? {
        if let serverID = nonEmpty(serverID) {
            return "sid#\(stableIdentifier(for: "sid:\(serverID)"))"
        }
        if let baseURL, let canonical = canonicalBaseURLIdentity(baseURL) {
            return "url#\(stableIdentifier(for: "url:\(canonical)"))"
        }
        return nil
    }

    private static func userComponent(_ userID: String?) -> String {
        guard let userID = nonEmpty(userID) else { return "user#none" }
        return "user#\(stableIdentifier(for: "user:\(userID)"))"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func stableIdentifier(for raw: String) -> String {
        // FNV-1a: deterministic, short, and enough for local scoping keys. This is
        // not used as a security boundary; it keeps raw hosts/users out of persisted
        // identifiers while preserving stable equality for the same inputs.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in raw.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}
