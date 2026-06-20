import Foundation

/// Explicit lifecycle state for a download, persisted so a relaunch can tell a
/// FINISHED transfer from a STALLED one. Previously completion was inferred from
/// `progress >= 1.0`, which can't distinguish a job that died mid-flight (the
/// progress just freezes) from one that genuinely finished — see D2 in research/14.
public enum DownloadStatus: String, Codable, Sendable, Equatable {
    case queued        // seeded, transfer not yet started / no live task yet
    case downloading   // a background task is actively writing bytes
    case complete      // validated file is on disk and playable
    case failed        // transfer or validation failed; row kept so it can be retried

    /// Default lifecycle status for a row persisted BEFORE D2, which lacked an
    /// explicit `status` field (completion was inferred from `progress >= 1.0`).
    ///
    /// A finished-looking row maps to `.complete`, anything else to `.queued`
    /// (launch reconciliation then re-checks it against disk). Decoders should call
    /// this only when no `status` is present on the row.
    public static func migratedStatus(forLegacyProgress progress: Double) -> DownloadStatus {
        progress >= 1.0 ? .complete : .queued
    }

    /// Reconcile a persisted row's status against disk reality at launch (D2).
    ///
    /// A row left `.queued`/`.downloading` from a previous run whose task did NOT
    /// survive relaunch can't be trusted: it was never validated/marked `.complete`,
    /// so even a file on disk may be partial. Such a row becomes `.failed`
    /// (retryable) rather than letting the UI spin forever on a dead transfer. A
    /// `.complete` row whose file has since vanished is likewise demoted to
    /// `.failed`. `hasLiveTask` is true when the background session reattached to
    /// this download — genuinely still in flight and left untouched.
    ///
    /// This is the pure transition table; the app side performs the disk-existence
    /// check and the partial-file cleanup before/after calling it.
    public static func reconciledStatus(current: DownloadStatus,
                                        fileExists: Bool,
                                        hasLiveTask: Bool) -> DownloadStatus {
        switch current {
        case .complete:
            // A completed row is only usable if its validated file still exists.
            return fileExists ? .complete : .failed
        case .queued, .downloading:
            if hasLiveTask { return current }   // task survived; leave it
            // No live task and never validated -> can't trust it; make it retryable.
            return .failed
        case .failed:
            return .failed
        }
    }
}

/// A Codable snapshot of the source `MediaItem` (plus the chosen download quality)
/// taken at enqueue time (D5).
///
/// Stored on each row so the offline library renders richly WITHOUT the server
/// (title, TV episode context, year, type, runtime, summary, content rating, tagline)
/// and so `retry()` + offline playback can reconstruct a faithful `MediaItem`
/// instead of fabricating a minimal movie. Every field beyond `ratingKey`/`title`/`type` is optional and
/// decoded with `decodeIfPresent`, and the whole snapshot is itself decoded with
/// `decodeIfPresent` on the row, so libraries persisted before D5 keep loading.
///
/// `posterRelativePath` is the locally-cached poster file's path RELATIVE to the
/// Downloads base directory (same convention as `relativePath`), so a moved sandbox
/// container doesn't orphan it. `nil` when no poster was cached.

/// Pure timing policy for offline-download playback validation. Keeps AVFoundation
/// probes duration/source-aware without hiding magic constants in app delegates.
public struct OfflinePlaybackValidationPolicy: Sendable, Equatable {
    public let timeoutSeconds: Double
    public let requiredPlaybackSeconds: Double
    public let pollIntervalMilliseconds: Int

    public init(timeoutSeconds: Double, requiredPlaybackSeconds: Double,
                pollIntervalMilliseconds: Int = 250) {
        self.timeoutSeconds = timeoutSeconds
        self.requiredPlaybackSeconds = requiredPlaybackSeconds
        self.pollIntervalMilliseconds = pollIntervalMilliseconds
    }

    /// - Parameters:
    ///   - durationMs: optional media duration. Short clips should not need to advance 0.5s.
    ///   - isRemotePreflight: true for source-URL preflight before downloading; remote startup can
    ///     be slower than validating a local completed file, so it gets a longer timeout.
    public static func make(durationMs: Int?, isRemotePreflight: Bool = false) -> Self {
        let required: Double
        if let durationMs, durationMs > 0 {
            let durationSeconds = Double(durationMs) / 1000.0
            required = min(0.5, max(0.05, durationSeconds * 0.10))
        } else {
            required = 0.5
        }
        return Self(timeoutSeconds: isRemotePreflight ? 12.0 : 8.0,
                    requiredPlaybackSeconds: required)
    }
}

