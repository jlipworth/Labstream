import Foundation

/// Pure file-name/path classification for background-download temporary files.
///
/// The app layer owns filesystem reads and diagnostics. This policy pins the network-temp paths
/// included in diagnostics and the exact task ownership of app-created Range body stashes.
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

}
