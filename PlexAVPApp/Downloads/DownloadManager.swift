import Foundation
import Observation
import PMSKit
import AVFoundation   // D1: AVURLAsset playability probe on a finished download
import os

/// Diagnostic log for the offline-download pipeline. Inspect with:
///   log show --predicate 'subsystem == "com.jlipworth.VisionPlex"' --last 10m
/// Only scrubbed values are logged — never the token or full URL (the transcode
/// URL carries `X-Plex-Token` as a query param), so we log `url.path` only.
let downloadLog = Logger(subsystem: "com.jlipworth.VisionPlex", category: "Downloads")

/// Coordinates the offline-download pipeline:
///   1. trigger a server-side capped-bitrate optimize (8 Mbps 1080p preset),
///   2. poll the item's metadata until the optimized `Part` appears,
///   3. fetch that part over a **background** `URLSession` into Application Support,
///   4. record it in `DownloadStore` (ratingKey -> local file, size, progress).
///
/// Offline playback reuses the custom player via `CustomPlayerView(localFile:item:)`.
///
/// The optimize trigger is the highest-uncertainty area in the whole app — see
/// `triggerOptimize(...)`. It is isolated behind that single method so the live
/// (server-specific playlist + targetTagID) path can be swapped in without
/// touching the rest of the pipeline.
@MainActor
@Observable
public final class DownloadManager {

    /// Surfaced failure/edge states for the UI. Not thrown — recorded so the
    /// `OfflineLibraryView` can show why a job didn't complete.
    public enum DownloadError: Error, Sendable, Equatable {
        case notAuthenticated
        case optimizeFailed(String)
        case optimizeTimedOut
        case noOptimizedPart
        case storageFull
        case transferFailed(String)
        /// The transfer finished with a 2xx but the body wasn't a usable video
        /// container (HTML/JSON error page, truncated transcode, unplayable). D1:
        /// previously such bodies were saved as "complete" and failed at playback.
        case invalidDownload(String)
    }

    /// A user-selectable download quality.
    ///
    /// Each case maps to a video-bitrate cap (kbps) handed to the SAME universal
    /// transcoder the player uses, via `TranscodeRequest.downloadURL()`. We download
    /// a single progressive MP4 at the chosen cap rather than going through the
    /// fragile server-side optimize queue (see `optimizeAndDownload(_:quality:)` for
    /// the rationale). `.original` requests "no cap" — we pass a very high ceiling so
    /// PMS still emits a compatible MP4 rather than rejecting an absent cap (mirrors
    /// the player's `0`-means-maximum convention in `PlaybackController`).
    public enum DownloadQuality: String, Sendable, Equatable, CaseIterable, Identifiable {
        case p480
        case p720
        case p1080
        case original

        public var id: String { rawValue }

        /// Human label for the picker.
        public var label: String {
            switch self {
            case .p480:     return "480p · 2 Mbps"
            case .p720:     return "720p · 4 Mbps"
            case .p1080:    return "1080p · 8 Mbps"
            case .original: return "Original / Maximum"
            }
        }

        /// Short caption for secondary text / accessibility.
        public var caption: String {
            switch self {
            case .p480:     return "Smallest file, lowest quality"
            case .p720:     return "Balanced size and quality"
            case .p1080:    return "Best quality for the headset"
            case .original: return "Largest file, source quality"
            }
        }

        /// Compact resolution marker for tight UI (the download progress caption).
        public var shortLabel: String {
            switch self {
            case .p480:     return "480p"
            case .p720:     return "720p"
            case .p1080:    return "1080p"
            case .original: return "Original"
            }
        }

        /// Video-bitrate cap in kbps handed to the transcoder. `nil` == no cap
        /// (original); the manager translates that to the transcoder's high ceiling.
        public var maxVideoBitrateKbps: Int? {
            switch self {
            case .p480:     return 2000
            case .p720:     return 4000
            case .p1080:    return 8000
            case .original: return nil
            }
        }

        /// The default offered to the user: the app-wide 1080p/8 Mbps cap.
        public static var `default`: DownloadQuality { .p1080 }
    }

    /// Live records (in-progress + completed), backed by `DownloadStore`.
    public private(set) var records: [DownloadRecord] = []

    /// ratingKeys with an active (optimize or transfer) job in flight.
    public private(set) var activeJobs: Set<String> = []

    /// Last error per ratingKey, for UI surfacing.
    public private(set) var lastError: [String: DownloadError] = [:]

    /// Smoothed transfer rate (bytes/sec) per actively-downloading ratingKey, derived
    /// in `refreshRecords` by diffing cumulative bytes between progress callbacks.
    /// Ephemeral (never persisted); drives the "x MB/s" + ETA readout in the UI.
    public private(set) var downloadSpeed: [String: Double] = [:]

    /// Last (bytes, time) sample per ratingKey, used to compute `downloadSpeed`.
    private var speedSamples: [String: (bytes: Int, time: Date)] = [:]

    private let appModel: AppModel
    private let store: DownloadStore
    private let session: BackgroundDownloadSession

