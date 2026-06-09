import Foundation
import PlexKit

/// Explicit lifecycle state for a download, persisted so a relaunch can tell a
/// FINISHED transfer from a STALLED one. Previously completion was inferred from
/// `progress >= 1.0`, which can't distinguish a job that died mid-flight (the
/// progress just freezes) from one that genuinely finished — see D2 in research/14.
public enum DownloadStatus: String, Codable, Sendable, Equatable {
    case queued        // seeded, transfer not yet started / no live task yet
    case downloading   // a background task is actively writing bytes
    case complete      // validated file is on disk and playable
    case failed        // transfer or validation failed; row kept so it can be retried
}

/// A Codable snapshot of the source `MediaItem` (plus the chosen download quality)
/// taken at enqueue time (D5).
///
/// Stored on each row so the offline library renders richly WITHOUT the server
/// (title, year, type, runtime, summary, content rating, tagline) and so `retry()`
/// + offline playback can reconstruct a faithful `MediaItem` instead of fabricating
/// a minimal movie. Every field beyond `ratingKey`/`title`/`type` is optional and
/// decoded with `decodeIfPresent`, and the whole snapshot is itself decoded with
/// `decodeIfPresent` on the row, so libraries persisted before D5 keep loading.
///
/// `posterRelativePath` is the locally-cached poster file's path RELATIVE to the
/// Downloads base directory (same convention as `relativePath`), so a moved sandbox
/// container doesn't orphan it. `nil` when no poster was cached.
public struct OfflineMetadata: Codable, Sendable, Equatable {
    public var ratingKey: String
    public var key: String?
    public var title: String
    public var type: String
    public var year: Int?
    public var duration: Int?
    public var viewOffset: Int?
    public var viewCount: Int?
    public var summary: String?
    public var contentRating: String?
    public var tagline: String?
    /// The original Plex `thumb` path, kept so we can re-fetch the poster if the
    /// local cache is missing and the server is reachable again.
    public var thumb: String?
    /// The original Plex `art` (backdrop) path.
    public var art: String?
    /// The quality the user chose at enqueue time, so `retry()` re-runs at the SAME
    /// cap rather than always defaulting to 1080p. Stored as the enum raw value.
    public var quality: String?
    public var mediaIndex: Int?
    public var partIndex: Int?
    /// Locally-cached poster path, relative to the Downloads base directory.
    public var posterRelativePath: String?

    public init(ratingKey: String,
                key: String? = nil,
                title: String,
                type: String,
                year: Int? = nil,
                duration: Int? = nil,
                viewOffset: Int? = nil,
                viewCount: Int? = nil,
                summary: String? = nil,
                contentRating: String? = nil,
                tagline: String? = nil,
                thumb: String? = nil,
                art: String? = nil,
                quality: String? = nil,
                mediaIndex: Int? = nil,
                partIndex: Int? = nil,
                posterRelativePath: String? = nil) {
        self.ratingKey = ratingKey
        self.key = key
        self.title = title
        self.type = type
        self.year = year
        self.duration = duration
        self.viewOffset = viewOffset
        self.viewCount = viewCount
        self.summary = summary
        self.contentRating = contentRating
        self.tagline = tagline
        self.thumb = thumb
        self.art = art
        self.quality = quality
        self.mediaIndex = mediaIndex
        self.partIndex = partIndex
        self.posterRelativePath = posterRelativePath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ratingKey = try c.decode(String.self, forKey: .ratingKey)
        title = try c.decode(String.self, forKey: .title)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "movie"
        key = try c.decodeIfPresent(String.self, forKey: .key)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        duration = try c.decodeIfPresent(Int.self, forKey: .duration)
        viewOffset = try c.decodeIfPresent(Int.self, forKey: .viewOffset)
        viewCount = try c.decodeIfPresent(Int.self, forKey: .viewCount)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        contentRating = try c.decodeIfPresent(String.self, forKey: .contentRating)
        tagline = try c.decodeIfPresent(String.self, forKey: .tagline)
        thumb = try c.decodeIfPresent(String.self, forKey: .thumb)
        art = try c.decodeIfPresent(String.self, forKey: .art)
        quality = try c.decodeIfPresent(String.self, forKey: .quality)
        mediaIndex = try c.decodeIfPresent(Int.self, forKey: .mediaIndex)
        partIndex = try c.decodeIfPresent(Int.self, forKey: .partIndex)
        posterRelativePath = try c.decodeIfPresent(String.self, forKey: .posterRelativePath)
    }

