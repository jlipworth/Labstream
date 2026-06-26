import Foundation

// Shared low-level helpers for the Emby/Jellyfin (forked-API) backends. These return
// optionals rather than throwing so each backend keeps its own error type at the call
// site (EmbyServerURLError/JellyfinServerURLError, EmbyPlaybackError/JellyfinPlaybackError),
// which existing tests assert on.

public enum MediaBrowserURL {
    /// Validate and normalize a user-entered server address. Returns nil if the input is
    /// empty or does not resolve to an http/https URL with a host.
    ///
    /// The user-entered base path (for example Emby's `/emby`) is PRESERVED verbatim:
    /// relative stream URLs returned by PlaybackInfo are joined onto `server.path`, so the
    /// normalizer must not strip it. Default ports are a caller/UX concern.
    public static func normalizedServerURL(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"

        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              (scheme == "https" || scheme == "http"),
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        return url
    }

    /// Join a server-relative path (or same-origin absolute URL) onto the server base
    /// URL, PRESERVING the server's base path (for example `/emby`). Returns nil if a URL
    /// cannot be constructed or if an absolute URL is not same-origin with `server`.
    public static func join(server: URL, pathOrURLString: String) -> URL? {
        joinTrustedServerURL(server: server, pathOrURLString: pathOrURLString)
    }

    /// Join a backend-provided media URL that will be fetched with MediaBrowser credentials.
    ///
    /// Relative paths are resolved against the configured server while preserving its base path.
    /// Absolute URLs are accepted only when they match the server's effective origin: same
    /// http(s) scheme, case-insensitive host, and effective port (implicit 443/80 default ports
    /// are treated the same as explicit ones).
    public static func joinTrustedServerURL(server: URL, pathOrURLString: String) -> URL? {
        if let absolute = URL(string: pathOrURLString), absolute.scheme != nil {
            return isSameOrigin(absolute, server: server) ? absolute : nil
        }
        return joinRelative(server: server, pathOrURLString: pathOrURLString)
    }

    public static func isSameOrigin(_ url: URL, server: URL) -> Bool {
        guard let lhs = origin(for: url),
              let rhs = origin(for: server) else {
            return false
        }
        return lhs.scheme == rhs.scheme &&
            lhs.host.caseInsensitiveCompare(rhs.host) == .orderedSame &&
            lhs.port == rhs.port
    }

    private static func joinRelative(server: URL, pathOrURLString: String) -> URL? {
        guard var comps = URLComponents(url: server, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let basePath = comps.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let relativePath: String
        let query: String?
        if let qIndex = pathOrURLString.firstIndex(of: "?") {
            relativePath = String(pathOrURLString[..<qIndex])
            query = String(pathOrURLString[pathOrURLString.index(after: qIndex)...])
        } else {
            relativePath = pathOrURLString
            query = nil
        }
        let cleanRelative = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        comps.percentEncodedPath = "/" + [basePath, cleanRelative].filter { !$0.isEmpty }.joined(separator: "/")
        comps.percentEncodedQuery = query
        return comps.url
    }

    private static func origin(for url: URL) -> (scheme: String, host: String, port: Int)? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = comps.scheme?.lowercased(),
              let host = comps.host,
              !host.isEmpty,
              let port = effectivePort(for: scheme, explicitPort: comps.port) else {
            return nil
        }
        return (scheme, host, port)
    }

    private static func effectivePort(for scheme: String, explicitPort: Int?) -> Int? {
        if let explicitPort { return explicitPort }
        switch scheme {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}

public enum MediaBrowserAuth {
    /// Escape a value for embedding in a quoted authorization-header parameter.
    public static func quote(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
