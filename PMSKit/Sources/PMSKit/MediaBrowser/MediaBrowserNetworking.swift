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

    /// Join a server-relative path (or pass through an absolute URL) onto the server base
    /// URL, PRESERVING the server's base path (for example `/emby`). Returns nil if a URL
    /// cannot be constructed.
    public static func join(server: URL, pathOrURLString: String) -> URL? {
        if let absolute = URL(string: pathOrURLString), absolute.scheme != nil {
            return absolute
        }
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
}

public enum MediaBrowserAuth {
    /// Escape a value for embedding in a quoted authorization-header parameter.
    public static func quote(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