    /// Reconstruct a faithful `MediaItem` for offline playback + retry. Only the
    /// fields we captured are populated; stream-level metadata isn't needed offline.
    public func makeMediaItem() -> MediaItem {
        MediaItem(ratingKey: ratingKey,
                  key: key,
                  title: title,
                  type: type,
                  duration: duration,
                  viewOffset: viewOffset,
                  viewCount: viewCount,
                  year: year,
                  summary: summary,
                  thumb: thumb,
                  art: art,
                  contentRating: contentRating,
                  tagline: tagline)
    }
}

/// One persisted, identifiable offline download.
///
/// `localURL` is stored as a path RELATIVE to Application Support and re-resolved
/// against the current container on load: the sandbox container path is *not*
/// stable across installs/devices, so persisting an absolute URL would dangle.
/// `progress` is 0...1 and `bytes` is the transferred byte count; both are
/// updated live by `DownloadManager` from the background-session delegate.
/// `status` is the authoritative lifecycle flag the UI drives off of (D2).
/// `metadata` is the D5 snapshot of the source item (nil for rows persisted before
/// D5); `posterURL` is the re-resolved absolute path to the cached poster, if any.
public struct DownloadRecord: Identifiable, Codable, Sendable, Equatable {
    public let ratingKey: String
    public let title: String
    public let localURL: URL
    public var bytes: Int
    public var progress: Double
    public var status: DownloadStatus
    public var metadata: OfflineMetadata?
    public var posterURL: URL?

    public var id: String { ratingKey }

    /// Convenience: a download is usable only when explicitly marked complete.
    /// Drives the player gate so a stalled-at-100% row never opens an empty file.
    public var isComplete: Bool { status == .complete }

    public init(ratingKey: String,
                title: String,
                localURL: URL,
                bytes: Int = 0,
                progress: Double = 0,
                status: DownloadStatus = .queued,
                metadata: OfflineMetadata? = nil,
                posterURL: URL? = nil) {
        self.ratingKey = ratingKey
        self.title = title
        self.localURL = localURL
        self.bytes = bytes
        self.progress = progress
        self.status = status
        self.metadata = metadata
        self.posterURL = posterURL
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
        var status: DownloadStatus
        // D5: snapshot of the source item + the locally-cached poster path. Both are
        // optional and decoded with `decodeIfPresent` so rows written before D5 load.
        var metadata: OfflineMetadata?

        // Backward-compatible decoding: rows written before D2 lack `status`.
        // Infer it from the old progress signal so existing libraries keep
        // working — a finished-looking row maps to `.complete`, anything else
        // to `.queued` (launch reconciliation then re-checks it against disk).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ratingKey = try c.decode(String.self, forKey: .ratingKey)
            title = try c.decode(String.self, forKey: .title)
            relativePath = try c.decode(String.self, forKey: .relativePath)
            bytes = try c.decode(Int.self, forKey: .bytes)
            progress = try c.decode(Double.self, forKey: .progress)
            status = try c.decodeIfPresent(DownloadStatus.self, forKey: .status)
                ?? (progress >= 1.0 ? .complete : .queued)
            metadata = try c.decodeIfPresent(OfflineMetadata.self, forKey: .metadata)
        }

