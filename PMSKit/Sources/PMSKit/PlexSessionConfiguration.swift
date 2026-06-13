import Foundation

/// URLSession policies shared by app executors that talk to Plex.
public enum PlexSessionConfiguration {
    /// Short-lived control-plane session for player recovery (#33).
    ///
    /// Use this when the current pooled connection may be poisoned by a heavy media stall:
    /// a fresh ephemeral session avoids shared cookies/cache and fails fast instead of
    /// waiting behind CFNetwork's normal request timeout.
    public static func recoveryControlPlane(timeout: TimeInterval = 5) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.waitsForConnectivity = false
        return config
    }

    /// Upstream session config for the media-session proxy (#33). Like `recoveryControlPlane`
    /// (ephemeral, no cache/cookies, no connectivity wait) but `timeout` is deliberately
    /// GENEROUS: it is the time-to-first-byte deadline, and a deep-seek prime can hold the
    /// connection silent for ~7–9s before PMS emits the first segment. Set the deadline above
    /// that ceiling so a legitimate prime completes inside it; a socket that produces nothing
    /// past the deadline is treated as wedged and triggers a rotate.
    public static func mediaUpstream(timeout: TimeInterval = 20) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.waitsForConnectivity = false
        return config
    }
}