    /// How long to poll the optimize queue before giving up.
    private let optimizePollTimeout: TimeInterval = 60 * 30   // 30 min
    private let optimizePollInterval: TimeInterval = 5

    init(appModel: AppModel) {
        self.appModel = appModel
        let store = DownloadStore()
        self.store = store
        self.session = BackgroundDownloadSession(store: store)
        self.records = store.records
        // Reattach to any transfers that survived a relaunch + receive progress.
        self.session.onChange = { [weak self] in
            Task { @MainActor in self?.refreshRecords() }
        }
        // D3: surface background-delegate failures instead of silently dropping the
        // row. The delegate records a `.failed` status in the store and hands us the
        // reason here so `lastError` can drive the OfflineLibraryView message + retry.
        self.session.onError = { [weak self] ratingKey, error in
            Task { @MainActor in
                self?.lastError[ratingKey] = error
                self?.refreshRecords()
            }
        }
        // D2: rows with no live task can't be told apart from a stall, so reconcile
        // them to `.failed` (retryable) once we know which tasks survived. The
        // `getAllTasks` completion lands off the main actor; the store is thread-safe,
        // so we reconcile there and hop to `@MainActor` only to publish records.
        self.session.reattach { [weak self, store] liveKeys in
            store.reconcile(liveRatingKeys: liveKeys)
            Task { @MainActor in self?.refreshRecords() }
        }
    }

    /// Absolute local URL for a completed download, if present on disk.
    public func localURL(for ratingKey: String) -> URL? {
        store.localURL(for: ratingKey)
    }

    /// Full pipeline: optimize -> poll -> background-download -> record.
    /// Records the resulting state (including any error) rather than throwing.
    public func optimizeAndDownload(_ item: MediaItem) async {
        let ratingKey = item.ratingKey
        guard let token = appModel.serverToken, let server = appModel.serverBaseURL else {
            lastError[ratingKey] = .notAuthenticated
            return
        }
        guard !activeJobs.contains(ratingKey) else { return }
        activeJobs.insert(ratingKey)
        lastError[ratingKey] = nil
        defer { activeJobs.remove(ratingKey) }

        // D5: snapshot metadata (no explicit quality on this legacy optimize path).
        let metadata = Self.offlineMetadata(from: item, quality: nil,
                                            mediaIndex: 0, partIndex: 0)
        // Seed a 0% record so the UI shows the job immediately.
        let seed = DownloadRecord(ratingKey: ratingKey, title: item.title,
                                  localURL: store.destinationURL(ratingKey: ratingKey, ext: "mp4"),
                                  bytes: 0, progress: 0, metadata: metadata)
        store.upsert(seed)
        refreshRecords()
        cachePoster(ratingKey: ratingKey, thumb: item.thumb ?? item.art,
                    server: server, token: token)

        do {
            try await triggerOptimize(item: item, server: server, token: token,
                                      identity: appModel.identity)
            let part = try await pollForOptimizedPart(ratingKey: ratingKey, server: server,
                                                      token: token, identity: appModel.identity)
            let ext = part.container ?? (part.file as NSString?)?.pathExtension ?? "mp4"
            let destination = store.destinationURL(ratingKey: ratingKey, ext: ext.isEmpty ? "mp4" : ext)
            store.upsert(DownloadRecord(ratingKey: ratingKey, title: item.title,
                                        localURL: destination, bytes: 0, progress: 0,
                                        metadata: metadata))
            refreshRecords()

            let downloadURL = OptimizeRequest.downloadURL(server: server, token: token, partKey: part.key)
            try session.start(ratingKey: ratingKey, from: downloadURL, to: destination,
                              expectedBytes: part.size)
            refreshRecords()
        } catch let error as DownloadError {
            // D3: keep a `.failed` row (with surfaced reason) instead of erasing it,
            // so the UI can explain the failure and offer a retry.
            lastError[ratingKey] = error
            store.setStatus(ratingKey: ratingKey, .failed)
            refreshRecords()
        } catch {
            lastError[ratingKey] = .transferFailed(String(describing: error))
            store.setStatus(ratingKey: ratingKey, .failed)
            refreshRecords()
        }
    }

