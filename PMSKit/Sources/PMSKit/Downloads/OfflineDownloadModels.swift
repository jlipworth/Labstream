import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Explicit lifecycle state for a download, persisted so a relaunch can tell a
/// FINISHED transfer from a STALLED one. Previously completion was inferred from
/// `progress >= 1.0`, which can't distinguish a job that died mid-flight (the
/// progress just freezes) from one that genuinely finished — see D2 in research/14.
public enum DownloadStatus: String, Codable, Sendable, Equatable {
    case queued        // seeded, transfer not yet started / no live task yet
    // Emby convert-then-download: the server is rendering a persistent converted file (an Emby
    // "Convert Media" Sync job) before any byte download begins. Distinct from `.downloading`
    // (no URLSession task yet) and from `.queued` (a `.preparing` row carries a server-side
    // `embyConvertJobID` and resumes polling — not a dead transfer — across relaunch). The
    // conversion runs server-side and survives app death, so a `.preparing` row is never a stale
    // transfer; launch reconciliation keeps it `.preparing` and the app re-drives polling.
    case preparing     // server-side convert job rendering the file; no byte download yet
    case downloading   // a background task is actively writing bytes
    case complete      // validated file is on disk and playable
    // #98: the byte transfer completed, but the local AVPlayer startup probe did not confirm
    // playback. Keep the file playable/inspectable instead of deleting it or forcing a 0% retry;
    // the row remains explicitly distinct from a validated `.complete` download.
    case unverified    // complete file kept; playback probe was inconclusive/failed
    case failed        // transfer or validation failed; row kept so it can be retried
    // #95: a recoverable interruption (e.g. headset-off killed the transfer) that handed back
    // URLSession resume data. NOT a failure — the partial bytes + resume blob are retained so a
    // Resume continues from the offset instead of restarting at 0. Decoded with `decodeIfPresent`
    // on the row, so libraries persisted before this case keep loading.
    case paused        // interrupted but resumable from persisted resume data

    /// Default lifecycle status for a row persisted BEFORE D2, which lacked an
    /// explicit `status` field (completion was inferred from `progress >= 1.0`).
    ///
    /// A finished-looking row maps to `.complete`, anything else to `.queued`
    /// (launch reconciliation then re-checks it against disk). Decoders should call
    /// this only when no `status` is present on the row.
    public static func migratedStatus(forLegacyProgress progress: Double) -> DownloadStatus {
        progress >= 1.0 ? .complete : .queued
    }

