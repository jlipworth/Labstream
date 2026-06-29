import Foundation

/// Pure policy for deciding when a visible MediaBrowser forward-only download has stopped making
/// byte progress long enough that the app should do what the user currently does manually: cancel
/// the stale encoder stream and retry from a fresh server-minted URL/session (#189).
public enum DownloadStallRecoveryPolicy {
    /// Long enough to avoid racing normal encoder pauses or short Wi-Fi blips, short enough to recover
    /// from the observed "active-looking, zero-bandwidth forever" network-switch wedge without an
    /// overnight soak.
    public static let defaultForwardOnlyStallTimeout: TimeInterval = 90

    /// Bound automatic restarts per visible row. Forward-only streams restart from byte 0, so repeated
    /// restarts would waste server CPU/network and can mask a real outage. Manual retry remains.
    public static let defaultMaxAutomaticRestarts = 2

    /// Only forward-only MediaBrowser streams should be auto-restarted. Static byte-range downloads
    /// already have durable checkpoint/range recovery, and Plex optimize phase 2 is a static Part once
    /// it exists.
    public static func isForwardOnlyMediaBrowserStream(_ record: DownloadRecord) -> Bool {
        guard record.status == .downloading,
              DownloadDisplayClassifier.isLiveTranscoderSourced(record) else { return false }
        let backend = record.metadata?.resolvedBackendKind(ratingKey: record.ratingKey)
            ?? DownloadBackendKind(ratingKeyPrefix: record.ratingKey)
        guard backend == .jellyfin || backend == .emby else { return false }
        return record.metadata?.resolvedResumeMode(ratingKey: record.ratingKey) != .staticByteRange
    }

    public static func shouldRestartForwardOnlyStream(record: DownloadRecord,
                                                      active: Bool,
                                                      lastForwardProgressAt: Date?,
                                                      now: Date,
                                                      restartAttempts: Int,
                                                      stallTimeout: TimeInterval = defaultForwardOnlyStallTimeout,
                                                      maxRestartAttempts: Int = defaultMaxAutomaticRestarts) -> Bool {
        guard active,
              isForwardOnlyMediaBrowserStream(record),
              restartAttempts < maxRestartAttempts,
              let lastForwardProgressAt else { return false }
        return now.timeIntervalSince(lastForwardProgressAt) >= stallTimeout
    }
}
