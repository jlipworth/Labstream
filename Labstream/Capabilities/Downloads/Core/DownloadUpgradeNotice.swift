import Foundation
import PMSKit

/// What the P3b schema upgrade removed: in-progress downloads the maintainer decision did not
/// keep, and how many of those had a server job whose cleanup identity was unavailable. Stored as
/// sets of full attempt keys so a pass repeated after a crash counts each deletion once.
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
    static let fallbackDefaultsKey = "downloads.schemaUpgradeNoticeFallback"

    /// One notice entry: the exact attempt (rating key and attempt ID).
    static func entry(for key: DownloadAttemptKey) -> String {
        "\(key.ratingKey)\u{1F}\(key.attemptID.rawValue)"
    }

    /// Lives in the download authority directory beside the cleanup journal, written before the
    /// v5 stamp is enqueued: atomic replace, file fsync, directory fsync.
    /// The durable file merged with any fallback a failed save left behind.
    static func load(from directory: URL,
                     fallback defaults: UserDefaults = .standard) -> DownloadUpgradeNotice? {
        var notice = (try? Data(contentsOf: directory.appendingPathComponent(fileName)))
            .flatMap { try? JSONDecoder().decode(DownloadUpgradeNotice.self, from: $0) }
            ?? DownloadUpgradeNotice()
        if let data = defaults.data(forKey: fallbackDefaultsKey),
           let pending = try? JSONDecoder().decode(DownloadUpgradeNotice.self, from: data) {
            notice.retiredAttemptIDs.formUnion(pending.retiredAttemptIDs)
            notice.cleanupGapAttemptIDs.formUnion(pending.cleanupGapAttemptIDs)
        }
        return notice.retiredCount > 0 ? notice : nil
    }

    /// Best-effort carrier for entries whose durable save failed; merged by the next `load`.
    func saveFallback(_ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.fallbackDefaultsKey)
    }

    static func clearFallback(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: fallbackDefaultsKey)
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
        clearFallback()
    }
}