    /// Download `item` at a user-chosen `quality` via the universal-transcode path.
    ///
    /// **Why this, not the optimize queue:** the legacy `optimizeAndDownload(_:)`
    /// above triggers a server-side OPTIMIZE (a `targetTagID` preset) and then polls
    /// for the resulting part. That path is the highest-uncertainty area in the app —
    /// the live `backgroundProcessing.key` + server-specific `targetTagID` are
    /// UNVERIFIED (see the big `TODO(live)` on `triggerOptimize`). This method instead
    /// reuses the SAME universal transcoder the player streams from
    /// (`TranscodeRequest.downloadURL()` with the `Safari` profile + `maxVideoBitrate`
    /// cap), asking for a single progressive MP4 we can fetch with one background
    /// `downloadTask`. That contract is verified end-to-end for streaming, so it's the
    /// reliable way to honor a chosen quality offline. No optimize queue, no polling.
    ///
    /// Records state (including any error) rather than throwing. Keeps the existing
    /// background `URLSession` transfer machinery, so it survives suspension/relaunch.
    public func optimizeAndDownload(_ item: MediaItem,
                                    quality: DownloadQuality,
                                    mediaIndex: Int = 0,
                                    partIndex: Int = 0) async {
        let ratingKey = item.ratingKey
        guard let token = appModel.serverToken, let server = appModel.serverBaseURL else {
            lastError[ratingKey] = .notAuthenticated
            return
        }
        guard !activeJobs.contains(ratingKey) else { return }
        activeJobs.insert(ratingKey)
        lastError[ratingKey] = nil
        defer { activeJobs.remove(ratingKey) }

        // The transcoded download always lands as an MP4 (we ask `protocol=http`).
        let destination = store.destinationURL(ratingKey: ratingKey, ext: "mp4")
        // D5: snapshot the source item + chosen quality so the offline library renders
        // richly without the server and `retry()` can rebuild a faithful MediaItem.
        let metadata = Self.offlineMetadata(from: item, quality: quality,
                                            mediaIndex: mediaIndex, partIndex: partIndex)
        // Seed a 0% record so the UI shows the job immediately.
        store.upsert(DownloadRecord(ratingKey: ratingKey, title: item.title,
                                    localURL: destination, bytes: 0, progress: 0,
                                    metadata: metadata))
        refreshRecords()
        // D5: cache the poster locally (best-effort) so artwork shows offline. A fetch
        // failure is not a download failure — it just leaves the row without a poster.
        cachePoster(ratingKey: ratingKey, thumb: item.thumb ?? item.art,
                    server: server, token: token)

        // `nil` cap (Original) maps to a very high ceiling so PMS still emits a
        // playable MP4 rather than rejecting an absent cap (mirrors PlaybackController).
        let cap = quality.maxVideoBitrateKbps ?? 200_000
        let metadataKey = item.key ?? "/library/metadata/\(ratingKey)"
        let transcode = TranscodeRequest(server: server,
                                         token: token,
                                         identity: appModel.identity,
                                         metadataKey: metadataKey,
                                         maxVideoBitrateKbps: cap,
                                         sessionID: "plex-avp-dl-" + UUID().uuidString,
                                         mediaIndex: mediaIndex,
                                         partIndex: partIndex)
        do {
            try session.start(ratingKey: ratingKey,
                              from: transcode.downloadURL(),
                              to: destination,
                              expectedBytes: Self.estimatedTranscodeBytes(
                                  quality: quality, durationMs: item.duration))
            refreshRecords()
        } catch let error as DownloadError {
            // D3: keep a `.failed` row (with surfaced reason) instead of erasing it,
            // so the UI can explain the failure and offer a retry.
            lastError[ratingKey] = error
            store.setStatus(ratingKey: ratingKey, .failed)
            refreshRecords()
        } catch {
            lastError[ratingKey] = .transferFailed(String(describing: error))
            store.setStatus(ratingKey: ratingKey, .failed)
            refreshRecords()
        }
    }

    /// Whether a download already exists (completed or in-flight) for `ratingKey`.
    /// Lets the options sheet show "Downloaded" / disable re-download.
    public func hasDownload(for ratingKey: String) -> Bool {
        records.contains { $0.ratingKey == ratingKey }
    }

    /// Retry a previously `.failed` download (D3/D5). We rebuild the source `MediaItem`
    /// from the persisted `OfflineMetadata` snapshot (real type + the originally chosen
    /// quality) and re-run the verified universal-transcode path. Rows persisted before
    /// D5 lack a snapshot, so we fall back to a minimal movie at the default quality.
    public func retry(ratingKey: String) {
        guard let record = records.first(where: { $0.ratingKey == ratingKey }) else { return }
        lastError[ratingKey] = nil
        let metadata = record.metadata
        // Drop the stale `.failed` row so `optimizeAndDownload` re-seeds it cleanly;
        // this also removes any leftover invalid file from the failed attempt.
        store.remove(ratingKey: ratingKey)
        refreshRecords()
        let item = metadata?.makeMediaItem()
            ?? MediaItem(ratingKey: record.ratingKey, title: record.title, type: "movie")
        let quality = metadata?.quality.flatMap(DownloadQuality.init(rawValue:)) ?? .default
        let mediaIndex = metadata?.mediaIndex ?? 0
        let partIndex = metadata?.partIndex ?? 0
        Task { await optimizeAndDownload(item, quality: quality,
                                         mediaIndex: mediaIndex, partIndex: partIndex) }
    }

    /// Delete a download and its backing file.
    public func delete(ratingKey: String) {
        session.cancel(ratingKey: ratingKey)
        store.remove(ratingKey: ratingKey)
        lastError[ratingKey] = nil
        refreshRecords()
    }