    /// True while this row represents work the app/server is still doing.
    ///
    /// `.preparing` is intentionally active: Emby convert-then-download has no URLSession task yet,
    /// but a server-side Sync job may already be rendering. UI affordances and duplicate-enqueue
    /// guards must treat it like `.queued` / `.downloading`, not like an idle row.
    public var isActiveWork: Bool {
        switch self {
        case .queued, .preparing, .downloading:
            return true
        case .complete, .unverified, .failed, .paused:
            return false
        }
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
    ///
    /// `hasResumeData` (#95) is true when a persisted URLSession resume blob exists for the
    /// row. A `.paused` row stays resumable across relaunch IFF that blob survived; without it
    /// the partial can't be continued, so it demotes to `.failed` (retryable from 0).
    public static func reconciledStatus(current: DownloadStatus,
                                        fileExists: Bool,
                                        hasLiveTask: Bool,
                                        hasResumeData: Bool = false) -> DownloadStatus {
        switch current {
        case .preparing:
            // The convert job runs server-side and survives app death, so a `.preparing` row is
            // never a dead transfer: keep it `.preparing` so the app resumes polling the Sync job
            // (which fails the row itself if the job is gone). No local file exists yet, so the
            // disk check is irrelevant here.
            return .preparing
        case .complete:
            // A completed row is only usable if its validated file still exists.
            return fileExists ? .complete : .failed
        case .unverified:
            // A probe-inconclusive completed row is still useful only while the file remains.
            return fileExists ? .unverified : .failed
        case .queued, .downloading:
            if hasLiveTask { return current }   // task survived; leave it
            // No live task and never validated -> can't trust it; make it retryable.
            return .failed
        case .paused:
            // A recoverable interruption stays resumable only while its resume blob persists;
            // if the task is somehow live again, let it run.
            if hasLiveTask { return .downloading }
            return hasResumeData ? .paused : .failed
        case .failed:
            return .failed
        }
    }

    /// Reconcile runs off-main in the reattach completion while the main actor keeps seeding new
    /// rows. A row created AFTER the live-task snapshot was captured is inherently absent from
    /// that snapshot's live-key set, so judging it against the snapshot demotes a healthy fresh
    /// `.queued` row to `.failed` (and deletes its destination file). Only rows that already
    /// existed at snapshot time are eligible for reconciliation.
    public static func reconcileEligible(ratingKey: String,
                                         snapshotRatingKeys: Set<String>) -> Bool {
        snapshotRatingKeys.contains(ratingKey)
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
    /// Original server thumbnail key. Offline downloads may also cache the resolved binary chapter
    /// image as a side asset; keeping this key preserves the source mapping for retries/migrations.
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


/// Codable intro/credits/commercial marker snapshot for offline playback. `Marker` itself
/// is intentionally only Decodable for server DTOs, so the download index stores this
/// stable app-owned shape alongside chapters.
public struct OfflineMarker: Codable, Sendable, Equatable {
    public var markerID: Int?
    public var type: String
    public var startTimeOffset: Int?
    public var endTimeOffset: Int?
    public var isFinal: Bool?

    public init(markerID: Int? = nil, type: String, startTimeOffset: Int? = nil,
                endTimeOffset: Int? = nil, isFinal: Bool? = nil) {
        self.markerID = markerID
        self.type = type
        self.startTimeOffset = startTimeOffset
        self.endTimeOffset = endTimeOffset
        self.isFinal = isFinal
    }

    public init(_ marker: Marker) {
        self.init(markerID: marker.markerID,
                  type: marker.type,
                  startTimeOffset: marker.startTimeOffset,
                  endTimeOffset: marker.endTimeOffset,
                  isFinal: marker.isFinal)
    }

    public func makeMarker() -> Marker {
        Marker(id: markerID,
               type: type,
               startTimeOffset: startTimeOffset,
               endTimeOffset: endTimeOffset,
               isFinal: isFinal)
    }
}

/// Which download lane produced a persisted row (#83). The lane is NOT recoverable from
/// `optimizeTargetName` alone — original (no target) and compatible-remux (no target) would be
/// indistinguishable — so it is persisted explicitly and consulted by `retry*` /
/// `resumePendingServerPrepDownloads`. Absent on rows written before #83: callers fall back to the
/// legacy "presence of `optimizeTargetName`" inference, which still maps original↔optimize
/// correctly for those rows (they never used the compatible lane).
public enum DownloadLane: String, Codable, Sendable, Equatable {
    /// Byte-for-byte original file (range-resumable).
    case original
    /// Bitrate-capped server transcode to a preset (forward-only).
    case optimize
    /// #83: original-quality compatible remux — copy video, remux to MP4, audio→AAC as needed.
    /// Forward-only (a remux stream is not range-resumable), so it falls out of the resume-data
    /// recovery path the other lanes use; restart-from-zero on failure.
    case compatibleRemux
}

/// Durable checkpoint/resume class for a download row (#131). This is deliberately
/// separate from `DownloadLane`: a row can be display-lane "optimize" while its
/// next resumable checkpoint is either server-prep polling (Plex/Emby convert) or
/// a forward-only live encoder stream (Jellyfin/Emby remux/transcode).
public enum DownloadResumeMode: String, Codable, Sendable, Equatable {
    /// A stable static object where byte-range / URLSession resume data may be trusted.
    case staticByteRange
    /// A durable server-side render/convert phase must be resumed before a static download.
    case serverPrepThenStatic
    /// A live encoder stream; byte-offset resume is unsafe/misleading.
    case liveForwardOnly

    public static func resolved(backend: DownloadBackendKind,
                                lane: DownloadLane,
                                optimizeTargetName: String? = nil,
                                embyConvertJobID: Int? = nil) -> DownloadResumeMode {
        if backend == .emby, embyConvertJobID != nil { return .serverPrepThenStatic }
        if backend == .plex, lane == .optimize, optimizeTargetName?.isEmpty == false {
            return .serverPrepThenStatic
        }
        if (backend == .jellyfin || backend == .emby), lane != .original {
            return .liveForwardOnly
        }
        return .staticByteRange
    }
}


/// Pure persistence policy for local offline playback resume positions.
///
/// Online streaming continues to report timeline to the server; this policy is only for
/// completed downloads whose local-file player has no server/token. Positions are persisted
/// per download row and clamped to the known media duration when available. A playhead very
/// close to EOF is treated as complete enough to restart at the beginning instead of reopening
/// on credits/a final frame.
public struct OfflinePlaybackPositionPolicy: Sendable, Equatable {
    public let minimumSavePositionMs: Int
    public let nearEndRestartThresholdMs: Int

    public init(minimumSavePositionMs: Int = 1_000,
                nearEndRestartThresholdMs: Int = 30_000) {
        self.minimumSavePositionMs = minimumSavePositionMs
        self.nearEndRestartThresholdMs = nearEndRestartThresholdMs
    }

    public static let standard = OfflinePlaybackPositionPolicy()

    public func persistedPositionMs(currentMs: Int, durationMs: Int?) -> Int {
        let nonNegative = max(0, currentMs)
        let clamped: Int
        if let durationMs, durationMs > 0 {
            clamped = min(nonNegative, durationMs)
            if durationMs > nearEndRestartThresholdMs,
               clamped >= max(0, durationMs - nearEndRestartThresholdMs) {
                return 0
            }
        } else {
            clamped = nonNegative
        }
        return clamped < minimumSavePositionMs ? 0 : clamped
    }

    public static func resolvedResumeOffsetMs(localPlaybackPositionMs: Int?,
                                              capturedViewOffsetMs: Int?,
                                              durationMs: Int?,
                                              policy: OfflinePlaybackPositionPolicy = .standard) -> Int? {
        if let localPlaybackPositionMs {
            return policy.persistedPositionMs(currentMs: localPlaybackPositionMs, durationMs: durationMs)
        }
        guard let capturedViewOffsetMs else { return nil }
        return policy.persistedPositionMs(currentMs: capturedViewOffsetMs, durationMs: durationMs)
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
    /// Last locally-observed playhead for this completed offline row. Distinct from
    /// `viewOffset`, which is the server snapshot captured when the download was enqueued.
    public var localPlaybackPositionMs: Int?
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
    /// existing Chapters tab without requiring network access. Per-chapter images, when available,
    /// are tracked separately as side-asset relative paths.
    public var chapters: [OfflineChapter]?
    /// Intro/credits/commercial ranges captured at download time so offline playback can power
    /// the existing Skip Intro / Skip Credits affordances without requiring network access.
    public var markers: [OfflineMarker]?
    /// Human resolution label of the downloaded file (e.g. "1080p", "4K", "1920×1080"),
    /// captured from the chosen `Media` at download time. Drives the offline caption.
    /// Replaces the retired bitrate-cap `quality` marker (offline-download redesign).
    public var resolutionLabel: String?
    /// User-facing download quality/profile selected when the row was queued. This preserves
    /// intent ("Requested: 4K 40 Mbps") separately from `resolutionLabel`, which may describe the
    /// final downloaded file or source media after backend-specific conversion/reuse behavior.
    public var requestedProfileLabel: String?
    /// Best bitrate to display for this saved row, in kbps. Static/original/existing-version rows
    /// use the selected source file's container bitrate; bitrate-capped transcode rows use the
    /// requested target cap. This gives completed downloads a compact, comparable label even when
    /// the profile name was only "Existing server version".
    public var downloadBitrateKbps: Int?
    public var librarySectionID: Int?
    public var librarySectionKey: String?
    public var mediaIndex: Int?
    public var partIndex: Int?
    /// The source part id selected when the download was enqueued. Used to distinguish original
    /// source parts from later server-rendered optimized parts after an app relaunch.
    public var sourcePartID: Int?
    /// Byte size of the selected source part when the server exposed one. Used as the best
    /// available expected size for compatible-remux streams that copy video but have no
    /// Content-Length, so progress/ETA can survive relaunch.
    public var sourcePartSize: Int?
    /// Non-nil while/when this row represents a server-side optimize/download route. Lets the
    /// app resume "Preparing on server…" rows that have no URLSession task yet.
    public var optimizeTargetName: String?
    /// Labstream-marked server optimize queue title for this row, when known. Persisted so an
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
    /// Locally-cached per-chapter image paths, keyed by the chapter's index (its position in
    /// `chapters`), relative to the Downloads base directory (#88/#89). Fetched at download time
    /// from each backend's chapter-image endpoint so the offline Chapters menu rail shows real
    /// thumbnails and the Emby offline scrubber has a coarse chapter-granularity preview source.
    /// Index-keyed (not array) because chapter indices aren't always contiguous and the Emby scrub
    /// provider maps a scrub target to a chapter index. nil/empty when no chapter carried an image.
    public var chapterImageRelativePaths: [Int: String]?
    /// Locally-cached external text subtitles for offline downloads. Embedded subtitles remain
    /// discoverable through AVFoundation; image/burned-in/unavailable tracks are intentionally
    /// not represented here.
    public var offlineTextSubtitles: [OfflineTextSubtitleTrack]?
    /// Backend that created this download. nil for rows persisted before #84 — see
    /// `resolvedBackendKind(ratingKey:)` for the migration fallback (ratingKey-prefix
    /// inference) that keeps already-downloaded libraries fully usable.
    public var backendKind: DownloadBackendKind?
    /// Resolved server base URL string for the owning backend at enqueue time. Used to
    /// match a persisted job to a live `BackendSession` and to validate resume.
    public var backendBaseURLString: String?
    /// Stable server identity (Plex machineIdentifier / JF-Emby serverId) when known.
    public var backendServerID: String?
    /// Jellyfin/Emby authenticated user id at enqueue time (server context for retry).
    public var backendUserID: String?
    /// Jellyfin/Emby media source id chosen for this download (needed to re-issue the
    /// transcode/original request on retry without re-deriving from a re-fetched item).
    public var mediaSourceID: String?
    /// Server play-session id for a transcoded JF/Emby (or Plex optimize) job, persisted
    /// so the encoder can be torn down after a hard app kill (was in-memory only).
    public var playSessionID: String?
    /// #83: which download lane produced this row. Persisted so a retry/resume after an app kill
    /// preserves the user's intent — original (no target) vs compatible-remux (no target) are
    /// otherwise indistinguishable. Absent on pre-#83 rows (see `resolvedDownloadLane`).
    public var downloadLane: DownloadLane?
    /// #131: durable checkpoint/resume class for this row. New rows persist this so retry/relaunch
    /// does not have to infer whether a row is byte-range resumable, server-prep resumable, or a
    /// live forward-only stream. Legacy rows derive the same value from backend/lane markers.
    public var resumeMode: DownloadResumeMode?
    /// #95: path (relative to the Downloads base dir) of the persisted URLSession resume blob
    /// for a `.paused` (recoverably-interrupted) download. Stored as a sibling file because the
    /// blob can be large. `nil` when the row isn't paused / has no resume data. Lets a manual
    /// Resume after relaunch continue from the byte offset via `downloadTask(withResumeData:)`
    /// instead of restarting at 0. Only range-resumable sources (static originals) ever set it.
    public var resumeDataRelativePath: String?
    /// Display-only byte count for a paused URLSession resume blob. Unlike `DownloadRecord.bytes`,
    /// this may include resumable OS-temp bytes from a continuous Range remainder that have not yet
    /// been appended to the durable partial. Only set while a surviving resume blob exists.
    public var resumeDisplayBytes: Int?
    /// Emby convert-then-download: the server-side "Convert Media" Sync job id for a `.preparing`
    /// row. Persisted so an app relaunch re-hydrates the row and RESUMES polling that job (rather
    /// than restarting the conversion), and so deleting a `.preparing` row can also cancel the
    /// server-side job via `DELETE /Sync/Jobs/{id}`. `nil` for every non-Emby-convert row.
    public var embyConvertJobID: Int?
    /// Emby convert-then-download: the FULL set of pre-existing `File` MediaSource ids on the item
    /// captured at convert-trigger time. Persisted so a relaunch-resume identifies the freshly
    /// converted source as "the one NOT in this set" — including when the item already had a PRIOR
    /// converted version (which `mediaSourceID` alone, the original source, would miss). `nil` for
    /// every non-Emby-convert row; empty when the snapshot couldn't be enumerated (the h264/mp4
    /// recency heuristic then disambiguates).
    public var embyConvertSnapshotIDs: [String]?
    /// Display-only marker: this row downloads a SERVER-PREPARED version (a transcoded copy the
    /// server rendered), not the user's true source file — the Emby convert-then-download output,
    /// the Emby #126 reuse of an existing converted version, and the Plex #112 existing-version
    /// download. All of those ride the `.original` static lane for byte-for-byte resumable transfer,
    /// so the lane alone can't distinguish them from a real original; this flag lets the UI badge
    /// them "Transcode" (consistent with on-demand optimize) instead of mislabelling them "Original".
    /// Purely cosmetic — it never affects the download/resume/rate mechanics, which stay lane-driven.
    /// `nil`/false for a genuine original (and every pre-existing row).
    public var serverPreparedVersion: Bool?
    /// #169: HTTP validator (`ETag`, else `Last-Modified`) captured from the first static byte-range
    /// range body. Sent as `If-Range` on later static Range requests so that if the server-side
    /// resource changes mid-download the server returns the whole NEW resource (200) — which the
    /// range lane replaces honestly — instead of a 206 that would append new bytes after a stale
    /// prefix and silently corrupt the file. `nil` until the first body completes / for
    /// non-byte-range rows.
    public var rangeValidator: String?
    /// Per-download-attempt identity token, minted when an attempt starts and cleared on
    /// cancel/delete and terminal failure. Stamped into every URLSession `taskDescription` this
    /// attempt creates (segment marker v2, opaque/open-ended attempt stamp) so adoption/reattach
    /// can reject a redelivered task from a PRIOR attempt or app life of the same ratingKey —
    /// ratingKey-only identity let old-rendition bytes splice into a re-download.
    public var downloadAttemptID: String?

    public init(ratingKey: String,
                key: String? = nil,
                title: String,
                type: String,
                year: Int? = nil,
                duration: Int? = nil,
                viewOffset: Int? = nil,
                localPlaybackPositionMs: Int? = nil,
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
                markers: [OfflineMarker]? = nil,
                resolutionLabel: String? = nil,
                requestedProfileLabel: String? = nil,
                downloadBitrateKbps: Int? = nil,
                librarySectionID: Int? = nil,
                librarySectionKey: String? = nil,
                mediaIndex: Int? = nil,
                partIndex: Int? = nil,
                sourcePartID: Int? = nil,
                sourcePartSize: Int? = nil,
                optimizeTargetName: String? = nil,
                optimizeQueueTitle: String? = nil,
                optimizeBaselinePartIDs: [Int]? = nil,
                posterRelativePath: String? = nil,
                plexBIFRelativePath: String? = nil,
                jellyfinTrickPlayPlaylistRelativePath: String? = nil,
                jellyfinTrickPlayTileRelativePaths: [String]? = nil,
                chapterImageRelativePaths: [Int: String]? = nil,
                offlineTextSubtitles: [OfflineTextSubtitleTrack]? = nil,
                backendKind: DownloadBackendKind? = nil,
                backendBaseURLString: String? = nil,
                backendServerID: String? = nil,
                backendUserID: String? = nil,
                mediaSourceID: String? = nil,
                playSessionID: String? = nil,
                downloadLane: DownloadLane? = nil,
                resumeMode: DownloadResumeMode? = nil,
                resumeDataRelativePath: String? = nil,
                resumeDisplayBytes: Int? = nil,
                embyConvertJobID: Int? = nil,
                embyConvertSnapshotIDs: [String]? = nil,
                serverPreparedVersion: Bool? = nil,
                rangeValidator: String? = nil,
                downloadAttemptID: String? = nil) {
        self.ratingKey = ratingKey
        self.key = key
        self.title = title
        self.type = type
        self.year = year
        self.duration = duration
        self.viewOffset = viewOffset
        self.localPlaybackPositionMs = localPlaybackPositionMs
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
        self.markers = markers
        self.resolutionLabel = resolutionLabel
        self.requestedProfileLabel = requestedProfileLabel
        self.downloadBitrateKbps = downloadBitrateKbps
        self.librarySectionID = librarySectionID
        self.librarySectionKey = librarySectionKey
        self.mediaIndex = mediaIndex
        self.partIndex = partIndex
        self.sourcePartID = sourcePartID
        self.sourcePartSize = sourcePartSize
        self.optimizeTargetName = optimizeTargetName
        self.optimizeQueueTitle = optimizeQueueTitle
        self.optimizeBaselinePartIDs = optimizeBaselinePartIDs
        self.posterRelativePath = posterRelativePath
        self.plexBIFRelativePath = plexBIFRelativePath
        self.jellyfinTrickPlayPlaylistRelativePath = jellyfinTrickPlayPlaylistRelativePath
        self.jellyfinTrickPlayTileRelativePaths = jellyfinTrickPlayTileRelativePaths
        self.chapterImageRelativePaths = chapterImageRelativePaths
        self.offlineTextSubtitles = offlineTextSubtitles
        self.backendKind = backendKind
        self.backendBaseURLString = backendBaseURLString
        self.backendServerID = backendServerID
        self.backendUserID = backendUserID
        self.mediaSourceID = mediaSourceID
        self.playSessionID = playSessionID
        self.downloadLane = downloadLane
        self.resumeMode = resumeMode
        self.resumeDataRelativePath = resumeDataRelativePath
        self.resumeDisplayBytes = resumeDisplayBytes
        self.embyConvertJobID = embyConvertJobID
        self.embyConvertSnapshotIDs = embyConvertSnapshotIDs
        self.serverPreparedVersion = serverPreparedVersion
        self.rangeValidator = rangeValidator
        self.downloadAttemptID = downloadAttemptID
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
        localPlaybackPositionMs = try c.decodeIfPresent(Int.self, forKey: .localPlaybackPositionMs)
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
        markers = try c.decodeIfPresent([OfflineMarker].self, forKey: .markers)
        resolutionLabel = try c.decodeIfPresent(String.self, forKey: .resolutionLabel)
        requestedProfileLabel = try c.decodeIfPresent(String.self, forKey: .requestedProfileLabel)
        downloadBitrateKbps = try c.decodeIfPresent(Int.self, forKey: .downloadBitrateKbps)
        librarySectionID = try c.decodeIfPresent(Int.self, forKey: .librarySectionID)
        librarySectionKey = try c.decodeIfPresent(String.self, forKey: .librarySectionKey)
        mediaIndex = try c.decodeIfPresent(Int.self, forKey: .mediaIndex)
        partIndex = try c.decodeIfPresent(Int.self, forKey: .partIndex)
        sourcePartID = try c.decodeIfPresent(Int.self, forKey: .sourcePartID)
        sourcePartSize = try c.decodeIfPresent(Int.self, forKey: .sourcePartSize)
        optimizeTargetName = try c.decodeIfPresent(String.self, forKey: .optimizeTargetName)
        optimizeQueueTitle = try c.decodeIfPresent(String.self, forKey: .optimizeQueueTitle)
        optimizeBaselinePartIDs = try c.decodeIfPresent([Int].self, forKey: .optimizeBaselinePartIDs)
        posterRelativePath = try c.decodeIfPresent(String.self, forKey: .posterRelativePath)
        plexBIFRelativePath = try c.decodeIfPresent(String.self, forKey: .plexBIFRelativePath)
        jellyfinTrickPlayPlaylistRelativePath = try c.decodeIfPresent(String.self, forKey: .jellyfinTrickPlayPlaylistRelativePath)
        jellyfinTrickPlayTileRelativePaths = try c.decodeIfPresent([String].self, forKey: .jellyfinTrickPlayTileRelativePaths)
        chapterImageRelativePaths = try c.decodeIfPresent([Int: String].self, forKey: .chapterImageRelativePaths)
        offlineTextSubtitles = try c.decodeIfPresent([OfflineTextSubtitleTrack].self, forKey: .offlineTextSubtitles)
        backendKind = try c.decodeIfPresent(DownloadBackendKind.self, forKey: .backendKind)
        backendBaseURLString = try c.decodeIfPresent(String.self, forKey: .backendBaseURLString)
        backendServerID = try c.decodeIfPresent(String.self, forKey: .backendServerID)
        backendUserID = try c.decodeIfPresent(String.self, forKey: .backendUserID)
        mediaSourceID = try c.decodeIfPresent(String.self, forKey: .mediaSourceID)
        playSessionID = try c.decodeIfPresent(String.self, forKey: .playSessionID)
        downloadLane = try c.decodeIfPresent(DownloadLane.self, forKey: .downloadLane)
        resumeMode = try c.decodeIfPresent(DownloadResumeMode.self, forKey: .resumeMode)
        resumeDataRelativePath = try c.decodeIfPresent(String.self, forKey: .resumeDataRelativePath)
        resumeDisplayBytes = try c.decodeIfPresent(Int.self, forKey: .resumeDisplayBytes)
        embyConvertJobID = try c.decodeIfPresent(Int.self, forKey: .embyConvertJobID)
        embyConvertSnapshotIDs = try c.decodeIfPresent([String].self, forKey: .embyConvertSnapshotIDs)
        serverPreparedVersion = try c.decodeIfPresent(Bool.self, forKey: .serverPreparedVersion)
        rangeValidator = try c.decodeIfPresent(String.self, forKey: .rangeValidator)
        downloadAttemptID = try c.decodeIfPresent(String.self, forKey: .downloadAttemptID)
    }

    /// Preserve local side/durable assets that may have been cached or checkpointed asynchronously
    /// after the caller captured an older metadata snapshot. Download rows are upserted several
    /// times during handoff/retry/final transfer; without this merge, a later upsert carrying a
    /// stale-but-non-nil metadata value can erase poster/trickplay/chapter/subtitle paths or
    /// resumability/checkpoint facts that another task just persisted.
    public mutating func preserveCachedSideAssets(from previous: OfflineMetadata) {
        if posterRelativePath == nil {
            posterRelativePath = previous.posterRelativePath
        }
        if plexBIFRelativePath == nil {
            plexBIFRelativePath = previous.plexBIFRelativePath
        }
        if jellyfinTrickPlayPlaylistRelativePath == nil {
            jellyfinTrickPlayPlaylistRelativePath = previous.jellyfinTrickPlayPlaylistRelativePath
        }
        if (jellyfinTrickPlayTileRelativePaths?.isEmpty ?? true) {
            jellyfinTrickPlayTileRelativePaths = previous.jellyfinTrickPlayTileRelativePaths
        }
        if (chapterImageRelativePaths?.isEmpty ?? true) {
            chapterImageRelativePaths = previous.chapterImageRelativePaths
        }
        if (offlineTextSubtitles?.isEmpty ?? true) {
            offlineTextSubtitles = previous.offlineTextSubtitles
        }
        if resumeDataRelativePath == nil {
            resumeDataRelativePath = previous.resumeDataRelativePath
        }
        if resumeDisplayBytes == nil {
            resumeDisplayBytes = previous.resumeDisplayBytes
        }
        if rangeValidator == nil {
            rangeValidator = previous.rangeValidator
        }
        // Mid-attempt metadata upserts (handoff/retry re-snapshots) must not wipe the live
        // attempt token; cancel/terminal-failure clear it explicitly, so a stale token can never
        // survive into a genuinely new attempt through this merge.
        if downloadAttemptID == nil {
            downloadAttemptID = previous.downloadAttemptID
        }
        if sourcePartSize == nil {
            sourcePartSize = previous.sourcePartSize
        }
        if requestedProfileLabel == nil {
            requestedProfileLabel = previous.requestedProfileLabel
        }
        if downloadBitrateKbps == nil {
            downloadBitrateKbps = previous.downloadBitrateKbps
        }
    }

    /// Display helper: true when this row downloads a server-prepared (transcoded) version rather
    /// than the genuine source — see `serverPreparedVersion`. Used by the offline UI to badge it
    /// "Transcode" even though it rides the `.original` static lane.
    public var isServerPreparedVersion: Bool { serverPreparedVersion == true }

    /// #83: resolve this row's lane. New rows persist `downloadLane`; pre-#83 rows fall back to the
    /// legacy inference (optimize ⇔ a non-empty `optimizeTargetName`, else original) — correct for
    /// those rows because the compatible-remux lane did not exist when they were written.
    public func resolvedDownloadLane() -> DownloadLane {
        if let downloadLane { return downloadLane }
        return (optimizeTargetName?.isEmpty == false) ? .optimize : .original
    }

    /// #131: resolve the checkpoint/resume class. New rows persist `resumeMode`; legacy rows derive
    /// from backend/lane/job markers so old offline libraries keep safe restart semantics.
    public func resolvedResumeMode(ratingKey: String) -> DownloadResumeMode {
        if let resumeMode { return resumeMode }
        return DownloadResumeMode.resolved(backend: resolvedBackendKind(ratingKey: ratingKey),
                                          lane: resolvedDownloadLane(),
                                          optimizeTargetName: optimizeTargetName,
                                          embyConvertJobID: embyConvertJobID)
    }

    /// Backend for this row. New rows store `backendKind`; pre-#84 rows fall back to
    /// the ratingKey prefix (`jellyfin:` / `emby:` / bare = Plex). This keeps already-
    /// downloaded libraries fully usable after the schema change.
    public func resolvedBackendKind(ratingKey: String) -> DownloadBackendKind {
        backendKind ?? DownloadBackendKind(ratingKeyPrefix: ratingKey)
    }

    public var offlineResumeOffsetMs: Int? {
        OfflinePlaybackPositionPolicy.resolvedResumeOffsetMs(localPlaybackPositionMs: localPlaybackPositionMs,
                                                            capturedViewOffsetMs: viewOffset,
                                                            durationMs: duration)
    }

    /// Reconstruct a faithful `MediaItem` for offline playback + retry. Only the
    /// fields we captured are populated; stream-level metadata isn't needed offline.
    public func makeMediaItem() -> MediaItem {
        MediaItem(ratingKey: ratingKey,
                  key: key,
                  title: title,
                  type: type,
                  duration: duration,
                  viewOffset: offlineResumeOffsetMs,
                  viewCount: viewCount,
                  year: year,
                  summary: summary,
                  thumb: thumb,
                  art: art,
                  chapters: chapters?.map { $0.makeChapter() },
                  markers: markers?.map { $0.makeMarker() },
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
    /// Re-resolved absolute cached per-chapter image URLs (chapter index → file), filled by the app
    /// store when records are hydrated (#88/#89). Feeds the offline Chapters rail and the Emby
    /// offline scrubber. Empty when no chapter images were cached.
    public var chapterImageURLs: [Int: URL]
    /// Bytes occupied by sidecar/offline assets (poster, trickplay, subtitles). Filled by the app
    /// store when records are hydrated; not persisted in the media row itself.
    public var sideAssetBytes: Int

    public var id: String { ratingKey }

    /// Convenience: a download has a finished local file that the user can try to play.
    /// Drives the player gate so a stalled-at-100% row never opens an empty file. `.unverified`
    /// rows (#98) are complete byte transfers preserved after an inconclusive local playback probe.
    public var isComplete: Bool { status == .complete || status == .unverified }

    /// True when the transfer completed but the local playback probe did not confirm startup.
    public var isUnverified: Bool { status == .unverified }

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
                chapterImageURLs: [Int: URL] = [:],
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
        self.chapterImageURLs = chapterImageURLs
        self.sideAssetBytes = sideAssetBytes
    }

    enum CodingKeys: String, CodingKey {
        case ratingKey, title, localURL, bytes, progress, status, metadata, posterURL, plexBIFURL
        case jellyfinTrickPlayPlaylistURL, chapterImageURLs, sideAssetBytes
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
        chapterImageURLs = try c.decodeIfPresent([Int: URL].self, forKey: .chapterImageURLs) ?? [:]
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
        if !chapterImageURLs.isEmpty { try c.encode(chapterImageURLs, forKey: .chapterImageURLs) }
        try c.encode(sideAssetBytes, forKey: .sideAssetBytes)
    }
}
