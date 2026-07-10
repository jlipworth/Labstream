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

    /// N2/F2c: the advancing position a keepalive should report for a forward-only transcode
    /// download. Such rows have no exact progress fraction (`record.progress` stays 0 — no
    /// Content-Length), so a keepalive built on it pings PositionTicks=0 forever and the server
    /// sees a stationary session it may idle-kill mid-download. Derive an honest, advancing
    /// position instead, in preference order:
    /// 1. the exact fraction when the lane has one (`progress > 0`),
    /// 2. received bytes against the duration×bitrate estimate (the same estimate the progress
    ///    bar uses) — advances exactly when the transfer does,
    /// 3. elapsed wall clock — a transcode is produced at least at playback rate, so elapsed time
    ///    is a lower bound on the encoded position, never an overstatement.
    /// The result is capped at the source duration and clamped monotonic against
    /// `lastReportedTicks` so switching signal sources can never report the session moving
    /// backwards.
    public static func reportedPositionTicks(progress: Double,
                                             bytes: Int,
                                             estimatedTotalBytes: Int?,
                                             elapsedSeconds: Double,
                                             durationMs: Int?,
                                             lastReportedTicks: Int) -> Int {
        var candidate = 0
        if let durationMs, durationMs > 0 {
            if progress.isFinite, progress > 0 {
                candidate = positionTicks(progress: progress, durationMs: durationMs)
            } else if let estimatedTotalBytes, estimatedTotalBytes > 0, bytes > 0 {
                let fraction = min(1, Double(bytes) / Double(estimatedTotalBytes))
                candidate = positionTicks(progress: fraction, durationMs: durationMs)
            }
        }
        if candidate == 0, elapsedSeconds.isFinite, elapsedSeconds > 0 {
            let elapsedTicks = (elapsedSeconds * 10_000_000).rounded()
            candidate = elapsedTicks.isFinite ? Int(elapsedTicks) : 0
            if let durationMs, durationMs > 0 {
                candidate = min(candidate, durationMs * 10_000)
            }
        }
        return max(max(0, lastReportedTicks), candidate)
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// One keepalive tick's collapsed health outcome (audit lens 8, A-2).
///
/// The keepalive previously `try?`-swallowed every HTTP response, so a rotated token silently
/// stopped reporting progress and the server idle-killed the encoder with zero diagnostic trail.
public enum JellyfinKeepaliveTickOutcome: Equatable, Sendable {
    case healthy
    /// At least one request failed at the transport layer (no HTTP response at all).
    case transportFailure
    /// At least one request returned a non-2xx, non-auth status.
    case httpFailure(statusCode: Int)
    /// At least one request returned 401/403 — the credential is dead.
    case authRejected(statusCode: Int)
}

extension JellyfinDownloadKeepalivePolicy {
    /// Collapse the tick's status codes (nil = transport error) into a single outcome.
    /// Auth-dead dominates, then the first non-2xx HTTP status, then transport failure.
    public static func tickOutcome(statuses: [Int?]) -> JellyfinKeepaliveTickOutcome {
        var firstHTTPFailure: Int?
        var sawTransportFailure = false
        for status in statuses {
            guard let status else {
                sawTransportFailure = true
                continue
            }
            if status == 401 || status == 403 { return .authRejected(statusCode: status) }
            if !(200..<300).contains(status), firstHTTPFailure == nil { firstHTTPFailure = status }
        }
        if let firstHTTPFailure { return .httpFailure(statusCode: firstHTTPFailure) }
        if sawTransportFailure { return .transportFailure }
        return .healthy
    }

    public enum HealthAction: Equatable, Sendable {
        case none
        /// First failure of this shape (or a changed failure status) — emit
        /// `downloads.jellyfin_keepalive_degraded` once, not every tick.
        case emitDegraded(reason: String)
        /// A previously degraded keepalive is healthy again.
        case emitRecovered
        /// 401/403: stop pinging — an auth-dead loop only spams the server and hides the problem.
        case stopAuthDead(statusCode: Int)
    }

    public static func healthAction(previous: JellyfinKeepaliveTickOutcome?,
                                    outcome: JellyfinKeepaliveTickOutcome) -> HealthAction {
        if case .authRejected(let statusCode) = outcome {
            return .stopAuthDead(statusCode: statusCode)
        }
        switch outcome {
        case .healthy:
            if let previous, previous != .healthy { return .emitRecovered }
            return .none
        default:
            guard previous != outcome else { return .none }
            return .emitDegraded(reason: degradedReason(outcome))
        }
    }

    public static func degradedReason(_ outcome: JellyfinKeepaliveTickOutcome) -> String {
        switch outcome {
        case .healthy: return "healthy"
        case .transportFailure: return "transport"
        case .httpFailure(let statusCode): return "http_\(statusCode)"
        case .authRejected(let statusCode): return "auth_\(statusCode)"
        }
    }
}
