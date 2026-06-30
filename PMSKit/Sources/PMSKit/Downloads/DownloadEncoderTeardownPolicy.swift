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

    public static func decision(backend: DownloadBackendKind,
                                transientPlaySessionID: String?,
                                metadata: OfflineMetadata?,
                                sessionAvailable: Bool,
                                sessionMatchesPersistedServer: Bool?) -> Decision {
        if let transientPlaySessionID, !transientPlaySessionID.isEmpty {
            guard sessionAvailable else { return .none }
            if let sessionMatchesPersistedServer, !sessionMatchesPersistedServer { return .none }
            return .stop(playSessionID: transientPlaySessionID)
        }

        guard let metadata,
              metadata.playSessionID?.isEmpty == false,
              metadata.resolvedBackendKind(ratingKey: metadata.ratingKey) == backend,
              sessionAvailable,
              sessionMatchesPersistedServer == false else {
            return .none
        }
        return .skip(reason: serverMismatchReason)
    }
}
