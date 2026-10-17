import Foundation

/// A one-level file snapshot from the app's Offline downloads directory.
///
/// The app target owns the actual `FileManager` scan; this PMSKit type keeps the index-vs-directory
/// accounting and orphan-candidate policy testable without an app test target (#171).
public struct OfflineDownloadFileSnapshot: Equatable, Sendable {
    public var relativePath: String
    public var byteCount: Int

    public init(relativePath: String, byteCount: Int) {
        self.relativePath = relativePath
        self.byteCount = max(0, byteCount)
    }
}

public struct OfflineDownloadStorageAudit: Equatable, Sendable {
    public var referencedRelativePaths: Set<String>
    public var referencedBytes: Int
    public var directoryBytes: Int
    public var unreferencedFiles: [OfflineDownloadFileSnapshot]
    public var orphanCandidates: [OfflineDownloadFileSnapshot]

    /// Index and atomic-index temporary files are accounted for, but never media sweep candidates.
    public var infrastructureFiles: [OfflineDownloadFileSnapshot] {
        unreferencedFiles.filter { OfflineDownloadFileInventory.isInfrastructureFilename($0.relativePath) }
    }

    public var infrastructureBytes: Int { infrastructureFiles.reduce(0) { $0 + $1.byteCount } }

    public var unreferencedBytes: Int {
        unreferencedFiles.reduce(0) { $0 + $1.byteCount }
    }

    public var orphanCandidateBytes: Int {
        orphanCandidates.reduce(0) { $0 + $1.byteCount }
    }

    public init(referencedRelativePaths: Set<String>,
                referencedBytes: Int,
                directoryBytes: Int,
                unreferencedFiles: [OfflineDownloadFileSnapshot],
                orphanCandidates: [OfflineDownloadFileSnapshot]) {
        self.referencedRelativePaths = referencedRelativePaths
        self.referencedBytes = max(0, referencedBytes)
        self.directoryBytes = max(0, directoryBytes)
        self.unreferencedFiles = unreferencedFiles
        self.orphanCandidates = orphanCandidates
    }
}

public enum OfflineDownloadFileInventory {
    public static let indexFilename = "index.json"

    public static func referencedRelativePaths(mainRelativePaths: some Sequence<String>,
                                               metadata: some Sequence<OfflineMetadata?>) -> Set<String> {
        var referenced = Set<String>()
        for relative in mainRelativePaths {
            insertSafe(relative, into: &referenced)
        }
        for metadata in metadata {
            guard let metadata else { continue }
            for relative in sideAssetRelativePaths(metadata: metadata) {
                insertSafe(relative, into: &referenced)
            }
        }
        return referenced
    }

    public static func audit(directoryFiles: some Sequence<OfflineDownloadFileSnapshot>,
                             referencedRelativePaths: Set<String>,
                             inFlightRelativePaths: Set<String> = []) -> OfflineDownloadStorageAudit {
        var seen: Set<String> = []
        let files = directoryFiles
            .filter { isOneLevelRelativePath($0.relativePath) && seen.insert($0.relativePath).inserted }
            .sorted { lhs, rhs in lhs.relativePath < rhs.relativePath }
        let directoryBytes = files.reduce(0) { $0 + $1.byteCount }
        let referencedBytes = files.reduce(0) { total, file in
            referencedRelativePaths.contains(file.relativePath) ? total + file.byteCount : total
        }
        let unreferenced = files.filter { !referencedRelativePaths.contains($0.relativePath) }
        let candidates = unreferenced.filter {
            !inFlightRelativePaths.contains($0.relativePath)
                && !isInfrastructureFilename($0.relativePath)
                && isLabstreamOwnedDownloadFilename($0.relativePath)
        }
        return OfflineDownloadStorageAudit(referencedRelativePaths: referencedRelativePaths,
                                           referencedBytes: referencedBytes,
                                           directoryBytes: directoryBytes,
                                           unreferencedFiles: unreferenced,
                                           orphanCandidates: candidates)
    }

    public static func isInfrastructureFilename(_ path: String) -> Bool {
        if path == indexFilename || path.hasPrefix(".index.json.commit-") { return true }
        guard path.hasPrefix("."), let marker = path.range(of: ".commit-", options: .backwards),
              UUID(uuidString: String(path[marker.upperBound...])) != nil else { return false }
        return isGenerationResumeFilename(String(path[path.index(after: path.startIndex)..<marker.lowerBound]))
    }

