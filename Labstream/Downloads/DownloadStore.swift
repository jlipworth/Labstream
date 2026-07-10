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
    private struct HydratedSideAssets {
        var posterURL: URL?
        var plexBIFURL: URL?
        var jellyfinTrickPlayPlaylistURL: URL?
        var chapterImageURLs: [Int: URL]
        var sideAssetBytes: Int
    }

    private var rows: [String: Row] = [:]          // ratingKey -> Row
    private var sideAssetHydrationCache: [String: HydratedSideAssets] = [:] // guarded by `lock`
    private var lastProgressPersist = Date.distantPast   // guarded by `lock`
    private let baseDirectory: URL                  // Application Support/Downloads
    private let indexURL: URL                        // baseDirectory/index.json
    private let fileManager: FileManager

    /// - Parameter baseDirectory: where media files + the index live. Defaults to
    ///   `Application Support/Labstream/Downloads`, created if missing.
    init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let appSupport = (try? fileManager.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil,
                                                create: true))
            ?? fileManager.temporaryDirectory
        let dir = baseDirectory ?? appSupport
            .appendingPathComponent("Labstream", isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
        self.baseDirectory = dir
        self.indexURL = dir.appendingPathComponent("index.json")
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        // Exclude the offline cache from iCloud/device backups and give newly-created
        // auth-adjacent artifacts a protected parent directory.
        try? CredentialArtifactStorage.applyProtectionAndBackupExclusion(
            to: self.baseDirectory,
            protection: CredentialArtifactStorage.authArtifactProtection,
            fileManager: fileManager)
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

    private static func safeExtension(_ value: String,
                                      allowed: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "ts", "webm"],
                                      fallback: String = "mp4") -> String {
        let lowered = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let alnum = lowered.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
        return alnum && allowed.contains(lowered) ? lowered : fallback
    }

    private static func safeSubtitleExtension(_ value: String) -> String {
        safeExtension(value, allowed: ["srt", "vtt"], fallback: "vtt")
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

    /// On-disk destination for a ratingKey's cached per-chapter image (#88/#89). Keyed by the
    /// chapter index so the offline Chapters rail and the Emby offline scrubber can both resolve a
    /// chapter back to its cached JPEG. Filename carries no token (the auth lives in the request).
    func chapterImageDestinationURL(ratingKey: String, index: Int) -> URL {
        baseDirectory.appendingPathComponent("\(Self.safeFilenameComponent(ratingKey)).chapter-\(index).jpg")
    }

    func textSubtitleDestinationURL(ratingKey: String, streamID: Int, ext: String) -> URL {
        baseDirectory.appendingPathComponent("\(Self.safeFilenameComponent(ratingKey)).sub-\(streamID).\(Self.safeSubtitleExtension(ext))")
    }

    /// #95: on-disk destination for a ratingKey's persisted URLSession resume blob, kept as a
    /// sibling of the media file so the relative-path convention and `remove` cleanup apply.
    func resumeDataDestinationURL(ratingKey: String) -> URL {
        baseDirectory.appendingPathComponent("\(Self.safeFilenameComponent(ratingKey)).resume")
    }

    /// Re-resolve a stored relative cache path to an absolute URL that exists on disk.
    private func resolvedDownloadAssetURL(_ relative: String?) -> URL? {
        guard let relative, Self.isSafeOneLevelRelativePath(relative) else { return nil }
        let url = baseDirectory.appendingPathComponent(relative)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Fast hot-path side-asset URL hydration. Trust safe persisted one-level relative paths and
    /// avoid a filesystem stat. Cold playback accessors still call `resolvedDownloadAssetURL` when
    /// they must prove the file exists before opening it.
    private func fastResolvedDownloadAssetURL(_ relative: String?) -> URL? {
        guard let relative, Self.isSafeOneLevelRelativePath(relative) else { return nil }
        return baseDirectory.appendingPathComponent(relative)
    }

    /// Current records, absolute URLs re-resolved against the live container.
    ///
    /// This is a hot UI/startup path: `DownloadManager.refreshRecords()` may read it repeatedly while
    /// SwiftUI is creating the scene. Keep hydration cheap and avoid stat'ing every poster, BIF,
    /// trickplay tile, chapter image, and subtitle on each read; large headset libraries can carry
    /// enough sidecars to trip the scene-create watchdog.
    var records: [DownloadRecord] {
        lock.lock()
        let snapshot = Array(rows.values)
        lock.unlock()
        let hydrated = snapshot.map { row in
            let sideAssets = hydratedSideAssets(ratingKey: row.ratingKey, metadata: row.metadata)
            return DownloadRecord(ratingKey: row.ratingKey,
                                  title: row.title,
                                  localURL: baseDirectory.appendingPathComponent(row.relativePath),
                                  bytes: row.bytes,
                                  progress: row.progress,
                                  status: row.status,
                                  metadata: row.metadata,
                                  posterURL: sideAssets.posterURL,
                                  plexBIFURL: sideAssets.plexBIFURL,
                                  jellyfinTrickPlayPlaylistURL: sideAssets.jellyfinTrickPlayPlaylistURL,
                                  chapterImageURLs: sideAssets.chapterImageURLs,
                                  sideAssetBytes: sideAssets.sideAssetBytes)
        }
        return OfflineDownloadSort.sorted(hydrated)
    }

    /// The set of indexed ratingKeys, WITHOUT touching the filesystem. Use this when
    /// you only need to test membership (e.g. reattach matching) and don't want the
    /// per-row poster `fileExists` cost that `records` pays.
    var allRatingKeys: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(rows.keys)
    }

    /// Lightweight status lookup for delegate/IO race decisions that must not pay the full
    /// `records` hydration cost (poster/chapter/trickplay file stats) just to distinguish a user
    /// pause from a delete/cancel.
    func status(for ratingKey: String) -> DownloadStatus? {
        lock.lock(); defer { lock.unlock() }
        return rows[ratingKey]?.status
    }

    /// Absolute destinations for indexed rows, regardless of status. Used when rebinding
    /// background URLSession tasks after relaunch: the persisted row knows the real extension
    /// (`.mp4`, `.mkv`, etc.), while a resumed task URL may not carry enough information.
    var destinationsByRatingKey: [String: URL] {
        lock.lock(); defer { lock.unlock() }
        return rows.mapValues { baseDirectory.appendingPathComponent($0.relativePath) }
    }

    /// Privacy-safe storage accounting for diagnostics/settings (#171). This reports aggregate
    /// bytes and conservative orphan candidates only; it does not delete anything.
    func storageAudit(inFlightRelativePaths: Set<String> = []) -> OfflineDownloadStorageAudit {
        lock.lock()
        let snapshot = Array(rows.values)
        lock.unlock()

        let referenced = OfflineDownloadFileInventory.referencedRelativePaths(
            mainRelativePaths: snapshot.map(\.relativePath),
            metadata: snapshot.map(\.metadata)
        )
        let files = directoryFileSnapshots()
        return OfflineDownloadFileInventory.audit(directoryFiles: files,
                                                  referencedRelativePaths: referenced,
                                                  inFlightRelativePaths: inFlightRelativePaths)
    }

    /// Absolute local URL for a completed download, if indexed AND present on disk.
    func localURL(for ratingKey: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard let row = rows[ratingKey], row.status == .complete || row.status == .unverified else { return nil }
        let url = baseDirectory.appendingPathComponent(row.relativePath)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Absolute local Plex BIF cache URL for a completed download, if present on disk.
    func plexBIFURL(for ratingKey: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard let row = rows[ratingKey], row.status == .complete || row.status == .unverified else { return nil }
        return resolvedDownloadAssetURL(row.metadata?.plexBIFRelativePath)
    }

    /// Absolute local Jellyfin trickplay playlist URL for a completed download, if present on disk.
    func jellyfinTrickPlayPlaylistURL(for ratingKey: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard let row = rows[ratingKey], row.status == .complete || row.status == .unverified else { return nil }
        return resolvedDownloadAssetURL(row.metadata?.jellyfinTrickPlayPlaylistRelativePath)
    }

    /// Absolute cached per-chapter image URLs (chapter index → file) for a completed download,
    /// limited to files that still exist on disk (#88/#89).
    func chapterImageURLs(for ratingKey: String) -> [Int: URL] {
        lock.lock(); defer { lock.unlock() }
        guard let row = rows[ratingKey], row.status == .complete || row.status == .unverified else { return [:] }
        return Self.resolvedChapterImageURLs(row.metadata?.chapterImageRelativePaths,
                                             baseDirectory: baseDirectory,
                                             fileManager: fileManager)
    }

    private static func resolvedChapterImageURLs(_ relatives: [Int: String]?,
                                                 baseDirectory: URL,
                                                 fileManager: FileManager) -> [Int: URL] {
        guard let relatives else { return [:] }
        var out: [Int: URL] = [:]
        for (index, relative) in relatives where isSafeOneLevelRelativePath(relative) {
            let url = baseDirectory.appendingPathComponent(relative)
            if fileManager.fileExists(atPath: url.path) { out[index] = url }
        }
        return out
    }

    private static func fastResolvedChapterImageURLs(_ relatives: [Int: String]?,
                                                     baseDirectory: URL) -> [Int: URL] {
        guard let relatives else { return [:] }
        var out: [Int: URL] = [:]
        for (index, relative) in relatives where isSafeOneLevelRelativePath(relative) {
            out[index] = baseDirectory.appendingPathComponent(relative)
        }
        return out
    }

    private static func isSafeOneLevelRelativePath(_ relative: String) -> Bool {
        !relative.isEmpty
            && !relative.contains("/")
            && !relative.contains("\\")
            && relative != "."
            && relative != ".."
    }

    private func sideAssetRelativePaths(for metadata: OfflineMetadata?) -> [String] {
        guard let metadata else { return [] }
        var relatives: [String] = []
        relatives.append(contentsOf: [
            metadata.posterRelativePath,
            metadata.plexBIFRelativePath,
            metadata.jellyfinTrickPlayPlaylistRelativePath,
        ].compactMap { $0 })
        relatives.append(contentsOf: metadata.jellyfinTrickPlayTileRelativePaths ?? [])
        relatives.append(contentsOf: Array(metadata.chapterImageRelativePaths?.values ?? Dictionary<Int, String>().values))
        relatives.append(contentsOf: metadata.offlineTextSubtitles?.map(\.relativePath) ?? [])
        return relatives.filter(Self.isSafeOneLevelRelativePath)
    }

    private func hydratedSideAssets(ratingKey: String, metadata: OfflineMetadata?) -> HydratedSideAssets {
        lock.lock()
        if let cached = sideAssetHydrationCache[ratingKey] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let relatives = sideAssetRelativePaths(for: metadata)
        let sideAssetBytes = relatives.reduce(0) { total, relative in
            let url = baseDirectory.appendingPathComponent(relative)
            let attrs = try? fileManager.attributesOfItem(atPath: url.path)
            return total + ((attrs?[.size] as? NSNumber)?.intValue ?? 0)
        }
        let hydrated = HydratedSideAssets(
            posterURL: fastResolvedDownloadAssetURL(metadata?.posterRelativePath),
            plexBIFURL: fastResolvedDownloadAssetURL(metadata?.plexBIFRelativePath),
            jellyfinTrickPlayPlaylistURL: fastResolvedDownloadAssetURL(metadata?.jellyfinTrickPlayPlaylistRelativePath),
            chapterImageURLs: Self.fastResolvedChapterImageURLs(metadata?.chapterImageRelativePaths,
                                                               baseDirectory: baseDirectory),
            sideAssetBytes: sideAssetBytes
        )
        lock.lock()
        sideAssetHydrationCache[ratingKey] = hydrated
        lock.unlock()
        return hydrated
    }

    private func directoryFileSnapshots() -> [OfflineDownloadFileSnapshot] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return OfflineDownloadFileSnapshot(relativePath: url.lastPathComponent, byteCount: size)
        }
    }

    private func fileSize(at url: URL) -> Int? {
        guard let raw = (try? fileManager.attributesOfItem(atPath: url.path)[.size]) else {
            return nil
        }
        if let number = raw as? NSNumber {
            return number.intValue
        }
        if let int = raw as? Int {
            return int
        }
        if let int64 = raw as? Int64 {
            return Int(int64)
        }
        return nil
    }

    private func fileSize(relativePath: String) -> Int? {
        fileSize(at: baseDirectory.appendingPathComponent(relativePath))
    }

    /// The source's EXACT byte size when the row knows it (static-lane Content-Length /
    /// `sourcePartSize`), or nil. Unlike `expectedBytesEstimate` this never falls back to the
    /// ratio-derived estimate — callers use it to judge byte-completeness, where an estimate
    /// would misfire. Nil for non-static lanes: enqueue metadata records the SOURCE part size on
    /// every lane, but a transcode's finished output is legitimately smaller than its source, so
    /// only a byte-for-byte static download may be measured against this.
    func sourceExactBytes(ratingKey: String) -> Int? {
        // `rows` is shared with URLSession delegate callbacks; even read-only dictionary lookups
        // must take the lock while downloads are actively mutating the store. A headset crash
        // (Labstream-2026-07-08-235111.ips) showed this racing the range progress delegate during
        // the completed-size audit, corrupting the dictionary bridge and aborting in
        // `Dictionary._Variant.lookup`.
        lock.lock()
        let row = rows[ratingKey]
        lock.unlock()
        guard let row,
              let metadata = row.metadata,
              metadata.resolvedResumeMode(ratingKey: ratingKey) == .staticByteRange,
              let size = metadata.sourcePartSize, size > 0 else { return nil }
        return size
    }

    private static func expectedBytesEstimate(row: Row) -> Int? {
        if let sourcePartSize = row.metadata?.sourcePartSize, sourcePartSize > 0 {
            return sourcePartSize
        }
        guard row.bytes > 0, row.progress > 0.0001 else { return nil }
        let expected = Int((Double(row.bytes) / min(row.progress, 1.0)).rounded())
        return expected > 0 ? expected : nil
    }

    private static func progressForDurableBytes(_ bytes: Int, expectedBytes: Int?) -> Double {
        guard let expectedBytes, expectedBytes > 0 else { return 0 }
        return min(1.0, Double(bytes) / Double(expectedBytes))
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
        var metadata = record.metadata ?? existing?.metadata
        if var incoming = record.metadata, let previous = existing?.metadata {
            incoming.preserveCachedSideAssets(from: previous)
            metadata = incoming
        }
        rows[record.ratingKey] = Row(ratingKey: record.ratingKey,
                                     title: record.title,
                                     relativePath: rel,
                                     bytes: record.bytes,
                                     progress: record.progress,
                                     status: record.status,
                                     metadata: metadata)
        sideAssetHydrationCache.removeValue(forKey: record.ratingKey)
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

    /// Record locally-cached per-chapter image paths (#88/#89), keyed by chapter index. Relative
    /// paths only. No-op for an empty map or a missing row/metadata.
    func setChapterImageRelativePaths(ratingKey: String, _ relativePathsByIndex: [Int: String]) {
        guard !relativePathsByIndex.isEmpty else { return }
        updateMetadata(ratingKey: ratingKey) { $0.chapterImageRelativePaths = relativePathsByIndex }
    }

    func setOfflineTextSubtitles(ratingKey: String, _ tracks: [OfflineTextSubtitleTrack]) {
        guard !tracks.isEmpty else { return }
        updateMetadata(ratingKey: ratingKey) { $0.offlineTextSubtitles = tracks }
    }

    /// Persist the last local-file playback position for a completed offline row (#146).
    ///
    /// This intentionally updates `localPlaybackPositionMs`, not the captured server `viewOffset`,
    /// so offline progress stays per downloaded row/version and online timeline semantics remain
    /// untouched. The pure policy clamps negatives/over-duration values and resets near-EOF
    /// positions to 0 so reopening does not land on a final frame.
    func setLocalPlaybackPosition(ratingKey: String, positionMs: Int, durationMs: Int?) {
        updateMetadata(ratingKey: ratingKey) { meta in
            let effectiveDuration = durationMs ?? meta.duration
            meta.localPlaybackPositionMs = OfflinePlaybackPositionPolicy.standard
                .persistedPositionMs(currentMs: positionMs, durationMs: effectiveDuration)
        }
    }

    /// #84: persist the server-minted `PlaySessionId` for a transcoded JF/Emby (or Plex optimize)
    /// job so a hard app kill can still tear the encoder down on next launch. Status-change-grade:
    /// persists immediately (not throttled). No-op if the row/metadata is gone.
    func setPlaySessionID(ratingKey: String, _ playSessionID: String) {
        updateMetadata(ratingKey: ratingKey) { $0.playSessionID = playSessionID }
    }

    /// #84: clear the persisted `PlaySessionId` after the encoder has been torn down (the launch
    /// sweep is idempotent — clearing prevents it from firing twice). No-op if the row is gone.
    func clearPlaySessionID(ratingKey: String) {
        updateMetadata(ratingKey: ratingKey) { $0.playSessionID = nil }
    }

    /// #84: persist the authoritative media-source id chosen for this download so a retry can
    /// re-issue the request without re-deriving it. No-op if the row/metadata is gone.
    func setMediaSourceID(ratingKey: String, _ mediaSourceID: String) {
        updateMetadata(ratingKey: ratingKey) { $0.mediaSourceID = mediaSourceID }
    }

    /// Persist the exact static resource size once a byte-range transfer discovers it. Rows may
    /// relaunch/reattach while the active bytes are still in URLSession's temp file; keeping this
    /// denominator durable lets the Offline UI continue to show percent/ETA from live Range bytes
    /// instead of falling back to a spinner + 0% caption.
    func setSourcePartSizeIfMissing(ratingKey: String, _ size: Int?) {
        setSourcePartSize(ratingKey: ratingKey, size, onlyIfMissing: true)
    }

    func setSourcePartSize(ratingKey: String, _ size: Int?) {
        setSourcePartSize(ratingKey: ratingKey, size, onlyIfMissing: false)
    }

    private func setSourcePartSize(ratingKey: String, _ size: Int?, onlyIfMissing: Bool) {
        guard let size, size > 0 else { return }
        lock.lock()
        let existing = rows[ratingKey]?.metadata?.sourcePartSize ?? 0
        lock.unlock()
        // Range progress delegates see the same Content-Range denominator on every callback.
        // Avoid rewriting metadata/index JSON, invalidating caches, and notifying refresh paths
        // when the value is already durable.
        guard existing != size else { return }
        guard !onlyIfMissing || existing <= 0 else { return }
        updateMetadata(ratingKey: ratingKey) { meta in
            if meta.sourcePartSize != size,
               (!onlyIfMissing || (meta.sourcePartSize ?? 0) <= 0) {
                meta.sourcePartSize = size
            }
        }
    }

    /// #95: persist a URLSession resume blob for a recoverably-interrupted download and record
    /// its relative path on the row's metadata, so a manual Resume (even after relaunch) can
    /// continue from the byte offset via `downloadTask(withResumeData:)`. The blob is written as
    /// a sibling `.resume` file (it can be large). No-op if the row/metadata is gone.
    func setResumeData(ratingKey: String, _ data: Data, displayBytes: Int? = nil) {
        // H9: `updateMetadata` is a no-op when a row carries no metadata snapshot (a
        // legacy pre-D5 row). Writing the blob first and only then discovering the path
        // can't be recorded would orphan a potentially large `.resume` file on disk. Bail
        // BEFORE writing when there's nothing to record it on — resume was already
        // unavailable for such a row, so this only avoids the leak, it changes no behavior.
        lock.lock()
        let canRecordPath = rows[ratingKey]?.metadata != nil
        lock.unlock()
        guard canRecordPath else {
            NSLog("DownloadStore: skipping resume-data persist for %@ — row has no metadata to record its path on",
                  ratingKey)
            return
        }
        let url = resumeDataDestinationURL(ratingKey: ratingKey)
        do {
            try CredentialArtifactStorage.writeAuthArtifact(data, to: url, fileManager: fileManager)
        } catch {
            NSLog("DownloadStore: failed to persist resume data for %@ (%@)",
                  ratingKey, DiagnosticRedactor.safeErrorSummary(error))
            return
        }
        updateMetadata(ratingKey: ratingKey) {
            $0.resumeDataRelativePath = url.lastPathComponent
            if let displayBytes, displayBytes > 0 {
                $0.resumeDisplayBytes = max(displayBytes, $0.resumeDisplayBytes ?? 0)
            }
        }
    }

    /// #95: the persisted resume blob for a row, if present on disk. `nil` when the row has no
    /// recorded resume path or the file is gone.
    func resumeData(ratingKey: String) -> Data? {
        lock.lock()
        let relative = rows[ratingKey]?.metadata?.resumeDataRelativePath
        lock.unlock()
        guard let relative, !relative.isEmpty else { return nil }
        return try? Data(contentsOf: baseDirectory.appendingPathComponent(relative))
    }

    /// #95: whether a row has a persisted resume blob ON DISK (used by launch reconciliation to
    /// decide if a `.paused` row stays resumable). FS-checked without reading the blob.
    func hasResumeData(ratingKey: String) -> Bool {
        lock.lock()
        let relative = rows[ratingKey]?.metadata?.resumeDataRelativePath
        lock.unlock()
        guard let relative, !relative.isEmpty else { return false }
        return fileManager.fileExists(atPath: baseDirectory.appendingPathComponent(relative).path)
    }

    /// #95: URLSession resume blobs are only safe for byte-range-resumable sources. Jellyfin/Emby
    /// encoder-served lanes (`.optimize` and `.compatibleRemux`) are forward-only streams with no
    /// stable validator, so even a resume blob can 200-full-restart or 416. Surface those
    /// interruptions as a clean restart-required failure instead of a misleading "Paused — tap to
    /// resume" row. Static original/existing-version downloads remain resumable.
    func supportsPersistedResumeData(ratingKey: String) -> Bool {
        lock.lock()
        let row = rows[ratingKey]
        lock.unlock()
        guard let row else { return false }
        let backend = row.metadata?.resolvedBackendKind(ratingKey: row.ratingKey)
            ?? DownloadBackendKind(ratingKeyPrefix: row.ratingKey)
        let mode = row.metadata?.resolvedResumeMode(ratingKey: row.ratingKey)
            ?? DownloadResumeMode.resolved(backend: backend, lane: .original)
        return mode != .liveForwardOnly
    }

    /// #95: drop a row's persisted resume blob + its recorded path once it's consumed (a resume
    /// task was created) or invalidated (a clean restart). No-op if the row/metadata is gone.
    func resumeDisplayBytes(ratingKey: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return rows[ratingKey]?.metadata?.resumeDisplayBytes
    }

    func clearResumeData(ratingKey: String, clearDisplayBytes: Bool = true) {
        lock.lock()
        let relative = rows[ratingKey]?.metadata?.resumeDataRelativePath
        lock.unlock()
        if let relative, !relative.isEmpty {
            try? fileManager.removeItem(at: baseDirectory.appendingPathComponent(relative))
        }
        updateMetadata(ratingKey: ratingKey) {
            $0.resumeDataRelativePath = nil
            if clearDisplayBytes {
                $0.resumeDisplayBytes = nil
            }
        }
    }

    /// #169: the HTTP validator (`ETag`/`Last-Modified`) for a static byte-range download, captured
    /// from the first successful range body and sent as `If-Range` on later requests so a server-side resource change is
    /// detected (200 full-replace) instead of silently corrupting the partial.
    func rangeValidator(ratingKey: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return rows[ratingKey]?.metadata?.rangeValidator
    }

    func setRangeValidator(ratingKey: String, _ validator: String) {
        updateMetadata(ratingKey: ratingKey) { $0.rangeValidator = validator }
    }

    func clearRangeValidator(ratingKey: String) {
        updateMetadata(ratingKey: ratingKey) { $0.rangeValidator = nil }
    }

    /// #169: reset persisted static byte-range progress to the bytes that are actually durable in
    /// the partial file. The current in-flight static Range task body lives in an OS temp
    /// until `didFinishDownloadingTo`; progress callbacks may have published those optimistic bytes
    /// for UI smoothness, but pause/error/reconcile paths must checkpoint from this file size only.
    @discardableResult
    func resetStaticRangeProgressToDurableCheckpoint(ratingKey: String,
                                                     expectedBytes explicitExpectedBytes: Int? = nil) -> Int {
        lock.lock()
        guard var row = rows[ratingKey] else { lock.unlock(); return 0 }
        let backend = row.metadata?.resolvedBackendKind(ratingKey: row.ratingKey)
            ?? DownloadBackendKind(ratingKeyPrefix: row.ratingKey)
        let mode = row.metadata?.resolvedResumeMode(ratingKey: row.ratingKey)
            ?? DownloadResumeMode.resolved(
                backend: backend,
                lane: row.metadata?.resolvedDownloadLane() ?? .original)
        guard mode == .staticByteRange else {
            let bytes = row.bytes
            lock.unlock()
            return bytes
        }
        let durableBytes = fileSize(relativePath: row.relativePath) ?? 0
        let expectedBytes = explicitExpectedBytes ?? Self.expectedBytesEstimate(row: row)
        let progress = Self.progressForDurableBytes(durableBytes, expectedBytes: expectedBytes)
        var changed = false
        // The resume display watermark represents temp bytes owned by a URLSession resume blob.
        // Once no blob remains (durable fallback discarded it, adoption rejected it as stale, or a
        // restart never produced one), those temp bytes are gone — keeping the watermark would
        // over-report progress until live bytes caught back up. The pause path persists the blob
        // BEFORE resetting, so legitimate watermarks survive this.
        if row.metadata?.resumeDisplayBytes != nil,
           (row.metadata?.resumeDataRelativePath ?? "").isEmpty {
            row.metadata?.resumeDisplayBytes = nil
            changed = true
        }
        if row.bytes != durableBytes || abs(row.progress - progress) > 0.000_001 {
            row.bytes = durableBytes
            row.progress = progress
            changed = true
        }
        guard changed else {
            lock.unlock()
            return durableBytes
        }
        rows[ratingKey] = row
        lock.unlock()
        persist()
        return durableBytes
    }

    func durableStaticRangeCheckpointSize(ratingKey: String) -> Int {
        lock.lock()
        let row = rows[ratingKey]
        lock.unlock()
        guard let row,
              row.metadata?.resolvedResumeMode(ratingKey: row.ratingKey) == .staticByteRange else {
            return 0
        }
        return fileSize(relativePath: row.relativePath) ?? 0
    }

    /// #169: ratingKeys for static byte-range rows that were ACTIVELY transferring (`.downloading`/
    /// `.queued`) — NOT user-paused — when the app died. A row may have zero durable bytes if the
    /// first background range body was still in the OS temp file; it is still a system-interrupted active
    /// download and should restart from byte 0 rather than waiting for a manual tap.
    /// Must be read BEFORE `reconcile`, which parks them `.paused` (conflating them with a deliberate
    /// user pause). The launch auto-resume uses this to continue interrupted downloads after a process
    /// kill without overriding a row the user actually paused. Durable checkpoint size is still read
    /// from the file system by reconciliation/resume; optimistic row bytes are never used here.
    func interruptedStaticByteRangeKeys() -> [String] {
        lock.lock(); let snapshot = Array(rows.values); lock.unlock()
        return snapshot.compactMap { row in
            guard row.status == .downloading || row.status == .queued,
                  row.metadata?.resolvedResumeMode(ratingKey: row.ratingKey) == .staticByteRange else { return nil }
            return row.ratingKey
        }
    }

    private func updateMetadata(ratingKey: String, mutate: (inout OfflineMetadata) -> Void) {
        lock.lock()
        guard var row = rows[ratingKey], var meta = row.metadata else { lock.unlock(); return }
        let oldMeta = meta
        mutate(&meta)
        guard meta != oldMeta else { lock.unlock(); return }
        row.metadata = meta
        rows[ratingKey] = row
        sideAssetHydrationCache.removeValue(forKey: ratingKey)
        lock.unlock()
        persist()
    }

    /// Update transfer progress for an in-flight download. Moving any bytes from a task still owned by
    /// the session means the transfer is live, so we promote any non-terminal transfer row to
    /// `.downloading` here (D2: the UI distinguishes "waiting on server" from "actively transferring").
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
        let previousStatus = row.status
        var statusChanged = false
        if row.status == .queued || row.status == .paused || row.status == .failed {
            row.status = .downloading
            statusChanged = true
        }
        rows[ratingKey] = row
        let now = Date()
        let shouldPersist = statusChanged
            || now.timeIntervalSince(lastProgressPersist) >= Self.progressPersistInterval
        if shouldPersist { lastProgressPersist = now }
        lock.unlock()
        if statusChanged {
            AppDiagnostics.record(.downloads, "downloads.status_transition", fields: [
                "download_id": .identifier(ratingKey),
                "from": .label(previousStatus.rawValue),
                "to": .label(DownloadStatus.downloading.rawValue),
                "bytes_exact": .int(bytes),
                "progress_percent": .int(Int((progress * 100).rounded(.down))),
                "source": .label("progress"),
            ])
        }
        if shouldPersist { persist() }
    }

    /// Set the explicit lifecycle status for a row (D2). No-op if the row is gone.
    func setStatus(ratingKey: String, _ status: DownloadStatus) {
        lock.lock()
        guard var row = rows[ratingKey] else { lock.unlock(); return }
        let previousStatus = row.status
        let bytes = row.bytes
        let progress = row.progress
        row.status = status
        rows[ratingKey] = row
        lock.unlock()
        if previousStatus != status {
            AppDiagnostics.record(.downloads, "downloads.status_transition", fields: [
                "download_id": .identifier(ratingKey),
                "from": .label(previousStatus.rawValue),
                "to": .label(status.rawValue),
                "bytes_exact": .int(bytes),
                "progress_percent": .int(Int((progress * 100).rounded(.down))),
                "source": .label("setStatus"),
            ])
        }
        persist()
    }

    /// Promote a previously byte-complete but probe-inconclusive row once a later validation or
    /// actual local playback proves the file is usable. No-op for already-complete/active/failed rows
    /// so callers can safely invoke this from reconnect and playback-progress paths.
    @discardableResult
    func markCompleteIfUnverified(ratingKey: String) -> Bool {
        lock.lock()
        guard var row = rows[ratingKey], row.status == .unverified else {
            lock.unlock()
            return false
        }
        row.status = .complete
        rows[ratingKey] = row
        lock.unlock()
        AppDiagnostics.record(.downloads, "downloads.unverified_promoted", fields: [
            "download_id": .identifier(ratingKey),
            "source": .label("local_playback"),
        ])
        persist()
        return true
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
    /// genuinely still in flight and left untouched. `snapshotRatingKeys` are the rows that
    /// existed when the task snapshot was requested: rows seeded on the main actor after that
    /// point are skipped entirely, or a brand-new `.queued` row (or a static row mid retry
    /// rebuild) would be demoted against a snapshot that predates it.
    func reconcile(liveRatingKeys: Set<String>, snapshotRatingKeys: Set<String>) {
        lock.lock()
        var changed = false
        for (key, var row) in rows {
            guard DownloadStatus.reconcileEligible(ratingKey: key,
                                                   snapshotRatingKeys: snapshotRatingKeys) else { continue }
            let hasLiveTask = liveRatingKeys.contains(key)
            let fileURL = baseDirectory.appendingPathComponent(row.relativePath)
            let partialBytes = fileSize(at: fileURL) ?? 0
            let fileExists = partialBytes > 0 || fileManager.fileExists(atPath: fileURL.path)
            // #95: does a persisted resume blob survive for this row? A `.paused` row stays
            // resumable only while it does (checked WITHOUT reading the blob).
            let resumeRelative = row.metadata?.resumeDataRelativePath
            let hasResumeData = (resumeRelative?.isEmpty == false)
                && fileManager.fileExists(
                    atPath: baseDirectory.appendingPathComponent(resumeRelative!).path)
            let resumeMode = row.metadata?.resolvedResumeMode(ratingKey: row.ratingKey)
                ?? DownloadResumeMode.resolved(
                    backend: row.metadata?.resolvedBackendKind(ratingKey: row.ratingKey)
                        ?? DownloadBackendKind(ratingKeyPrefix: row.ratingKey),
                    lane: row.metadata?.resolvedDownloadLane() ?? .original)
            let hasServerPrepCheckpoint = resumeMode == .serverPrepThenStatic
                && row.status == .paused
                && (row.metadata?.optimizeTargetName?.isEmpty == false
                    || row.metadata?.embyConvertJobID != nil)
            let hasAppRangeCheckpoint = resumeMode == .staticByteRange
                && (row.status == .paused || row.status == .queued || row.status == .downloading)
                && partialBytes > 0
            let staticRangeExpectedBytes = Self.expectedBytesEstimate(row: row)
            let staticRangeProgress = Self.progressForDurableBytes(
                partialBytes,
                expectedBytes: staticRangeExpectedBytes
            )
            // Only Plex has a server-side "prepare then static download" optimize queue that can
            // resume after relaunch. Jellyfin AND Emby transcoded rows are LIVE streams from a
            // URLSession task (Emby additionally renders via a server FFmpeg encoder), so a
            // missing task means the render is gone — they must demote to retryable `.failed`, not
            // resume as `.queued`. Hence both backend prefixes are excluded here.
            let isPlexServerPrepOptimizedJob = !hasLiveTask
                && (row.status == .queued || row.status == .downloading)
                && resumeMode == .serverPrepThenStatic
                && row.metadata?.optimizeTargetName?.isEmpty == false
                && !row.ratingKey.hasPrefix("jellyfin:")
                && !row.ratingKey.hasPrefix("emby:")
            let hasLiveStaticRangeTask = hasLiveTask
                && resumeMode == .staticByteRange
                && (row.status == .paused || row.status == .queued || row.status == .downloading)
            let newStatus: DownloadStatus
            if isPlexServerPrepOptimizedJob {
                newStatus = .queued
            } else if hasLiveStaticRangeTask {
                // A reattached background Range task is authoritative live work. Do not park the row
                // as `.paused` merely because a durable partial exists: that made the UI offer Resume
                // while nsurlsessiond was still delivering callbacks, allowing a duplicate Range task
                // to start at the same checkpoint.
                newStatus = .downloading
            } else if hasServerPrepCheckpoint || hasAppRangeCheckpoint {
                newStatus = .paused
            } else {
                newStatus = DownloadStatus.reconciledStatus(
                    current: row.status, fileExists: fileExists,
                    hasLiveTask: hasLiveTask, hasResumeData: hasResumeData)
            }
            let shouldResetOptimizedProgress = isPlexServerPrepOptimizedJob
                && (row.bytes != 0 || row.progress != 0)
            let shouldResetRangeProgress = hasAppRangeCheckpoint
                && (row.bytes != partialBytes || abs(row.progress - staticRangeProgress) > 0.000_001)
            let shouldResetMissingRangeProgress = resumeMode == .staticByteRange
                && !hasLiveTask
                && !hasAppRangeCheckpoint
                && (row.status == .paused || row.status == .queued
                    || row.status == .downloading || row.status == .failed)
                && (row.bytes != 0 || row.progress != 0)
            guard newStatus != row.status
                    || shouldResetOptimizedProgress
                    || shouldResetRangeProgress
                    || shouldResetMissingRangeProgress else { continue }
            // A non-live queued/downloading row that we're demoting to `.failed` may have left a
            // partial file behind. Delete it so dead bytes don't sit invisibly on disk — a retry
            // rebuilds the file from scratch regardless. #95: but a row that STAYS resumable
            // (`.paused` with a surviving resume blob) must KEEP its partial, or the resume data
            // is useless; only delete when we're actually demoting to a non-resumable terminal state.
            let isStayingResumable = (newStatus == .paused)
            if (row.status == .queued || row.status == .downloading || row.status == .paused)
                && !hasLiveTask && !isStayingResumable {
                try? fileManager.removeItem(
                    at: baseDirectory.appendingPathComponent(row.relativePath))
                if resumeRelative?.isEmpty == false {
                    try? fileManager.removeItem(
                        at: baseDirectory.appendingPathComponent(resumeRelative!))
                }
            }
            row.status = newStatus
            if isPlexServerPrepOptimizedJob {
                row.bytes = 0
                row.progress = 0
            } else if hasAppRangeCheckpoint {
                row.bytes = partialBytes
                row.progress = staticRangeProgress
            } else if shouldResetMissingRangeProgress {
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
        sideAssetHydrationCache.removeValue(forKey: ratingKey)
        lock.unlock()
        if let row {
            let url = baseDirectory.appendingPathComponent(row.relativePath)
            // The row is already gone from the index, so a failed delete would
            // permanently orphan the file — log it rather than vanish silently.
            do { try fileManager.removeItem(at: url) }
            catch where fileManager.fileExists(atPath: url.path) {
                NSLog("DownloadStore: failed to delete media for %@ (%@); local file orphaned",
                      ratingKey, DiagnosticRedactor.safeErrorSummary(error))
            } catch {} // already absent — nothing to clean up
            // D5/#78: also delete cached side assets so a removed download leaves nothing behind.
            var assets = [row.metadata?.posterRelativePath,
                          row.metadata?.plexBIFRelativePath,
                          row.metadata?.jellyfinTrickPlayPlaylistRelativePath,
                          row.metadata?.resumeDataRelativePath].compactMap { $0 }
            assets.append(contentsOf: row.metadata?.jellyfinTrickPlayTileRelativePaths ?? [])
            assets.append(contentsOf: Array(row.metadata?.chapterImageRelativePaths?.values ?? Dictionary<Int, String>().values))
            assets.append(contentsOf: row.metadata?.offlineTextSubtitles?.map(\.relativePath) ?? [])
            for asset in assets where Self.isSafeOneLevelRelativePath(asset) {
                try? fileManager.removeItem(at: baseDirectory.appendingPathComponent(asset))
            }
        }
        persist()
    }

    // MARK: - Persistence

    private func load() {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: indexURL) else { return }
        // #135 H8: decode the index row-by-row so a single corrupt/forward-incompatible
        // row can't drop the user's whole offline library (the old all-or-nothing
        // `decode([Row].self)` did exactly that). A non-zero skip is logged rather than
        // swallowed — silent truncation is the failure mode this guards against.
        let result = DownloadIndexCoding.decode(Row.self, from: data)
        if result.skippedRowCount > 0 {
            NSLog("DownloadStore: skipped %d corrupt offline-index row(s) on load (schemaVersion %d); %d row(s) preserved",
                  result.skippedRowCount, result.schemaVersion, result.rows.count)
        }
        var repairedSubtitleRows = 0
        rows = Dictionary(uniqueKeysWithValues: result.rows.map { row in
            var repaired = row
            if repaired.metadata?.offlineTextSubtitles?.isEmpty ?? true,
               let tracks = cachedSubtitleTracksFromDisk(ratingKey: row.ratingKey),
               !tracks.isEmpty {
                repaired.metadata?.offlineTextSubtitles = tracks
                repairedSubtitleRows += 1
                NSLog("DownloadStore: repaired %d cached offline subtitle track(s) for %@",
                      tracks.count, row.ratingKey)
            }
            return (repaired.ratingKey, repaired)
        })
        if repairedSubtitleRows > 0 {
            let snapshot = Array(rows.values)
            lock.unlock()
            guard let data = try? DownloadIndexCoding.encode(snapshot) else {
                lock.lock()
                return
            }
            try? data.write(to: indexURL, options: .atomic)
            lock.lock()
        }
    }

    private func cachedSubtitleTracksFromDisk(ratingKey: String) -> [OfflineTextSubtitleTrack]? {
        let safePrefix = "\(Self.safeFilenameComponent(ratingKey)).sub-"
        guard let urls = try? fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let tracks: [OfflineTextSubtitleTrack] = urls.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasPrefix(safePrefix),
                  let ext = name.split(separator: ".").last.map(String.init)?.lowercased(),
                  ["srt", "vtt"].contains(ext),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { return nil }
            let idStart = name.index(name.startIndex, offsetBy: safePrefix.count)
            let idEnd = name.index(name.endIndex, offsetBy: -(".\(ext)".count))
            guard idStart < idEnd,
                  let streamID = Int(name[idStart..<idEnd]) else { return nil }
            return OfflineTextSubtitleTrack(id: streamID,
                                            displayName: "Subtitle \(streamID)",
                                            codec: ext,
                                            relativePath: name)
        }.sorted { $0.id < $1.id }
        return tracks.isEmpty ? nil : tracks
    }

    private func persist() {
        lock.lock()
        let snapshot = Array(rows.values)
        lock.unlock()
        // #135 Stage 6: write the versioned envelope so a future on-disk migration can
        // branch on the schema version it reads back.
        guard let data = try? DownloadIndexCoding.encode(snapshot) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
