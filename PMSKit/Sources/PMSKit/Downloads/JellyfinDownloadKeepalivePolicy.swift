import Foundation

/// Sanitized inputs required to keep a Jellyfin transcoding download's PlaySession alive.
public struct JellyfinDownloadKeepaliveCandidate: Equatable, Sendable {
    public var ratingKey: String
    public var itemID: String
    public var mediaSourceID: String
    public var playSessionID: String
    public var durationMs: Int?

    public init(ratingKey: String,
                itemID: String,
                mediaSourceID: String,
                playSessionID: String,
                durationMs: Int?) {
        self.ratingKey = ratingKey
        self.itemID = itemID
        self.mediaSourceID = mediaSourceID
        self.playSessionID = playSessionID
        self.durationMs = durationMs
    }
}

/// Pure Jellyfin keepalive predicates for active transcoding downloads.
///
/// The app layer still owns live session lookup, server-match checks, request construction, and the
/// task lifetime. This policy pins which persisted rows are allowed to start a keepalive and how
/// progress maps to Jellyfin ticks.
public enum JellyfinDownloadKeepalivePolicy {
    public static let intervalSeconds: Double = 20

    public static func candidate(for record: DownloadRecord,
                                 hasExistingTask: Bool) -> JellyfinDownloadKeepaliveCandidate? {
        guard !hasExistingTask,
              record.status == .queued || record.status == .downloading,
              let metadata = record.metadata,
              metadata.resolvedBackendKind(ratingKey: record.ratingKey) == .jellyfin,
              metadata.resolvedDownloadLane() != .original,
              let playSessionID = trimmedNonEmpty(metadata.playSessionID),
              let mediaSourceID = trimmedNonEmpty(metadata.mediaSourceID)
        else { return nil }

        return JellyfinDownloadKeepaliveCandidate(
            ratingKey: record.ratingKey,
            itemID: DownloadRecordIdentity.jellyfinItemID(fromRecordKey: record.ratingKey),
            mediaSourceID: mediaSourceID,
            playSessionID: playSessionID,
            durationMs: metadata.duration)
    }

    public static func positionTicks(progress: Double, durationMs: Int?) -> Int {
        guard let durationMs, durationMs > 0, progress.isFinite else { return 0 }
        let ticks = Double(durationMs) * 10_000 * max(0, min(progress, 1))
        return ticks.isFinite ? max(0, Int(ticks.rounded())) : 0
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
