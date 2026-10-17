import Foundation

/// What the P3b schema upgrade removed: in-progress downloads the maintainer decision did not
/// keep, and how many of those had a server job whose cleanup identity was unavailable. Stored as
/// attempt-ID sets so a pass repeated after a crash counts each deletion once.
public struct DownloadUpgradeNotice: Codable, Equatable, Sendable {
    public var retiredAttemptIDs: Set<String> = []
    public var cleanupGapAttemptIDs: Set<String> = []

    public var retiredCount: Int { retiredAttemptIDs.count }
    public var cleanupGapCount: Int { cleanupGapAttemptIDs.count }

    public var message: String {
        let rows = retiredCount == 1
            ? "1 in-progress download was" : "\(retiredCount) in-progress downloads were"
        var text = "\(rows) removed while updating the download library. Start them again to resume."
        if cleanupGapCount > 0 {
            text += cleanupGapCount == 1
                ? " One server job could not be cleaned up automatically."
                : " \(cleanupGapCount) server jobs could not be cleaned up automatically."
        }
        return text
    }

    static let fileName = "schema-upgrade-notice.json"

    /// Lives in the download authority directory beside the cleanup journal, written before the
    /// v5 stamp is enqueued: atomic replace, file fsync, directory fsync.
    static func load(from directory: URL) -> DownloadUpgradeNotice? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)),
              let notice = try? JSONDecoder().decode(DownloadUpgradeNotice.self, from: data),
              notice.retiredCount > 0 else { return nil }
        return notice
    }

    @discardableResult
    func save(to directory: URL) -> Bool {
        let url = directory.appendingPathComponent(Self.fileName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(self).write(to: url, options: .atomic)
            try DownloadPromotionFilesystem.live.fullSyncSource(url)
            try DownloadPromotionFilesystem.live.syncParentDirectory(url)
            return true
        } catch {
            return false
        }
    }

    static func clear(from directory: URL) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
    }
}