        init(ratingKey: String, title: String, relativePath: String,
             bytes: Int, progress: Double, status: DownloadStatus,
             metadata: OfflineMetadata? = nil) {
            self.ratingKey = ratingKey
            self.title = title
            self.relativePath = relativePath
            self.bytes = bytes
            self.progress = progress
            self.status = status
            self.metadata = metadata
        }
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
        let safeRatingKey = Self.safeFilenameComponent(ratingKey)
        let safeExt = Self.safeExtension(ext)
        return baseDirectory.appendingPathComponent("\(safeRatingKey).\(safeExt)")
    }

    private static func safeFilenameComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let result = String(scalars)
        return result.isEmpty ? UUID().uuidString : result
    }

    private static func safeExtension(_ value: String) -> String {
        let lowered = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let allowed: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "ts", "webm"]
        let alnum = lowered.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
        return alnum && allowed.contains(lowered) ? lowered : "mp4"
    }

    /// Build the on-disk destination for a ratingKey's cached poster (D5). Kept as a
    /// sibling of the media file so `remove` (which deletes the whole base dir entry)
    /// and the relative-path convention both apply uniformly.
    func posterDestinationURL(ratingKey: String) -> URL {
        baseDirectory.appendingPathComponent("\(Self.safeFilenameComponent(ratingKey)).poster.jpg")
    }

    /// Re-resolve a stored relative poster path to an absolute URL that exists on disk.
    private func resolvedPosterURL(_ relative: String?) -> URL? {
        guard let relative, !relative.isEmpty else { return nil }
        let url = baseDirectory.appendingPathComponent(relative)
        return fileManager.fileExists(atPath: url.path) ? url : nil
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
                               progress: row.progress,
                               status: row.status,
                               metadata: row.metadata,
                               posterURL: resolvedPosterURL(row.metadata?.posterRelativePath))
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Absolute local URL for a completed download, if indexed AND present on disk.
    func localURL(for ratingKey: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard let row = rows[ratingKey], row.status == .complete else { return nil }
        let url = baseDirectory.appendingPathComponent(row.relativePath)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Insert/replace a record. `localURL` must live under `baseDirectory`.
    ///
    /// D5: preserves an already-stored `metadata` snapshot if the incoming record
    /// doesn't carry one — the pipeline upserts the same row several times (seed,
    /// then with the resolved destination) and we don't want a later, leaner upsert
    /// to wipe the metadata/poster captured earlier.
    func upsert(_ record: DownloadRecord) {
        lock.lock()
        let rel = record.localURL.lastPathComponent
        let existing = rows[record.ratingKey]
        rows[record.ratingKey] = Row(ratingKey: record.ratingKey,
                                     title: record.title,
                                     relativePath: rel,
                                     bytes: record.bytes,
                                     progress: record.progress,
                                     status: record.status,
                                     metadata: record.metadata ?? existing?.metadata)
        lock.unlock()
        persist()
    }

    /// Record the locally-cached poster path (relative to the base dir) on a row's
    /// metadata snapshot (D5). No-op if the row or its metadata is gone — a missing
    /// poster is never a download failure.
    func setPosterRelativePath(ratingKey: String, _ relativePath: String) {
        lock.lock()
        guard var row = rows[ratingKey], var meta = row.metadata else { lock.unlock(); return }
        meta.posterRelativePath = relativePath
        row.metadata = meta
        rows[ratingKey] = row
        lock.unlock()
        persist()
    }

    /// Update transfer progress for an in-flight download. Moving any bytes means
    /// the transfer is live, so we promote a `.queued` row to `.downloading` here
    /// (D2: the UI distinguishes "waiting on server" from "actively transferring").
    func updateProgress(ratingKey: String, bytes: Int, progress: Double) {
        lock.lock()
        guard var row = rows[ratingKey] else { lock.unlock(); return }
        row.bytes = bytes
        row.progress = progress
        if row.status == .queued { row.status = .downloading }
        rows[ratingKey] = row
        lock.unlock()
        persist()
    }

    /// Set the explicit lifecycle status for a row (D2). No-op if the row is gone.
    func setStatus(ratingKey: String, _ status: DownloadStatus) {
        lock.lock()
        guard var row = rows[ratingKey] else { lock.unlock(); return }
        row.status = status
        rows[ratingKey] = row
        lock.unlock()
        persist()
    }

    /// Reconcile persisted rows against disk at launch (D2).
    ///
    /// A row left `.queued`/`.downloading` from a previous run whose task did NOT
    /// survive relaunch can't be trusted: it was never validated/marked `.complete`,
    /// so even a file on disk may be partial. We mark such rows `.failed` (retryable)
    /// rather than letting the UI spin forever on a dead transfer. A `.complete` row
    /// whose file has since vanished is likewise demoted to `.failed`. `liveRatingKeys`
    /// are the ratingKeys the background session reattached to — genuinely still in
    /// flight and left untouched.
    func reconcile(liveRatingKeys: Set<String>) {
        lock.lock()
        var changed = false
        for (key, var row) in rows {
            switch row.status {
            case .complete:
                // A completed row is only usable if its validated file still exists.
                let fileExists = fileManager.fileExists(
                    atPath: baseDirectory.appendingPathComponent(row.relativePath).path)
                if !fileExists { row.status = .failed; rows[key] = row; changed = true }
            case .queued, .downloading:
                if liveRatingKeys.contains(key) { continue }   // task survived; leave it
                // No live task and never validated -> can't trust it; make it retryable.
                row.status = .failed; rows[key] = row; changed = true
            case .failed:
                continue
            }
        }
        lock.unlock()
        if changed { persist() }
    }

    /// Remove a record and delete its backing file.
    func remove(ratingKey: String) {
        lock.lock()
        let row = rows.removeValue(forKey: ratingKey)
        lock.unlock()
        if let row {
            let url = baseDirectory.appendingPathComponent(row.relativePath)
            try? fileManager.removeItem(at: url)
            // D5: also delete the cached poster so a removed download leaves nothing behind.
            if let poster = row.metadata?.posterRelativePath, !poster.isEmpty {
                try? fileManager.removeItem(at: baseDirectory.appendingPathComponent(poster))
            }
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
