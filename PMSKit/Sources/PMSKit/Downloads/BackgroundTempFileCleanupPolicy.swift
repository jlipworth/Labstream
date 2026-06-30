import Foundation

public enum BackgroundNetworkTempCleanupDisposition: Sendable, Equatable {
    case none
    case skipLiveTasks(liveTaskCount: Int)
    case deleteCandidates
}

/// Pure file-name/path decisions for background-download temporary-file cleanup.
///
/// The app layer still owns filesystem reads/deletes and diagnostics. This policy only pins which
/// temp paths are in scope and when a cleanup pass is allowed to remove them.
public enum BackgroundTempFileCleanupPolicy {
    public static let rangeChunkStashPrefix = "vp-range-chunk-"
    public static let cfNetworkTempPrefix = "CFNetworkDownload_"
    public static let cfNetworkTempSuffix = ".tmp"

    public static func nsurlsessiondRelativeDownloadCache(bundleID: String) -> String {
        "Caches/com.apple.nsurlsessiond/Downloads/\(bundleID)"
    }

    public static func networkTempDirectories(tempDirectory: URL,
                                              appSupportDirectory: URL?,
                                              bundleID: String) -> [URL] {
        var directories = [tempDirectory]
        if let appSupportDirectory {
            let library = appSupportDirectory.deletingLastPathComponent()
            directories.append(library.appendingPathComponent(
                nsurlsessiondRelativeDownloadCache(bundleID: bundleID),
                isDirectory: true
            ))
        }
        return directories
    }

    public static func isCFNetworkDownloadTempFile(fileName: String,
                                                   isRegularFile: Bool) -> Bool {
        isRegularFile
            && fileName.hasPrefix(cfNetworkTempPrefix)
            && fileName.hasSuffix(cfNetworkTempSuffix)
    }

    public static func rangeChunkStashTaskIdentifier(fileName: String) -> Int? {
        guard fileName.hasPrefix(rangeChunkStashPrefix) else { return nil }
        return Int(fileName.dropFirst(rangeChunkStashPrefix.count))
    }

    public static func shouldDeleteRangeChunkStash(fileName: String,
                                                   liveTaskIdentifiers: Set<Int>) -> Bool {
        guard let taskIdentifier = rangeChunkStashTaskIdentifier(fileName: fileName) else {
            return false
        }
        return !liveTaskIdentifiers.contains(taskIdentifier)
    }

    public static func cleanupDisposition(liveTaskCount: Int,
                                          candidateCount: Int) -> BackgroundNetworkTempCleanupDisposition {
        guard candidateCount > 0 else { return .none }
        guard liveTaskCount == 0 else {
            return .skipLiveTasks(liveTaskCount: liveTaskCount)
        }
        return .deleteCandidates
    }
}