    private func refreshRecords() {
        let now = Date()
        let fresh = store.records
        let activeKeys = Set(fresh.filter { $0.status == .downloading }.map(\.ratingKey))
        // Recompute a smoothed bytes/sec for each actively-downloading row by diffing
        // its cumulative byte count against the previous sample. Resample on a ≥1s
        // interval (a longer window yields a less noisy instantaneous rate) and fold it
        // into a heavily-weighted EMA (~4s memory) so the displayed speed — and the ETA
        // derived from it — drift smoothly instead of bouncing on every burst of the
        // rapid progress callbacks.
        for record in fresh where record.status == .downloading {
            guard let prev = speedSamples[record.ratingKey] else {
                speedSamples[record.ratingKey] = (record.bytes, now)
                continue
            }
            let dt = now.timeIntervalSince(prev.time)
            let db = record.bytes - prev.bytes
            if dt >= 1.0 && db > 0 {
                let instantaneous = Double(db) / dt
                let smoothed = downloadSpeed[record.ratingKey].map { 0.75 * $0 + 0.25 * instantaneous }
                    ?? instantaneous
                downloadSpeed[record.ratingKey] = smoothed
                speedSamples[record.ratingKey] = (record.bytes, now)
            }
        }
        // Drop samples for rows no longer downloading (complete / failed / removed).
        speedSamples = speedSamples.filter { activeKeys.contains($0.key) }
        downloadSpeed = downloadSpeed.filter { activeKeys.contains($0.key) }
        records = fresh
    }

    /// Estimated final byte size of a transcoded download, from the chosen quality cap
    /// × runtime. Plex streams the transcode without a `Content-Length` (so the download
    /// delegate's `totalBytesExpectedToWrite` is -1 and can't drive a %), so the UI uses
    /// this estimate for the progress bar + ETA. Returns nil when we can't estimate —
    /// Original has no fixed cap, or the runtime is unknown — and the UI then falls back
    /// to an indeterminate bar + byte count. A `+192 kbps` allowance covers the audio
    /// track PMS transcodes alongside the video.
    public static func estimatedTranscodeBytes(quality: DownloadQuality?, durationMs: Int?) -> Int? {
        guard let durationMs, durationMs > 0,
              let quality, let videoKbps = quality.maxVideoBitrateKbps else { return nil }
        let totalBitsPerSec = Double(videoKbps + 192) * 1000.0
        let seconds = Double(durationMs) / 1000.0
        return Int(totalBitsPerSec / 8.0 * seconds)
    }

    // MARK: - D5: offline metadata + poster caching

    /// Build the persisted snapshot of a source `MediaItem` + the chosen quality.
    /// Captures only the fields the offline UI/player/retry actually read.
    private static func offlineMetadata(from item: MediaItem,
                                        quality: DownloadQuality?,
                                        mediaIndex: Int,
                                        partIndex: Int) -> OfflineMetadata {
        OfflineMetadata(ratingKey: item.ratingKey,
                        key: item.key,
                        title: item.title,
                        type: item.type,
                        year: item.year,
                        duration: item.duration,
                        viewOffset: item.viewOffset,
                        viewCount: item.viewCount,
                        summary: item.summary,
                        contentRating: item.contentRating,
                        tagline: item.tagline,
                        thumb: item.thumb,
                        art: item.art,
                        quality: quality?.rawValue,
                        mediaIndex: mediaIndex,
                        partIndex: partIndex,
                        posterRelativePath: nil)
    }

