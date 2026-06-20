import Foundation

public enum EmbyServerURLError: Error, Sendable, Equatable {
    case invalid
}

public enum EmbyServerURL {
    /// Normalize a user-entered Emby server address.
    ///
    /// DIVERGENCE FROM JELLYFIN: the user-entered base path (for example `/emby`) is
    /// PRESERVED verbatim. Emby commonly serves under a `/emby` base path, and the
    /// relative stream URLs returned by PlaybackInfo are joined onto `server.path`, so
    /// the normalizer must not strip it. Default ports (8096 http / 8920 https) are a
    /// caller/UX concern; this normalizer only validates scheme + host.
    public static func normalized(_ input: String) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EmbyServerURLError.invalid }

        let candidate: String
        if trimmed.contains("://") {
            candidate = trimmed
        } else {
            candidate = "https://\(trimmed)"
        }

        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              (scheme == "https" || scheme == "http"),
              let host = url.host,
              !host.isEmpty else {
            throw EmbyServerURLError.invalid
        }
        return url
    }
}
