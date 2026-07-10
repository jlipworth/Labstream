import Foundation

/// Pure terminal cleanup decision for backend live encoders created by download/transcode lanes.
///
/// The app layer owns service calls and mutable play-session maps. This policy pins when a terminal
/// transition should fire a best-effort ActiveEncodings teardown and when it should only log that a
/// persisted playSession belongs to a different server lane.
public enum DownloadEncoderTeardownPolicy {
    public enum Decision: Equatable, Sendable {
        case none
        case stop(playSessionID: String)
        case skip(reason: String)
    }

    public static let serverMismatchReason = "server_mismatch"

    /// `rowRemoved` marks the delete path: the store row is already gone and the caller is holding
    /// the last snapshot of it, so the persisted `playSessionID` is about to be destroyed with no
    /// later launch sweep able to retry — that is the one context where the persisted-psid branch
    /// must itself issue the `.stop` (JF-F5: after a relaunch the transient map is empty, so
    /// deleting a non-terminal row used to drop the only encoder handle without any teardown).
    /// Rows still in the store stay `.none` here on purpose: terminal rows are the launch sweep's
    /// job (a once-per-launch retry loop), and firing from every `releaseInFlight` would re-send
    /// the DELETE on every refresh tick while a server is unreachable.
    public static func decision(backend: DownloadBackendKind,
                                transientPlaySessionID: String?,
                                metadata: OfflineMetadata?,
                                sessionAvailable: Bool,
                                sessionMatchesPersistedServer: Bool?,
                                rowRemoved: Bool = false) -> Decision {
        if let transientPlaySessionID, !transientPlaySessionID.isEmpty {
            guard sessionAvailable else { return .none }
            if let sessionMatchesPersistedServer, !sessionMatchesPersistedServer { return .none }
            return .stop(playSessionID: transientPlaySessionID)
        }

        guard let metadata,
              let persistedPlaySessionID = metadata.playSessionID,
              !persistedPlaySessionID.isEmpty,
              metadata.resolvedBackendKind(ratingKey: metadata.ratingKey) == backend,
              sessionAvailable else {
            return .none
        }
        if sessionMatchesPersistedServer == false {
            return .skip(reason: serverMismatchReason)
        }
        guard rowRemoved, sessionMatchesPersistedServer == true else { return .none }
        return .stop(playSessionID: persistedPlaySessionID)
    }
}
