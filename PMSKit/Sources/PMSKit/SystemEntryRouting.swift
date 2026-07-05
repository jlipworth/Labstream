import Foundation

/// Backend/server/item identity for system-entry and navigation surfaces.
///
/// The app still only indexes Plex items today, but this value gives future Spotlight,
/// App Intent, and deep-link routes a single backend-scoped shape instead of passing a
/// raw `ratingKey` plus out-of-band active-backend state.
public struct BackendScopedMediaID: Sendable, Hashable, Codable {
    public static let currentPrefix = "vp1"

    public let backend: MediaBackendChoice
    public let serverNamespace: String?
    public let ratingKey: String

    public init(backend: MediaBackendChoice,
                serverNamespace: String? = nil,
                ratingKey: String) {
        self.backend = backend
        self.serverNamespace = serverNamespace?.isEmpty == true ? nil : serverNamespace
        self.ratingKey = ratingKey
    }

    public init(backend: MediaBackendChoice,
                server: URL,
                ratingKey: String) {
        self.init(backend: backend,
                  serverNamespace: Self.serverNamespace(server),
                  ratingKey: ratingKey)
    }

    /// Versioned identifier shape for new backend-scoped system-entry values.
    /// The final component is allowed to contain the separator so backend item ids remain opaque.
    public var identifier: String {
        [Self.currentPrefix, backend.rawValue, serverNamespace ?? "", ratingKey]
            .joined(separator: MediaSearchIdentifier.separator)
    }

    /// Parse a versioned backend-scoped id, a legacy server-scoped Plex id, or an old bare
    /// ratingKey. Legacy paths default to Plex to preserve existing Spotlight/App Intent entries.
    public init(systemIdentifier identifier: String) {
        let pieces = identifier.split(separator: MediaSearchIdentifier.separator,
                                      maxSplits: 3,
                                      omittingEmptySubsequences: false)
            .map(String.init)
        if pieces.count == 4,
           pieces[0] == Self.currentPrefix,
           let backend = MediaBackendChoice(rawValue: pieces[1]) {
            self.init(backend: backend,
                      serverNamespace: pieces[2].isEmpty ? nil : pieces[2],
                      ratingKey: pieces[3])
            return
        }

        let legacy = identifier.split(separator: MediaSearchIdentifier.separator,
                                      maxSplits: 1,
                                      omittingEmptySubsequences: false)
            .map(String.init)
        if legacy.count == 2 {
            self.init(backend: .plex,
                      serverNamespace: legacy[0].isEmpty ? nil : legacy[0],
                      ratingKey: legacy[1])
        } else {
            self.init(backend: .plex, ratingKey: identifier)
        }
    }

    public static func serverNamespace(_ server: URL) -> String {
        let host = server.host(percentEncoded: false) ?? server.host ?? server.absoluteString
        if let port = server.port {
            return "\(host):\(port)"
        }
        return host
    }
}

/// Pure helpers for Labstream system-entry routing (App Intents and Spotlight).
/// Kept in PMSKit so identifier parsing and one-shot autoplay behavior have unit coverage
/// without depending on SwiftUI/AppIntents/CoreSpotlight.
public enum MediaSearchIdentifier {
    public static let separator = "|"

    /// Build the existing non-secret, Plex/server-scoped identifier for a media item in system
    /// search. Kept byte-compatible with the current Plex-only Spotlight index.
    public static func make(ratingKey: String, server: URL) -> String {
        "\(BackendScopedMediaID.serverNamespace(server))\(separator)\(ratingKey)"
    }

    /// Build a versioned backend-scoped identifier for future non-Plex system-entry routes.
    public static func make(ratingKey: String, server: URL, backend: MediaBackendChoice) -> String {
        BackendScopedMediaID(backend: backend, server: server, ratingKey: ratingKey).identifier
    }

    /// Recover the full backend-scoped route key from a system-search identifier. Older builds
    /// indexed bare ratingKeys or `server|ratingKey`, so both forms still parse as Plex keys.
    public static func routeKey(from identifier: String) -> BackendScopedMediaID {
        BackendScopedMediaID(systemIdentifier: identifier)
    }

    /// Recover the media ratingKey from a system-search identifier. Older builds indexed
    /// bare ratingKeys, and current Plex-only Spotlight IDs are `server|ratingKey`.
    public static func ratingKey(from identifier: String) -> String {
        routeKey(from: identifier).ratingKey
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
