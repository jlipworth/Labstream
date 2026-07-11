import Foundation

public struct EmbyDownloadKeepaliveCandidate: Equatable, Sendable {
    public var ratingKey: String
    public var playSessionID: String

    public init(ratingKey: String, playSessionID: String) {
        self.ratingKey = ratingKey
        self.playSessionID = playSessionID
    }
}

/// Pure eligibility gate for Emby's live compatible-remux keepalive.
///
/// Explicit bitrate presets use persistent Convert jobs and originals/existing versions are static,
/// so `.compatibleRemux` is the only Emby lane whose HTTP body is served by an idle-killable encoder.
public enum EmbyDownloadKeepalivePolicy {
    public static let intervalSeconds = JellyfinDownloadKeepalivePolicy.intervalSeconds

    public static func candidate(for record: DownloadRecord,
                                 hasExistingTask: Bool) -> EmbyDownloadKeepaliveCandidate? {
        guard !hasExistingTask,
              record.status == .queued || record.status == .downloading,
              let metadata = record.metadata,
              metadata.resolvedBackendKind(ratingKey: record.ratingKey) == .emby,
              metadata.resolvedDownloadLane() == .compatibleRemux,
              let playSessionID = trimmedNonEmpty(metadata.playSessionID)
        else { return nil }

        return EmbyDownloadKeepaliveCandidate(ratingKey: record.ratingKey,
                                              playSessionID: playSessionID)
    }

    /// A naturally exiting task may finish after a replacement was installed for the same row.
    /// Only the generation that still owns the dictionary slot may remove it.
    public static func shouldRemoveTask(completingGeneration: UUID,
                                        currentGeneration: UUID?) -> Bool {
        currentGeneration == completingGeneration
    }

    public enum AuthQuarantineAction: Equatable, Sendable {
        case none
        /// The same rejected credential/session generation must not be restarted on every refresh.
        case suppress
        /// Credentials, user, or server changed; discard the old sentinel and allow a new task.
        case clear
    }

    public static func authQuarantineAction(quarantinedGeneration: String?,
                                            currentGeneration: String) -> AuthQuarantineAction {
        guard let quarantinedGeneration else { return .none }
        return quarantinedGeneration == currentGeneration ? .suppress : .clear
    }

    /// A PlaySession belongs to the user who minted it. Legacy rows without a persisted user keep
    /// today's best-effort behavior, but a known user must match exactly before any ping is sent.
    public static func matchesPersistedUser(_ persistedUserID: String?,
                                            currentUserID: String?) -> Bool {
        guard let persisted = trimmedNonEmpty(persistedUserID) else { return true }
        return trimmedNonEmpty(currentUserID) == persisted
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
