import Foundation

/// Pure helpers for VisionPlex system-entry routing (App Intents and Spotlight).
/// Kept in PMSKit so identifier parsing and one-shot autoplay behavior have unit coverage
/// without depending on SwiftUI/AppIntents/CoreSpotlight.
public enum MediaSearchIdentifier {
    public static let separator = "|"

    /// Build a non-secret, server-scoped identifier for a media item in system search.
    /// The namespace prevents a Spotlight result from one server accidentally opening the
    /// same ratingKey on another server. The host/port is already visible connection metadata;
    /// no token or path is included.
    public static func make(ratingKey: String, server: URL) -> String {
        "\(serverNamespace(server))\(separator)\(ratingKey)"
    }

    /// Recover the media ratingKey from a system-search identifier. Older builds indexed
    /// bare ratingKeys, so a string without the namespace separator remains valid.
    public static func ratingKey(from identifier: String) -> String {
        identifier.split(separator: separator, maxSplits: 1, omittingEmptySubsequences: false)
            .last
            .map(String.init) ?? identifier
    }

    private static func serverNamespace(_ server: URL) -> String {
        let host = server.host(percentEncoded: false) ?? server.host ?? server.absoluteString
        if let port = server.port {
            return "\(host):\(port)"
        }
        return host
    }
}

/// Minimal one-shot gate for an out-of-app "play this" request.
///
/// App Intents route through DetailView before playback can start. The router arms the
/// requested item, then DetailView consumes it after navigation. Consumption is one-shot
/// and time-boxed so a failed/stale route cannot surprise-autoplay a later manual visit.
public struct PendingAutoPlayGate: Equatable {
    private var arm: Arm?

    public init() {}

    public mutating func arm(ratingKey: String, now: Date = Date()) {
        arm = Arm(ratingKey: ratingKey, armedAt: now)
    }

    public mutating func consume(ratingKey: String, now: Date = Date(), maxAge: TimeInterval = 30) -> Bool {
        guard let current = arm, current.ratingKey == ratingKey else { return false }
        arm = nil
        return now.timeIntervalSince(current.armedAt) < maxAge
    }

    private struct Arm: Equatable {
        let ratingKey: String
        let armedAt: Date
    }
}
