import Foundation
import PMSKit

// `DownloadStatus`, `OfflineMetadata`, and `DownloadRecord` — the pure, Codable value
// types persisted on each offline row, plus the `reconciledStatus` transition table —
// live in PMSKit (`Downloads/OfflineDownloadModels.swift`) so the silent-data-loss-on-
// upgrade surface is testable without an app test target.

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
                ?? DownloadStatus.migratedStatus(forLegacyProgress: progress)
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

    /// Minimum spacing between index rewrites driven by progress callbacks.
    private static let progressPersistInterval: TimeInterval = 1

    private let lock = NSLock()
    private var rows: [String: Row] = [:]          // ratingKey -> Row
    private var lastProgressPersist = Date.distantPast   // guarded by `lock`
    private let baseDirectory: URL                  // Application Support/Downloads
    private let indexURL: URL                        // baseDirectory/index.json
    private let fileManager: FileManager

    /// - Parameter baseDirectory: where media files + the index live. Defaults to
    ///   `Application Support/VisionPlay/Downloads`, created if missing.
    init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let appSupport = (try? fileManager.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil,
                                                create: true))
            ?? fileManager.temporaryDirectory
        let dir = baseDirectory ?? appSupport
            .appendingPathComponent("VisionPlay", isDirectory: true)
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

    private static func safeSubtitleExtension(_ value: String) -> String {
        let lowered = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let allowed: Set<String> = ["srt", "vtt"]
        let alnum = lowered.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
        return alnum && allowed.contains(lowered) ? lowered : "vtt"
    }

    /// Build the on-disk destination for a ratingKey's cached poster (D5). Kept as a
    /// sibling of the media file so `remove` (which deletes the whole base dir entry)
    /// and the relative-path convention both apply uniformly.
    func posterDestinationURL(ratingKey: String) -> URL {
        baseDirectory.appendingPathComponent("\(Self.safeFilenameComponent(ratingKey)).poster.jpg")
    }

    /// Build the on-disk destination for a ratingKey's cached Plex BIF trick-play index (#78).
    func plexBIFDestinationURL(ratingKey: String) -> URL {
        baseDirectory.appendingPathComponent("\(Self.safeFilenameComponent(ratingKey)).plex-sd.bif")
    }

    func jellyfinTrickPlayPlaylistDestinationURL(ratingKey: String) -> URL {
        baseDirectory.appendingPathComponent("\(Self.safeFilenameComponent(ratingKey)).jf-trickplay.m3u8")
    }

    func jellyfinTrickPlayTileDestinationURL(ratingKey: String, index: Int) -> URL {
        baseDirectory.appendingPathComponent("\(Self.safeFilenameComponent(ratingKey)).jf-trickplay-\(index).jpg")
    }

    func textSubtitleDestinationURL(ratingKey: String, streamID: Int, ext: String) -> URL {
        baseDirectory.appendingPathComponent("\(Self.safeFilenameComponent(ratingKey)).sub-\(streamID).\(Self.safeSubtitleExtension(ext))")
    }

    /// Re-resolve a stored relative cache path to an absolute URL that exists on disk.
    private func resolvedDownloadAssetURL(_ relative: String?) -> URL? {
        guard let relative, !relative.isEmpty else { return nil }
        let url = baseDirectory.appendingPathComponent(relative)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Current records, absolute URLs re-resolved against the live container.
    ///
    /// Snapshot the rows under the lock, then do the poster `fileExists` resolution
    /// OUTSIDE the lock — stat'ing each poster file while holding the store lock
    /// serialized every reader behind disk I/O on this hot path.
    var records: [DownloadRecord] {
        lock.lock()
        let snapshot = Array(rows.values)
        lock.unlock()
        return snapshot
            .map { row in
                DownloadRecord(ratingKey: row.ratingKey,
                               title: row.title,
                               localURL: baseDirectory.appendingPathComponent(row.relativePath),
                               bytes: row.bytes,
                               progress: row.progress,
                               status: row.status,
                               metadata: row.metadata,
                               posterURL: resolvedDownloadAssetURL(row.metadata?.posterRelativePath),
                               plexBIFURL: resolvedDownloadAssetURL(row.metadata?.plexBIFRelativePath),
                               jellyfinTrickPlayPlaylistURL: resolvedDownloadAssetURL(row.metadata?.jellyfinTrickPlayPlaylistRelativePath),
                               sideAssetBytes: sideAssetBytes(for: row.metadata))
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// The set of indexed ratingKeys, WITHOUT touching the filesystem. Use this when
    /// you only need to test membership (e.g. reattach matching) and don't want the
    /// per-row poster `fileExists` cost that `records` pays.
    var allRatingKeys: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(rows.keys)
    }

    /// Absolute destinations for indexed rows, regardless of status. Used when rebinding
    /// background URLSession tasks after relaunch: the persisted row knows the real extension
    /// (`.mp4`, `.mkv`, etc.), while a resumed task URL may not carry enough information.
    var destinationsByRatingKey: [String: URL] {
        lock.lock(); defer { lock.unlock() }
        return rows.mapValues { baseDirectory.appendingPathComponent($0.relativePath) }
    }

    /// Absolute local URL for a completed download, if indexed AND present on disk.
    func localURL(for ratingKey: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard let row = rows[ratingKey], row.status == .complete else { return nil }
        let url = baseDirectory.appendingPathComponent(row.relativePath)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Absolute local Plex BIF cache URL for a completed download, if present on disk.
    func plexBIFURL(for ratingKey: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard let row = rows[ratingKey], row.status == .complete else { return nil }
        return resolvedDownloadAssetURL(row.metadata?.plexBIFRelativePath)
    }

    /// Absolute local Jellyfin trickplay playlist URL for a completed download, if present on disk.
    func jellyfinTrickPlayPlaylistURL(for ratingKey: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard let row = rows[ratingKey], row.status == .complete else { return nil }
        return resolvedDownloadAssetURL(row.metadata?.jellyfinTrickPlayPlaylistRelativePath)
    }

    private func sideAssetBytes(for metadata: OfflineMetadata?) -> Int {
        guard let metadata else { return 0 }
        var relatives: [String] = []
        relatives.append(contentsOf: [
            metadata.posterRelativePath,
            metadata.plexBIFRelativePath,
            metadata.jellyfinTrickPlayPlaylistRelativePath,
        ].compactMap { $0 })
        relatives.append(contentsOf: metadata.jellyfinTrickPlayTileRelativePaths ?? [])
        relatives.append(contentsOf: metadata.offlineTextSubtitles?.map(\.relativePath) ?? [])
        return relatives.reduce(0) { total, relative in
            guard !relative.isEmpty else { return total }
            let url = baseDirectory.appendingPathComponent(relative)
            let attrs = try? fileManager.attributesOfItem(atPath: url.path)
            return total + ((attrs?[.size] as? NSNumber)?.intValue ?? 0)
        }
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
        updateMetadata(ratingKey: ratingKey) { $0.posterRelativePath = relativePath }
    }

    /// Record the locally-cached Plex BIF path (relative to the base dir) on a row's
    /// metadata snapshot (#78). No-op if the row or metadata is gone.
    func setPlexBIFRelativePath(ratingKey: String, _ relativePath: String) {
        updateMetadata(ratingKey: ratingKey) { $0.plexBIFRelativePath = relativePath }
    }

    /// Record locally-cached Jellyfin trickplay assets (#79). Relative paths only; the playlist
    /// itself is sanitized before writing, so no token-bearing URLs are persisted.
    func setJellyfinTrickPlayRelativePaths(ratingKey: String, playlist: String, tiles: [String]) {
        updateMetadata(ratingKey: ratingKey) {
            $0.jellyfinTrickPlayPlaylistRelativePath = playlist
            $0.jellyfinTrickPlayTileRelativePaths = tiles
        }
    }

    func setOfflineTextSubtitles(ratingKey: String, _ tracks: [OfflineTextSubtitleTrack]) {
        guard !tracks.isEmpty else { return }
        updateMetadata(ratingKey: ratingKey) { $0.offlineTextSubtitles = tracks }
    }

    private func updateMetadata(ratingKey: String, mutate: (inout OfflineMetadata) -> Void) {
        lock.lock()
        guard var row = rows[ratingKey], var meta = row.metadata else { lock.unlock(); return }
        mutate(&meta)
        row.metadata = meta
        rows[ratingKey] = row
        lock.unlock()
        persist()
    }

    /// Update transfer progress for an in-flight download. Moving any bytes means
    /// the transfer is live, so we promote a `.queued` row to `.downloading` here
    /// (D2: the UI distinguishes "waiting on server" from "actively transferring").
    ///
    /// Disk writes are throttled: the in-memory row updates on every callback (the
    /// UI reads live progress from `records`), but the JSON index is rewritten at
    /// most once per second. The session delegate fires `didWriteData` many times a
    /// second on fast transfers, and re-encoding the index each time thrashes I/O
    /// for no benefit — stale persisted progress is harmless because `reconcile`
    /// distrusts any non-live `.downloading` row at relaunch anyway, and the
    /// terminal `setStatus` always persists.
    func updateProgress(ratingKey: String, bytes: Int, progress: Double) {
        lock.lock()
        guard var row = rows[ratingKey] else { lock.unlock(); return }
        row.bytes = bytes
        row.progress = progress
        var statusChanged = false
        if row.status == .queued { row.status = .downloading; statusChanged = true }
        rows[ratingKey] = row
        let now = Date()
        let shouldPersist = statusChanged
            || now.timeIntervalSince(lastProgressPersist) >= Self.progressPersistInterval
        if shouldPersist { lastProgressPersist = now }
        lock.unlock()
        if shouldPersist { persist() }
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
    /// survive relaunch can't usually be trusted: it was never validated/marked
    /// `.complete`, so even a file on disk may be partial. We mark such rows `.failed`
    /// (retryable) rather than letting the UI spin forever on a dead transfer.
    ///
    /// Plex optimized/download-prep rows are the exception: Plex may still be
    /// rendering the compatible file and the app must resume polling after relaunch.
    /// We reset their local transfer counters and keep them `.queued`; any partial
    /// local file is removed so the eventual compatible part starts from a clean
    /// download. Jellyfin optimized rows are NOT server-prep rows: they stream from a
    /// live URLSession task, so if that task is gone they must stay retryable-failed.
    ///
    /// A `.complete` row whose file has since vanished is likewise demoted to `.failed`.
    /// `liveRatingKeys` are the ratingKeys the background session reattached to —
    /// genuinely still in flight and left untouched.
    func reconcile(liveRatingKeys: Set<String>) {
        lock.lock()
        var changed = false
        for (key, var row) in rows {
            let hasLiveTask = liveRatingKeys.contains(key)
            let fileExists = fileManager.fileExists(
                atPath: baseDirectory.appendingPathComponent(row.relativePath).path)
            // Only Plex has a server-side "prepare then static download" optimize queue that can
            // resume after relaunch. Jellyfin AND Emby transcoded rows are LIVE streams from a
            // URLSession task (Emby additionally renders via a server FFmpeg encoder), so a
            // missing task means the render is gone — they must demote to retryable `.failed`, not
            // resume as `.queued`. Hence both backend prefixes are excluded here.
            let isPlexServerPrepOptimizedJob = !hasLiveTask
                && (row.status == .queued || row.status == .downloading)
                && row.metadata?.optimizeTargetName?.isEmpty == false
                && !row.ratingKey.hasPrefix("jellyfin:")
                && !row.ratingKey.hasPrefix("emby:")
            let newStatus = isPlexServerPrepOptimizedJob
                ? .queued
                : DownloadStatus.reconciledStatus(
                    current: row.status, fileExists: fileExists, hasLiveTask: hasLiveTask)
            let shouldResetOptimizedProgress = isPlexServerPrepOptimizedJob
                && (row.bytes != 0 || row.progress != 0)
            guard newStatus != row.status || shouldResetOptimizedProgress else { continue }
            // A non-live queued/downloading row that we're demoting to `.failed` may
            // have left a partial file behind. Delete it so dead bytes don't sit
            // invisibly on disk — a retry rebuilds the file from scratch regardless.
            if (row.status == .queued || row.status == .downloading) && !hasLiveTask {
                try? fileManager.removeItem(
                    at: baseDirectory.appendingPathComponent(row.relativePath))
            }
            row.status = newStatus
            if isPlexServerPrepOptimizedJob {
                row.bytes = 0
                row.progress = 0
            }
            rows[key] = row
            changed = true
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
            // The row is already gone from the index, so a failed delete would
            // permanently orphan the file — log it rather than vanish silently.
            do { try fileManager.removeItem(at: url) }
            catch where fileManager.fileExists(atPath: url.path) {
                NSLog("DownloadStore: failed to delete media for %@ (%@); file orphaned at %@",
                      ratingKey, String(describing: error), url.path)
            } catch {} // already absent — nothing to clean up
            // D5/#78: also delete cached side assets so a removed download leaves nothing behind.
            var assets = [row.metadata?.posterRelativePath,
                          row.metadata?.plexBIFRelativePath,
                          row.metadata?.jellyfinTrickPlayPlaylistRelativePath].compactMap { $0 }
            assets.append(contentsOf: row.metadata?.jellyfinTrickPlayTileRelativePaths ?? [])
            assets.append(contentsOf: row.metadata?.offlineTextSubtitles?.map(\.relativePath) ?? [])
            for asset in assets where !asset.isEmpty {
                try? fileManager.removeItem(at: baseDirectory.appendingPathComponent(asset))
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
