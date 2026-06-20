import Foundation

public enum EmbyServerURLError: Error, Sendable, Equatable {
    case invalid
}

public enum EmbyServerURL {
    /// Normalize a user-entered Emby server address.
    ///
    /// The user-entered base path (for example `/emby`) is PRESERVED verbatim: Emby commonly
    /// serves under a `/emby` base path, and the relative stream URLs returned by PlaybackInfo
    /// are joined onto `server.path`, so the normalizer must not strip it. Default ports
    /// (8096 http / 8920 https) are a caller/UX concern; this only validates scheme + host.
    /// (Shared with Jellyfin via `MediaBrowserURL.normalizedServerURL`.)
    public static func normalized(_ input: String) throws -> URL {
        guard let url = MediaBrowserURL.normalizedServerURL(input) else {
            throw EmbyServerURLError.invalid
        }
        return url
    }
}
