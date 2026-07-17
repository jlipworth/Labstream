import Foundation

/// Crash-durable sibling-temp publication for resume blobs. The shared low-level committer writes
/// mode 0600, applies auth-artifact protection/backup exclusion, full-syncs file contents, renames
/// atomically, and fsyncs the containing directory before returning.
struct DownloadArtifactFileCommitter: Sendable {
    private let durableCommitter: DownloadIndexFileCommitter

    init(durableCommitter: DownloadIndexFileCommitter = .init()) {
        self.durableCommitter = durableCommitter
    }

    func commit(_ data: Data, to destination: URL) throws {
        try durableCommitter.commit(data, to: destination)
    }

    /// Startup-only orphan collection independent of row intents. A first relaunch may retire a
    /// prepared intent while its just-created sibling temp is still inside the live-writer safety
    /// window; a later launch must still be able to recognize and age-collect that temp.
    static func cleanupAbandonedResumeTemps(
        in directory: URL,
        olderThan cutoff: Date = Date().addingTimeInterval(-3_600),
        fileManager: FileManager = .default
    ) throws {
        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [])
        for child in children where isGenerationPrivateResumeCommitTemp(child.lastPathComponent) {
            let modified = try child.resourceValues(
                forKeys: [.contentModificationDateKey]).contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try fileManager.removeItem(at: child)
        }
    }

    private static func isGenerationPrivateResumeCommitTemp(_ name: String) -> Bool {
        guard name.first == ".",
              let commitRange = name.range(of: ".commit-", options: .backwards),
              UUID(uuidString: String(name[commitRange.upperBound...])) != nil else { return false }
        let destination = String(name[name.index(after: name.startIndex)..<commitRange.lowerBound])
        guard let marker = destination.range(of: ".resume-", options: .backwards) else {
            return false
        }
        let generation = String(destination[marker.upperBound...])
        let parts = generation.split(separator: "-", maxSplits: 1).map(String.init)
        let ratingComponent = destination[..<marker.lowerBound]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard parts.count == 2,
              parts[0].count == 24,
              parts[0].allSatisfy({ $0.isHexDigit }),
              UUID(uuidString: parts[1]) != nil,
              !ratingComponent.isEmpty,
              ratingComponent.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return false
        }
        return true
    }
}
