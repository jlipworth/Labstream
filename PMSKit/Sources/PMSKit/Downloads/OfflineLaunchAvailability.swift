import Foundation

/// Pure admission rule for the restricted cold-launch Offline surface.
public enum OfflineLaunchAvailability {
    public static func hasPlayableDownload(
        records: [DownloadRecord],
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> Bool {
        records.contains { $0.isComplete && fileExists($0.localURL) }
    }

    /// The Offline launch surface is offered only when downloads ship on this product, the
    /// selected saved session was preserved through a transient reachability failure, and at
    /// least one completed local media file exists. Missing credentials (including an explicit
    /// sign-out), a confirmed invalid credential, or an unconfirmed identity keep sign-in.
    public static func admitsOfflineLaunch(restoreOutcome: SessionRestoreOutcome?,
                                           downloadsSupported: Bool,
                                           hasPlayableDownload: Bool) -> Bool {
        downloadsSupported && restoreOutcome == .temporarilyUnavailable && hasPlayableDownload
    }
}