    /// Download + cache the item's poster locally so the offline library shows artwork
    /// without the server (D5). Best-effort: any failure leaves the row poster-less and
    /// never fails the download. Fetches via the same `/photo/:/transcode` path the
    /// online `PosterImage` uses, with the same server + token as the media download.
    private func cachePoster(ratingKey: String, thumb: String?, server: URL, token: String) {
        guard let thumb, !thumb.isEmpty,
              let url = Self.posterTranscodeURL(thumb: thumb, server: server, token: token)
        else { return }
        let posterURL = store.posterDestinationURL(ratingKey: ratingKey)
        let store = self.store
        Task { @MainActor in
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse,
                   !(200...299).contains(http.statusCode) { return }
                guard !data.isEmpty else { return }
                try data.write(to: posterURL, options: .atomic)
                store.setPosterRelativePath(ratingKey: ratingKey,
                                            posterURL.lastPathComponent)
                self.refreshRecords()
            } catch {
                // No poster is fine — never surfaced as a download error.
            }
        }
    }

    /// Build the `/photo/:/transcode` URL for an image path, mirroring `PosterImage`.
    /// Requests a poster-sized image so the cached file stays small.
    private static func posterTranscodeURL(thumb: String, server: URL, token: String) -> URL? {
        var comps = URLComponents(url: server.appendingPathComponent("/photo/:/transcode"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            .init(name: "url", value: thumb),
            .init(name: "width", value: "400"),
            .init(name: "height", value: "600"),
            .init(name: "minSize", value: "1"),
            .init(name: "upscale", value: "1"),
            .init(name: "X-Plex-Token", value: token),
        ]
        return comps?.url
    }

    // MARK: - Optimize trigger (HIGH UNCERTAINTY — isolated)

    /// Trigger the server-side optimized (capped-bitrate) version of `item`.
    ///
    /// // TODO(live): verify optimize endpoint + targetTagID against the live
    /// server (research/11). PMSKit's `OptimizeRequest.create` encodes a
    /// BEST-EFFORT contract: a flat `PUT /library/optimize` carrying
    /// `title`/`target`/`targetTagID` plus python-plexapi's nested `Item[...]`
    /// MediaSettings params. The REAL Plex optimize is NOT this static PUT — it
    /// posts to `{backgroundProcessing.key}/items`, where `backgroundProcessing.key`
    /// is fetched at runtime from `/playlists?type=42` (the background-processing
    /// playlist), and `targetTagID` is a SERVER-SPECIFIC id resolved from the
    /// server's `mediaProcessingTarget` tag list — NOT the conventional `2` we use
    /// for the 8 Mbps/1080p "Optimized for TV" preset here.
    ///
    /// This method is the ONLY place that path lives. To go live:
    ///   1. GET `/playlists?type=42` -> read `backgroundProcessing.key`,
    ///   2. resolve the real `targetTagID` from the server's target tags,
    ///   3. PUT to `{key}/items` with the `Item[...]` grammar.
    /// None of the rest of the pipeline changes.
    ///
    /// NOT VERIFIED against a live server. A non-2xx here is reported as
    /// `.optimizeFailed`; the caller still polls metadata so that if optimize was
    /// already triggered out-of-band the existing optimized part is picked up.
    private func triggerOptimize(item: MediaItem,
                                 server: URL,
                                 token: String,
                                 identity: ClientIdentity) async throws {
        let request = OptimizeRequest.create(
            server: server,
            token: token,
            identity: identity,
            ratingKey: item.ratingKey,
            title: item.title,
            targetTagID: .tv1080p8Mbps      // 8 Mbps 1080p preset (tagID best-effort = 2)
        )
        do {
            try await appModel.client.send(request)
        } catch let error as PlexError {
            // Don't hard-fail: the optimized part may already exist on the server.
            // We log the optimize-trigger failure but proceed to poll metadata.
            throw DownloadError.optimizeFailed(String(describing: error))
        }
    }

    // MARK: - Poll for optimized part

    /// Poll the item's metadata until an optimized (extra) `Part` shows up.
    ///
    /// Heuristic: the optimized version appears as an additional `Media`/`Part`
    /// alongside the original. We snapshot the original part ids first, then poll;
    /// the first part whose id is NOT in that original set is the optimized output.
    /// If the item had no media at all, we take the highest-id new part.
    private func pollForOptimizedPart(ratingKey: String,
                                      server: URL,
                                      token: String,
                                      identity: ClientIdentity) async throws -> Part {
        let originalPartIDs = Set((appModelItemMedia(ratingKey) ?? []).flatMap { $0.part.map(\.id) })
        let deadline = Date().addingTimeInterval(optimizePollTimeout)

        while Date() < deadline {
            let statusReq = OptimizeRequest.statusRequest(server: server, token: token,
                                                          identity: identity, ratingKey: ratingKey)
            if let response = try? await appModel.client.send(statusReq, as: MetadataResponse.self),
               let metadata = response.mediaContainer.metadata.first {
                let allParts = (metadata.media ?? []).flatMap { $0.part }
                if let newPart = allParts.first(where: { !originalPartIDs.contains($0.id) }) {
                    return newPart
                }
                // Fallback: if there was originally NO media, any part counts.
                if originalPartIDs.isEmpty, let only = allParts.last {
                    return only
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(optimizePollInterval * 1_000_000_000))
        }
        throw DownloadError.optimizeTimedOut
    }

    /// Best-effort: the media we already had for this item (used to diff parts).
    /// We don't cache full items here, so this returns nil and the poll treats all
    /// discovered parts as candidates (taking the last). Kept as a seam so a future
    /// caller can pass through the originally-loaded `MediaItem.media`.
    private func appModelItemMedia(_ ratingKey: String) -> [Media]? { nil }
}

/// Wraps a background `URLSession` so transfers survive app suspension and
/// relaunch. On visionOS the OS pauses background transfers while the headset is
/// OFF and resumes them when worn again — surface that reality in the UI
/// (research/10): a "download" is best-effort and may stall until the headset is
/// back on the user's head.
///
/// Delegate callbacks land off the main actor; we hop to `@MainActor` for record
/// updates via `onChange`. The store itself is internally locked.
final class BackgroundDownloadSession: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    /// The fixed background-session identifier. Shared with the app delegate so it can
    /// route `handleEventsForBackgroundURLSession` to THIS session's completion handler.
    static let identifier = "com.plexavp.downloads.background"

    private let store: DownloadStore
    private let fileManager = FileManager.default
    /// taskIdentifier -> (ratingKey, destination)
    private var inflight: [Int: (ratingKey: String, destination: URL)] = [:]
    /// taskIdentifiers whose expected-size has already been logged once (diagnostics).
    private var loggedExpectation: Set<Int> = []
    private let lock = NSLock()

    /// Called on any progress/completion so the manager can refresh records.
    var onChange: (() -> Void)?

    /// D3: invoked from each delegate failure/validation path so the manager can
    /// surface a reason (`lastError`) instead of the row vanishing without cause.
    /// Lands off the main actor; the manager hops to `@MainActor` to apply it.
    var onError: ((_ ratingKey: String, _ error: DownloadManager.DownloadError) -> Void)?

    private lazy var urlSession: URLSession = {
        let config: URLSessionConfiguration
        #if targetEnvironment(simulator)
        // The background transfer daemon (`nsurlsessiond`) is unreliable in the visionOS
        // simulator: it intermittently refuses the XPC connection (NSCocoaError 4097), so
        // `downloadTask` creation fails and the task dies immediately with
        // NSURLErrorUnknown (-1) / 0 bytes received. A foreground (in-process) session
        // needs no daemon, so downloads work while developing in the sim. Real devices
        // always have the daemon, so they keep the background session below (which
        // survives app suspension/relaunch — the resume-after-kill path from D5/D8).
        config = URLSessionConfiguration.default
        downloadLog.info("using FOREGROUND URLSession (simulator) for downloads")
        #else
        config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.isDiscretionary = false
        // The OS may relaunch us in the background to finish transfers; required so
        // `handleEventsForBackgroundURLSession` is delivered to the app delegate.
        config.sessionSendsLaunchEvents = true
        #endif
        config.allowsCellularAccess = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    init(store: DownloadStore) {
        self.store = store
        super.init()
        // Register so the app delegate can hand us the system completion handler when
        // the app is relaunched to process finished background events.
        let session = self
        Task { @MainActor in BackgroundDownloadCompletionRegistry.shared.register(session) }
    }

    /// Rebind delegate to any tasks the background session resumed after relaunch.
    ///
    /// Touching `urlSession` lazily recreates the background session object bound to
    /// the persisted identifier; the OS then redelivers progress/completion callbacks
    /// for any tasks that survived suspension/relaunch, and our delegate methods
    /// restore each record's progress from `didWriteData`/`didFinishDownloadingTo`.
    /// We also re-seed `inflight` so a relaunched task maps back to its record's
    /// destination (the index.json still holds the ratingKey + relative path).
    /// - Parameter onReattached: called (off the main actor) with the set of
    ///   ratingKeys that mapped back to a still-running task. The manager uses it to
    ///   reconcile the rest of the store to `.failed` (D2) — anything NOT in this set
    ///   has no live task and so can't be distinguished from a stall.
    func reattach(onReattached: (@Sendable (Set<String>) -> Void)? = nil) {
        urlSession.getAllTasks { [weak self] tasks in
            guard let self else { onReattached?([]); return }
            // Rebuild the taskIdentifier -> (ratingKey, destination) map for any
            // tasks the OS resumed. We match a task to a record by its source URL's
            // `path` query param (the metadataKey), which is stable per item; if we
            // can't match we still leave the task running and rely on the store row.
            var liveKeys: Set<String> = []
            self.lock.lock()
            for task in tasks {
                guard self.inflight[task.taskIdentifier] == nil,
                      let ratingKey = Self.ratingKey(for: task, store: self.store) else { continue }
                let destination = self.store.destinationURL(ratingKey: ratingKey, ext: "mp4")
                self.inflight[task.taskIdentifier] = (ratingKey, destination)
                liveKeys.insert(ratingKey)
            }
            // Also count tasks already tracked (e.g. started this launch) as live.
            for entry in self.inflight.values { liveKeys.insert(entry.ratingKey) }
            self.lock.unlock()
            onReattached?(liveKeys)
            self.onChange?()
        }
    }

    /// Best-effort match of a resumed background task back to a known download record.
    ///
    /// The task's original request URL carries the item's metadata key as the `path`
    /// query param (`/library/metadata/<ratingKey>`). We extract the trailing id and
    /// confirm a matching in-progress record exists in the store.
    private static func ratingKey(for task: URLSessionTask, store: DownloadStore) -> String? {
        guard let url = task.originalRequest?.url,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = comps.queryItems?.first(where: { $0.name == "path" })?.value else { return nil }
        let key = (path as NSString).lastPathComponent
        return store.records.contains(where: { $0.ratingKey == key }) ? key : nil
    }

    /// Force the lazy background session to be created (and thus its delegate bound),
    /// so the OS can deliver `urlSessionDidFinishEvents` after a relaunch.
    func ensureSessionReady() {
        _ = urlSession
    }

    /// Begin (or resume) a background download.
    ///
    /// `expectedBytes` is the known/estimated final file size, when the caller has
    /// one (the optimized part's reported size, or the quality×runtime estimate).
    /// `nil` falls back to the bare 500 MB floor.
    func start(ratingKey: String, from url: URL, to destination: URL,
               expectedBytes: Int? = nil) throws {
        // Pre-flight storage check: refuse if free space can't plausibly hold the
        // file. Sized against the expected bytes (plus headroom for the OS and the
        // temp-then-move copy) when known, so a 5 GB download with 600 MB free fails
        // here rather than mid-transfer.
        let headroom: Int64 = 500_000_000
        let required = max(headroom, Int64(expectedBytes ?? 0) + headroom)
        if let free = try? fileManager
            .attributesOfFileSystem(forPath: store.directory.path)[.systemFreeSize] as? Int64,
           free < required {
            throw DownloadManager.DownloadError.storageFull
        }
        let task = urlSession.downloadTask(with: url)
        lock.lock()
        inflight[task.taskIdentifier] = (ratingKey, destination)
        lock.unlock()
        downloadLog.info("start ratingKey=\(ratingKey, privacy: .public) path=\(url.path, privacy: .public)")
        task.resume()
    }

    /// Path + query of a request URL with the `X-Plex-Token` value redacted and the
    /// host omitted — safe to log for diagnosing a transcode/download rejection without
    /// leaking the token or the server hostname.
    static func sanitizedPathQuery(_ url: URL?) -> String {
        guard let url, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "nil"
        }
        comps.queryItems = comps.queryItems?.map {
            $0.name == "X-Plex-Token" ? URLQueryItem(name: $0.name, value: "REDACTED") : $0
        }
        let query = comps.query.map { "?\($0)" } ?? ""
        return comps.path + query
    }

    /// Cancel any in-flight transfer for a ratingKey.
    func cancel(ratingKey: String) {
        urlSession.getAllTasks { tasks in
            self.lock.lock()
            let ids = self.inflight.filter { $0.value.ratingKey == ratingKey }.map(\.key)
            self.lock.unlock()
            for task in tasks where ids.contains(task.taskIdentifier) { task.cancel() }
        }
        lock.lock()
        inflight = inflight.filter { $0.value.ratingKey != ratingKey }
        lock.unlock()
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        lock.lock()
        let entry = inflight[downloadTask.taskIdentifier]
        let firstCallback = entry != nil && loggedExpectation.insert(downloadTask.taskIdentifier).inserted
        lock.unlock()
        guard let entry else { return }
        // Log the server-declared expected size ONCE per task: -1 confirms the transcode
        // streamed without a Content-Length (so we estimate progress in the UI instead).
        if firstCallback {
            downloadLog.info("first-progress ratingKey=\(entry.ratingKey, privacy: .public) expectedBytes=\(totalBytesExpectedToWrite, privacy: .public)")
        }
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        store.updateProgress(ratingKey: entry.ratingKey,
                             bytes: Int(totalBytesWritten),
                             progress: progress)
        onChange?()
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        lock.lock(); let entry = inflight[downloadTask.taskIdentifier]; lock.unlock()
        guard let entry else { return }

        // Helper: a finished transfer that isn't actually a usable video must NOT be
        // left in place as "complete" (D1). Record a `.failed` row + surface why, and
        // delete the bad file so a retry starts clean.
        func fail(_ reason: String) {
            downloadLog.error("invalid-download ratingKey=\(entry.ratingKey, privacy: .public) reason=\(reason, privacy: .public)")
            try? fileManager.removeItem(at: entry.destination)
            store.setStatus(ratingKey: entry.ratingKey, .failed)
            onError?(entry.ratingKey, .invalidDownload(reason))
            onChange?()
        }

        let httpStatus = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
        let mime = (downloadTask.response as? HTTPURLResponse)?.mimeType ?? "nil"
        downloadLog.info("finished-transfer ratingKey=\(entry.ratingKey, privacy: .public) http=\(httpStatus, privacy: .public) mime=\(mime, privacy: .public)")

        // 1. HTTP status — Plex returns 200 for a real file body.
        if let http = downloadTask.response as? HTTPURLResponse {
            guard (200...299).contains(http.statusCode) else {
                // A download task writes the response body to `location` even on a 4xx,
                // so capture PMS's error page + the sanitized request (token stripped,
                // host omitted) at .error level — .info logs are memory-only and get
                // evicted before we can read them. This makes a transcode rejection
                // (e.g. an endpoint/param the universal transcoder refuses) diagnosable
                // from the log instead of an opaque status code.
                let body = (try? Data(contentsOf: location))
                    .map { String(decoding: $0.prefix(800), as: UTF8.self) } ?? "<unreadable>"
                let req = Self.sanitizedPathQuery(downloadTask.originalRequest?.url)
                downloadLog.error("download-http-error ratingKey=\(entry.ratingKey, privacy: .public) http=\(http.statusCode, privacy: .public) req=\(req, privacy: .public) body=\(body, privacy: .public)")
                fail("Server returned HTTP \(http.statusCode).")
                return
            }
            // 2. MIME type — an HTML/JSON body is a Plex error page, not a container.
            // (Truncated transcodes still pass here but are caught by 3/4 below.)
            if let mime = http.mimeType?.lowercased(),
               mime.hasPrefix("text/") || mime.contains("application/json")
                || mime.contains("application/xml") {
                fail("Server returned a \(mime) page, not a video.")
                return
            }
        }

        // Move the temp file into place atomically before validating its contents
        // (the system deletes `location` once this delegate returns).
        do {
            try? fileManager.removeItem(at: entry.destination)
            try fileManager.moveItem(at: location, to: entry.destination)
        } catch {
            store.setStatus(ratingKey: entry.ratingKey, .failed)
            onError?(entry.ratingKey, .transferFailed(String(describing: error)))
            onChange?()
            return
        }

        // 3. Minimum size — an error page or stub is far below any real video; a
        // sub-1 MB "movie" is almost certainly a truncated/failed transcode.
        let bytes = (try? fileManager.attributesOfItem(atPath: entry.destination.path)[.size] as? Int)
            .flatMap { $0 } ?? 0
        if bytes < 1_000_000 {       // < ~1 MB
            fail("Downloaded file is too small to be a video (\(bytes) bytes).")
            return
        }

        // 4. Playability probe — confirm AVFoundation can actually open the file,
        // catching bodies that are the right size/type but not a decodable container.
        // Uses the async `load(.isPlayable)` (the sync `isPlayable` is deprecated and
        // unreliable before properties load); the delegate can't await, so we finalize
        // status in a detached Task. Bytes/progress are recorded now so the in-flight
        // count is correct even while the probe runs.
        store.updateProgress(ratingKey: entry.ratingKey, bytes: bytes, progress: 1.0)
        onChange?()
        let destination = entry.destination
        let ratingKey = entry.ratingKey
        Task { [weak self] in
            let asset = AVURLAsset(url: destination)
            let playable = (try? await asset.load(.isPlayable)) ?? false
            guard let self else { return }
            if playable {
                // Validated: mark explicitly complete (D2) so a relaunch trusts it.
                downloadLog.info("complete ratingKey=\(ratingKey, privacy: .public) bytes=\(bytes, privacy: .public)")
                self.store.setStatus(ratingKey: ratingKey, .complete)
            } else {
                downloadLog.error("invalid-download ratingKey=\(ratingKey, privacy: .public) reason=not-playable bytes=\(bytes, privacy: .public)")
                try? self.fileManager.removeItem(at: destination)
                self.store.setStatus(ratingKey: ratingKey, .failed)
                self.onError?(ratingKey, .invalidDownload("Downloaded file isn't a playable video container."))
            }
            self.onChange?()
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        lock.lock()
        let entry = inflight.removeValue(forKey: task.taskIdentifier)
        loggedExpectation.remove(task.taskIdentifier)
        lock.unlock()
        guard let entry, let error else { return }
        let nsError = error as NSError
        // A cancel is not a failure. Any other error keeps a `.failed` row (D3) with a
        // surfaced reason, rather than silently erasing it so the UI can offer retry.
        if nsError.code != NSURLErrorCancelled {
            downloadLog.error("transfer-failed ratingKey=\(entry.ratingKey, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) desc=\(error.localizedDescription, privacy: .public) bytesReceived=\(task.countOfBytesReceived, privacy: .public)")
            store.setStatus(ratingKey: entry.ratingKey, .failed)
            onError?(entry.ratingKey, .transferFailed(error.localizedDescription))
        } else {
            downloadLog.info("cancelled ratingKey=\(entry.ratingKey, privacy: .public)")
        }
        onChange?()
    }

    /// Called when the background session has delivered all events queued while the
    /// app was suspended/terminated (after a relaunch). We invoke the system-supplied
    /// completion handler the app delegate stashed, so the OS knows our UI is current
    /// and snapshots a fresh app preview. Must run on the main queue.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        onChange?()
        let identifier = session.configuration.identifier ?? Self.identifier
        Task { @MainActor in
            BackgroundDownloadCompletionRegistry.shared.fireCompletion(for: identifier)
        }
    }
}

