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

    static let defaultsKey = "downloads.schemaUpgradeNotice"

    static func load(_ defaults: UserDefaults = .standard) -> DownloadUpgradeNotice? {
        guard let data = defaults.data(forKey: defaultsKey),
              let notice = try? JSONDecoder().decode(DownloadUpgradeNotice.self, from: data),
              notice.retiredCount > 0 else { return nil }
        return notice
    }

    func save(_ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    static func clear(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
