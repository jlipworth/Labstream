import Foundation

public enum BackgroundNetworkTempCleanupDisposition: Sendable, Equatable {
    case none
    case skipLiveTasks(liveTaskCount: Int)
    case skipReattach
    case deleteCandidates
}

/// Which cleanup pass is asking. Reattach is special: a finished-but-undelivered background
/// download task is absent from `getAllTasks` while its completed payload still lives in a
/// `CFNetworkDownload_*.tmp` awaiting `didFinishDownloadingTo` delivery (#220), so a reattach
/// pass can never prove a CFNetwork temp is orphaned.
public enum BackgroundNetworkTempCleanupContext: String, Sendable {
    case reattach
    case manualScan = "manual_scan"
}

/// Pure file-name/path decisions for background-download temporary-file cleanup.
///
/// The app layer still owns filesystem reads/deletes and diagnostics. This policy only pins which
/// temp paths are in scope and when a cleanup pass is allowed to remove them.
public enum BackgroundTempFileCleanupPolicy {
    public static let rangeBodyStashPrefix = "vp-range-body-"
    public static let legacyRangeChunkStashPrefix = "vp-range-chunk-"
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

    public static func rangeBodyStashTaskIdentifier(fileName: String) -> Int? {
        func identifier(afterPrefix prefix: String) -> Int? {
            guard fileName.hasPrefix(prefix) else { return nil }
            var tail = String(fileName.dropFirst(prefix.count))
            if let dashO = tail.range(of: "-o") { tail = String(tail[..<dashO.lowerBound]) }
            return Int(tail)
        }
        return identifier(afterPrefix: rangeBodyStashPrefix)
            ?? identifier(afterPrefix: legacyRangeChunkStashPrefix)
    }

    public static func rangeBodyStashOffset(fileName: String) -> Int? {
        guard let dashO = fileName.range(of: "-o") else { return nil }
        return Int(fileName[dashO.upperBound...])
    }

    public static func shouldDeleteRangeBodyStash(fileName: String,
                                                  liveTaskIdentifiers: Set<Int>) -> Bool {
        guard let taskIdentifier = rangeBodyStashTaskIdentifier(fileName: fileName) else {
            return false
        }
        return !liveTaskIdentifiers.contains(taskIdentifier)
    }

    /// CFNetwork temps younger than this are never deletable, even by a manual scan: the file
    /// may back a completed transfer whose delegate delivery is still pending (#220 saw a response
    /// body suspended ~3h before delivery). 72h comfortably clears any suspension-delivery latency
    /// while still reclaiming genuinely leaked multi-GB temps.
    public static let minimumCFNetworkTempAge: TimeInterval = 72 * 60 * 60

    public static func cleanupDisposition(context: BackgroundNetworkTempCleanupContext,
                                          liveTaskCount: Int,
                                          candidateCount: Int) -> BackgroundNetworkTempCleanupDisposition {
        guard candidateCount > 0 else { return .none }
        guard context != .reattach else { return .skipReattach }
        guard liveTaskCount == 0 else {
            return .skipLiveTasks(liveTaskCount: liveTaskCount)
        }
        return .deleteCandidates
    }

    /// Per-file age gate for `.deleteCandidates`: only temps old enough that no delegate
    /// delivery can still be pending are deletable. Unknown or negative (future-mtime) ages
    /// are protected.
    public static func shouldDeleteCFNetworkTemp(modificationAge: TimeInterval?) -> Bool {
        guard let modificationAge else { return false }
        return modificationAge >= minimumCFNetworkTempAge
    }
}