/// Bridges the app delegate's `handleEventsForBackgroundURLSession` callback to the
/// `BackgroundDownloadSession` that owns the matching background `URLSession`.
///
/// When visionOS relaunches the app in the background to finish a transfer it calls
/// `application(_:handleEventsForBackgroundURLSessionWithIdentifier:completionHandler:)`.
/// The app must (1) recreate the background session (done lazily by reattaching the
/// `DownloadManager`) and (2) keep the completion handler until the session reports
/// `urlSessionDidFinishEvents`, then call it. The session object and the app delegate
/// are created independently, so this small main-actor registry connects them by
/// session identifier.
@MainActor
final class BackgroundDownloadCompletionRegistry {
    static let shared = BackgroundDownloadCompletionRegistry()

    /// identifier -> system completion handler awaiting `didFinishEvents`.
    private var handlers: [String: () -> Void] = [:]
    /// Live sessions keyed by their background-session identifier.
    private var sessions: [String: BackgroundDownloadSession] = [:]

    private init() {}

    /// Record a live session so the delegate's identifier resolves to it.
    func register(_ session: BackgroundDownloadSession) {
        sessions[BackgroundDownloadSession.identifier] = session
        if handlers[BackgroundDownloadSession.identifier] != nil {
            session.ensureSessionReady()
            session.reattach()
        }
    }

    /// Store the system completion handler and make sure the matching session exists
    /// so its delegate will eventually fire `urlSessionDidFinishEvents`.
    func store(identifier: String, completion: @escaping () -> Void) {
        handlers[identifier] = completion
        sessions[identifier]?.ensureSessionReady()
        sessions[identifier]?.reattach()
    }

    /// Invoke and clear the stored completion handler for `identifier`.
    func fireCompletion(for identifier: String) {
        guard let handler = handlers.removeValue(forKey: identifier) else { return }
        handler()
    }
}