/// Codable chapter snapshot for offline playback. `Chapter` itself is intentionally only
/// Decodable for server DTOs, so the download index stores this stable app-owned shape.
public struct OfflineChapter: Codable, Sendable, Equatable {
    public var chapterID: Int?
    public var tag: String?
    public var startTimeOffset: Int?
    public var endTimeOffset: Int?
    /// Original server thumbnail key. Binary chapter images are not cached yet; keeping the key
    /// lets a future online refresh/cache migration identify the source image.
    public var thumb: String?

    public init(chapterID: Int? = nil, tag: String? = nil, startTimeOffset: Int? = nil,
                endTimeOffset: Int? = nil, thumb: String? = nil) {
        self.chapterID = chapterID
        self.tag = tag
        self.startTimeOffset = startTimeOffset
        self.endTimeOffset = endTimeOffset
        self.thumb = thumb
    }

    public init(_ chapter: Chapter) {
        self.init(chapterID: chapter.chapterID,
                  tag: chapter.tag,
                  startTimeOffset: chapter.startTimeOffset,
                  endTimeOffset: chapter.endTimeOffset,
                  thumb: chapter.thumb)
    }

    public func makeChapter() -> Chapter {
        Chapter(id: chapterID,
                tag: tag,
                startTimeOffset: startTimeOffset,
                endTimeOffset: endTimeOffset,
                thumb: thumb)
    }
}

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
    /// Show/season context for episode rows. Persisted so the Offline tab can keep showing
    /// an ordered context line like "Show · S1E3 · Episode Title" without asking the server.
    public var grandparentTitle: String?
    public var grandparentRatingKey: String?
    public var grandparentThumb: String?
    public var parentTitle: String?
    public var parentRatingKey: String?
    public var parentThumb: String?
    public var parentIndex: Int?
    public var index: Int?
    /// The original Plex `thumb` path, kept so we can re-fetch the poster if the
    /// local cache is missing and the server is reachable again.
    public var thumb: String?
    /// The original Plex `art` (backdrop) path.
    public var art: String?
    /// Text chapter markers captured at download time so local playback can populate the
    /// existing Chapters tab without requiring network access. Chapter images are not cached yet.
    public var chapters: [OfflineChapter]?
    /// Human resolution label of the downloaded file (e.g. "1080p", "4K", "1920×1080"),
    /// captured from the chosen `Media` at download time. Drives the offline caption.
    /// Replaces the retired bitrate-cap `quality` marker (offline-download redesign).
    public var resolutionLabel: String?
    public var librarySectionID: Int?
    public var librarySectionKey: String?
    public var mediaIndex: Int?
    public var partIndex: Int?
    /// The source part id selected when the download was enqueued. Used to distinguish original
    /// source parts from later server-rendered optimized parts after an app relaunch.
    public var sourcePartID: Int?
    /// Non-nil while/when this row represents a server-side optimize/download route. Lets the
    /// app resume "Preparing on server…" rows that have no URLSession task yet.
    public var optimizeTargetName: String?
    /// VisionPlay-marked server optimize queue title for this row, when known. Persisted so an
    /// app relaunch can keep protecting/resuming the server-side render.
    public var optimizeQueueTitle: String?
    /// Part ids present on the source item immediately before the optimize job was created.
    /// Any later part not in this set is a candidate optimized output.
    public var optimizeBaselinePartIDs: [Int]?
    /// Locally-cached poster path, relative to the Downloads base directory.
    public var posterRelativePath: String?
    /// Locally-cached Plex BIF index path, relative to the Downloads base directory.
    /// Populated only for Plex items/parts that advertise a standard-definition BIF.
    public var plexBIFRelativePath: String?
    /// Locally-cached Jellyfin trickplay playlist path, relative to the Downloads base directory.
    /// The cached playlist is sanitized: tile lines are rewritten to local filenames and never
    /// contain token-bearing server URLs.
    public var jellyfinTrickPlayPlaylistRelativePath: String?
    /// Locally-cached Jellyfin trickplay tile sheet paths, relative to the Downloads base directory.
    public var jellyfinTrickPlayTileRelativePaths: [String]?
    /// Locally-cached external text subtitles for original downloads. Embedded subtitles remain
    /// discoverable through AVFoundation; image/burned-in/unavailable tracks are intentionally
    /// not represented here.
    public var offlineTextSubtitles: [OfflineTextSubtitleTrack]?

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
                grandparentTitle: String? = nil,
                grandparentRatingKey: String? = nil,
                grandparentThumb: String? = nil,
                parentTitle: String? = nil,
                parentRatingKey: String? = nil,
                parentThumb: String? = nil,
                parentIndex: Int? = nil,
                index: Int? = nil,
                thumb: String? = nil,
                art: String? = nil,
                chapters: [OfflineChapter]? = nil,
                resolutionLabel: String? = nil,
                librarySectionID: Int? = nil,
                librarySectionKey: String? = nil,
                mediaIndex: Int? = nil,
                partIndex: Int? = nil,
                sourcePartID: Int? = nil,
                optimizeTargetName: String? = nil,
                optimizeQueueTitle: String? = nil,
                optimizeBaselinePartIDs: [Int]? = nil,
                posterRelativePath: String? = nil,
                plexBIFRelativePath: String? = nil,
                jellyfinTrickPlayPlaylistRelativePath: String? = nil,
                jellyfinTrickPlayTileRelativePaths: [String]? = nil,
                offlineTextSubtitles: [OfflineTextSubtitleTrack]? = nil) {
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
        self.grandparentTitle = grandparentTitle
        self.grandparentRatingKey = grandparentRatingKey
        self.grandparentThumb = grandparentThumb
        self.parentTitle = parentTitle
        self.parentRatingKey = parentRatingKey
        self.parentThumb = parentThumb
        self.parentIndex = parentIndex
        self.index = index
        self.thumb = thumb
        self.art = art
        self.chapters = chapters
        self.resolutionLabel = resolutionLabel
        self.librarySectionID = librarySectionID
        self.librarySectionKey = librarySectionKey
        self.mediaIndex = mediaIndex
        self.partIndex = partIndex
        self.sourcePartID = sourcePartID
        self.optimizeTargetName = optimizeTargetName
        self.optimizeQueueTitle = optimizeQueueTitle
        self.optimizeBaselinePartIDs = optimizeBaselinePartIDs
        self.posterRelativePath = posterRelativePath
        self.plexBIFRelativePath = plexBIFRelativePath
        self.jellyfinTrickPlayPlaylistRelativePath = jellyfinTrickPlayPlaylistRelativePath
        self.jellyfinTrickPlayTileRelativePaths = jellyfinTrickPlayTileRelativePaths
        self.offlineTextSubtitles = offlineTextSubtitles
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
        grandparentTitle = try c.decodeIfPresent(String.self, forKey: .grandparentTitle)
        grandparentRatingKey = try c.decodeIfPresent(String.self, forKey: .grandparentRatingKey)
        grandparentThumb = try c.decodeIfPresent(String.self, forKey: .grandparentThumb)
        parentTitle = try c.decodeIfPresent(String.self, forKey: .parentTitle)
        parentRatingKey = try c.decodeIfPresent(String.self, forKey: .parentRatingKey)
        parentThumb = try c.decodeIfPresent(String.self, forKey: .parentThumb)
        parentIndex = try c.decodeIfPresent(Int.self, forKey: .parentIndex)
        index = try c.decodeIfPresent(Int.self, forKey: .index)
        thumb = try c.decodeIfPresent(String.self, forKey: .thumb)
        art = try c.decodeIfPresent(String.self, forKey: .art)
        chapters = try c.decodeIfPresent([OfflineChapter].self, forKey: .chapters)
        resolutionLabel = try c.decodeIfPresent(String.self, forKey: .resolutionLabel)
        librarySectionID = try c.decodeIfPresent(Int.self, forKey: .librarySectionID)
        librarySectionKey = try c.decodeIfPresent(String.self, forKey: .librarySectionKey)
        mediaIndex = try c.decodeIfPresent(Int.self, forKey: .mediaIndex)
        partIndex = try c.decodeIfPresent(Int.self, forKey: .partIndex)
        sourcePartID = try c.decodeIfPresent(Int.self, forKey: .sourcePartID)
        optimizeTargetName = try c.decodeIfPresent(String.self, forKey: .optimizeTargetName)
        optimizeQueueTitle = try c.decodeIfPresent(String.self, forKey: .optimizeQueueTitle)
        optimizeBaselinePartIDs = try c.decodeIfPresent([Int].self, forKey: .optimizeBaselinePartIDs)
        posterRelativePath = try c.decodeIfPresent(String.self, forKey: .posterRelativePath)
        plexBIFRelativePath = try c.decodeIfPresent(String.self, forKey: .plexBIFRelativePath)
        jellyfinTrickPlayPlaylistRelativePath = try c.decodeIfPresent(String.self, forKey: .jellyfinTrickPlayPlaylistRelativePath)
        jellyfinTrickPlayTileRelativePaths = try c.decodeIfPresent([String].self, forKey: .jellyfinTrickPlayTileRelativePaths)
        offlineTextSubtitles = try c.decodeIfPresent([OfflineTextSubtitleTrack].self, forKey: .offlineTextSubtitles)
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
                  chapters: chapters?.map { $0.makeChapter() },
                  contentRating: contentRating,
                  tagline: tagline,
                  grandparentTitle: grandparentTitle,
                  grandparentRatingKey: grandparentRatingKey,
                  grandparentThumb: grandparentThumb,
                  parentTitle: parentTitle,
                  parentRatingKey: parentRatingKey,
                  parentThumb: parentThumb,
                  parentIndex: parentIndex,
                  index: index)
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
/// D5); `posterURL` is the re-resolved absolute path to the cached poster, if any,
/// and `plexBIFURL` is the re-resolved cached Plex trick-play index for offline scrubbing.
public struct DownloadRecord: Identifiable, Codable, Sendable, Equatable {
    public let ratingKey: String
    public let title: String
    public let localURL: URL
    public var bytes: Int
    public var progress: Double
    public var status: DownloadStatus
    public var metadata: OfflineMetadata?
    public var posterURL: URL?
    public var plexBIFURL: URL?
    public var jellyfinTrickPlayPlaylistURL: URL?
    /// Bytes occupied by sidecar/offline assets (poster, trickplay, subtitles). Filled by the app
    /// store when records are hydrated; not persisted in the media row itself.
    public var sideAssetBytes: Int

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
                posterURL: URL? = nil,
                plexBIFURL: URL? = nil,
                jellyfinTrickPlayPlaylistURL: URL? = nil,
                sideAssetBytes: Int = 0) {
        self.ratingKey = ratingKey
        self.title = title
        self.localURL = localURL
        self.bytes = bytes
        self.progress = progress
        self.status = status
        self.metadata = metadata
        self.posterURL = posterURL
        self.plexBIFURL = plexBIFURL
        self.jellyfinTrickPlayPlaylistURL = jellyfinTrickPlayPlaylistURL
        self.sideAssetBytes = sideAssetBytes
    }

    enum CodingKeys: String, CodingKey {
        case ratingKey, title, localURL, bytes, progress, status, metadata, posterURL, plexBIFURL
        case jellyfinTrickPlayPlaylistURL, sideAssetBytes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ratingKey = try c.decode(String.self, forKey: .ratingKey)
        title = try c.decode(String.self, forKey: .title)
        localURL = try c.decode(URL.self, forKey: .localURL)
        bytes = try c.decodeIfPresent(Int.self, forKey: .bytes) ?? 0
        progress = try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        status = try c.decodeIfPresent(DownloadStatus.self, forKey: .status)
            ?? DownloadStatus.migratedStatus(forLegacyProgress: progress)
        metadata = try c.decodeIfPresent(OfflineMetadata.self, forKey: .metadata)
        posterURL = try c.decodeIfPresent(URL.self, forKey: .posterURL)
        plexBIFURL = try c.decodeIfPresent(URL.self, forKey: .plexBIFURL)
        jellyfinTrickPlayPlaylistURL = try c.decodeIfPresent(URL.self, forKey: .jellyfinTrickPlayPlaylistURL)
        sideAssetBytes = try c.decodeIfPresent(Int.self, forKey: .sideAssetBytes) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ratingKey, forKey: .ratingKey)
        try c.encode(title, forKey: .title)
        try c.encode(localURL, forKey: .localURL)
        try c.encode(bytes, forKey: .bytes)
        try c.encode(progress, forKey: .progress)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(metadata, forKey: .metadata)
        try c.encodeIfPresent(posterURL, forKey: .posterURL)
        try c.encodeIfPresent(plexBIFURL, forKey: .plexBIFURL)
        try c.encodeIfPresent(jellyfinTrickPlayPlaylistURL, forKey: .jellyfinTrickPlayPlaylistURL)
        try c.encode(sideAssetBytes, forKey: .sideAssetBytes)
    }
}
