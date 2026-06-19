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
    /// Human resolution label of the downloaded file (e.g. "1080p", "4K", "1920×1080"),
    /// captured from the chosen `Media` at download time. Drives the offline caption.
    /// Replaces the retired bitrate-cap `quality` marker (offline-download redesign).
    public var resolutionLabel: String?
    public var librarySectionID: Int?
    public var librarySectionKey: String?
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
                resolutionLabel: String? = nil,
                librarySectionID: Int? = nil,
                librarySectionKey: String? = nil,
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
        self.resolutionLabel = resolutionLabel
        self.librarySectionID = librarySectionID
        self.librarySectionKey = librarySectionKey
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
        resolutionLabel = try c.decodeIfPresent(String.self, forKey: .resolutionLabel)
        librarySectionID = try c.decodeIfPresent(Int.self, forKey: .librarySectionID)
        librarySectionKey = try c.decodeIfPresent(String.self, forKey: .librarySectionKey)
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