    public static func isLabstreamOwnedDownloadFilename(_ relativePath: String) -> Bool {
        guard isOneLevelRelativePath(relativePath), relativePath != indexFilename else { return false }
        let stagingPrefix = ".attempt-stage-v1-"
        if relativePath.hasPrefix(stagingPrefix), relativePath.hasSuffix(".stage") {
            let digest = relativePath.dropFirst(stagingPrefix.count).dropLast(".stage".count)
            return digest.count == 64 && digest.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
        }
        if isGenerationResumeFilename(relativePath) { return true }
        if let marker = relativePath.range(of: ".checkpoint-", options: .backwards),
           relativePath.hasPrefix("..attempt-stage-v1-"),
           UUID(uuidString: String(relativePath[marker.upperBound...])) != nil {
            return isLabstreamOwnedDownloadFilename(String(relativePath[relativePath.index(after: relativePath.startIndex)..<marker.lowerBound]))
        }
        let mediaExtensions = ["avi", "m4v", "mkv", "mov", "mp4", "ts", "webm"]
        let subtitleExtensions = ["srt", "vtt"]
        let lowercased = relativePath.lowercased()

        if lowercased.hasSuffix(".resume")
            || lowercased.hasSuffix(".poster.jpg")
            || lowercased.hasSuffix(".plex-sd.bif")
            || lowercased.hasSuffix(".emby.bif")
            || lowercased.hasSuffix(".jf-trickplay.m3u8") {
            return safePrefix(beforeFirstDotIn: relativePath)
        }
        if relativePath.contains(".range-held-") {
            return safePrefix(beforeFirstDotIn: relativePath)
        }
        if matchesNumberedSuffix(relativePath, marker: ".chapter-", extension: "jpg")
            || matchesNumberedSuffix(relativePath, marker: ".jf-trickplay-", extension: "jpg") {
            return true
        }
        if subtitleExtensions.contains(where: { matchesNumberedSuffix(relativePath,
                                                                      marker: ".sub-",
                                                                      extension: $0) }) {
            return true
        }
        guard let ext = lowercased.split(separator: ".").last.map(String.init),
              mediaExtensions.contains(ext),
              relativePath.split(separator: ".").count == 2 else {
            return false
        }
        return safePrefix(beforeFirstDotIn: relativePath)
    }

    private static func isGenerationResumeFilename(_ path: String) -> Bool {
        guard safePrefix(beforeFirstDotIn: path), let marker = path.range(of: ".resume-") else { return false }
        let tail = path[marker.upperBound...]
        guard tail.count == 24 + 1 + 36 else { return false }
        let digest = tail.prefix(24)
        return digest.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
            && tail.dropFirst(24).first == "-" && UUID(uuidString: String(tail.suffix(36))) != nil
    }

    private static func sideAssetRelativePaths(metadata: OfflineMetadata) -> [String] {
        var relatives = [
            metadata.posterRelativePath,
            metadata.plexBIFRelativePath,
            metadata.embyBIFRelativePath,
            metadata.jellyfinTrickPlayPlaylistRelativePath,
            metadata.resumeDataRelativePath,
        ].compactMap { $0 }
        relatives.append(contentsOf: metadata.jellyfinTrickPlayTileRelativePaths ?? [])
        relatives.append(contentsOf: Array(metadata.chapterImageRelativePaths?.values ?? [:].values))
        relatives.append(contentsOf: metadata.offlineTextSubtitles?.map(\.relativePath) ?? [])
        relatives.append(contentsOf: metadata.heldRangeSegments?.map(\.relativePath) ?? [])
        return relatives
    }

    private static func insertSafe(_ relativePath: String, into set: inout Set<String>) {
        guard isOneLevelRelativePath(relativePath), !relativePath.isEmpty else { return }
        set.insert(relativePath)
    }

    private static func isOneLevelRelativePath(_ relativePath: String) -> Bool {
        !relativePath.isEmpty
            && !relativePath.contains("/")
            && !relativePath.contains("\\")
            && relativePath != "."
            && relativePath != ".."
    }

    private static func matchesNumberedSuffix(_ relativePath: String,
                                              marker: String,
                                              extension wantedExtension: String) -> Bool {
        guard safePrefix(beforeFirstDotIn: relativePath),
              let markerRange = relativePath.range(of: marker),
              relativePath.lowercased().hasSuffix(".\(wantedExtension)") else {
            return false
        }
        let numberStart = markerRange.upperBound
        let numberEnd = relativePath.index(relativePath.endIndex,
                                           offsetBy: -wantedExtension.count - 1)
        guard numberStart < numberEnd else { return false }
        let number = relativePath[numberStart..<numberEnd]
        return !number.isEmpty && number.allSatisfy(\.isNumber)
    }

    private static func safePrefix(beforeFirstDotIn relativePath: String) -> Bool {
        guard let dot = relativePath.firstIndex(of: ".") else { return false }
        let prefix = relativePath[..<dot]
        guard !prefix.isEmpty else { return false }
        return prefix.allSatisfy { char in
            char.isLetter || char.isNumber || char == "-" || char == "_"
        }
    }
}
