import Foundation
import PlexKit

/// One persisted, identifiable offline download.
///
/// `localURL` is stored as a path RELATIVE to Application Support and re-resolved
/// against the current container on load: the sandbox container path is *not*
/// stable across installs/devices, so persisting an absolute URL would dangle.
/// `progress` is 0...1 and `bytes` is the transferred byte count; both are
/// updated live by `DownloadManager` from the background-session delegate.
public struct DownloadRecord: Identifiable, Codable, Sendable, Equatable {
    public let ratingKey: String
    public let title: String
    public let localURL: URL
    public var bytes: Int
    public var progress: Double

    public var id: String { ratingKey }

    public init(ratingKey: String,
                title: String,
                localURL: URL,
                bytes: Int = 0,
                progress: Double = 0) {
        self.ratingKey = ratingKey
        self.title = title
        self.localURL = localURL
        self.bytes = bytes
        self.progress = progress
    }
}

/// Persisted index of `ratingKey -> local file` for offline content.
///
/// The on-disk JSON stores the file's path *relative* to the Application Support
/// directory (`relativePath`); `records` re-hydrates absolute `localURL`s against
/// the live container at load time so a moved sandbox doesn't orphan files.
///
/// This is a plain (non-actor) class guarded by an internal lock; `DownloadManager`
/// is the only writer and drives it from the `@MainActor`, but the background
/// `URLSession` delegate can call in from a delegate queue, so writes are locked.
final class DownloadStore: @unchecked Sendable {

    /// Codable row as persisted on disk (relative path, not absolute URL).
    private struct Row: Codable {
        let ratingKey: String
        let title: String
        let relativePath: String
        var bytes: Int
        var progress: Double
    }

    private let lock = NSLock()
    private var rows: [String: Row] = [:]          // ratingKey -> Row
    private let baseDirectory: URL                  // Application Support/Downloads
    private let indexURL: URL                        // baseDirectory/index.json
    private let fileManager: FileManager

    /// - Parameter baseDirectory: where media files + the index live. Defaults to
    ///   `Application Support/PlexAVPApp/Downloads`, created if missing.
    init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let appSupport = (try? fileManager.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil,
                                                create: true))
            ?? fileManager.temporaryDirectory
        let dir = baseDirectory ?? appSupport
            .appendingPathComponent("PlexAVPApp", isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
        self.baseDirectory = dir
        self.indexURL = dir.appendingPathComponent("index.json")
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        // Exclude the offline cache from iCloud/device backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDir = self.baseDirectory
        try? mutableDir.setResourceValues(values)
        load()
    }

    /// The directory media files should be written into.
    var directory: URL { baseDirectory }

    /// Build the on-disk destination for a given ratingKey + container extension.
    func destinationURL(ratingKey: String, ext: String) -> URL {
        let safeExt = ext.isEmpty ? "mp4" : ext
        return baseDirectory.appendingPathComponent("\(ratingKey).\(safeExt)")
    }

    /// Current records, absolute URLs re-resolved against the live container.
    var records: [DownloadRecord] {
        lock.lock(); defer { lock.unlock() }
        return rows.values
            .map { row in
                DownloadRecord(ratingKey: row.ratingKey,
                               title: row.title,
                               localURL: baseDirectory.appendingPathComponent(row.relativePath),
                               bytes: row.bytes,
                               progress: row.progress)
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Absolute local URL for a completed (or in-progress) download, if indexed
    /// AND the file is present on disk.
    func localURL(for ratingKey: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard let row = rows[ratingKey] else { return nil }
        let url = baseDirectory.appendingPathComponent(row.relativePath)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Insert/replace a record. `localURL` must live under `baseDirectory`.
    func upsert(_ record: DownloadRecord) {
        lock.lock()
        let rel = record.localURL.lastPathComponent
        rows[record.ratingKey] = Row(ratingKey: record.ratingKey,
                                     title: record.title,
                                     relativePath: rel,
                                     bytes: record.bytes,
                                     progress: record.progress)
        lock.unlock()
        persist()
    }

    /// Update transfer progress for an in-flight download.
    func updateProgress(ratingKey: String, bytes: Int, progress: Double) {
        lock.lock()
        guard var row = rows[ratingKey] else { lock.unlock(); return }
        row.bytes = bytes
        row.progress = progress
        rows[ratingKey] = row
        lock.unlock()
        persist()
    }

    /// Remove a record and delete its backing file.
    func remove(ratingKey: String) {
        lock.lock()
        let row = rows.removeValue(forKey: ratingKey)
        lock.unlock()
        if let row {
            let url = baseDirectory.appendingPathComponent(row.relativePath)
            try? fileManager.removeItem(at: url)
        }
        persist()
    }

    // MARK: - Persistence

    private func load() {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([Row].self, from: data) else { return }
        rows = Dictionary(uniqueKeysWithValues: decoded.map { ($0.ratingKey, $0) })
    }

    private func persist() {
        lock.lock()
        let snapshot = Array(rows.values)
        lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
