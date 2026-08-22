import Foundation

/// Pure admission rule for the restricted cold-launch Offline surface.
public enum OfflineLaunchAvailability {
    public static func hasPlayableDownload(
        records: [DownloadRecord],
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> Bool {
        records.contains { $0.isComplete && fileExists($0.localURL) }
    }
}
