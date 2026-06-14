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

    /// What the user chose in the download sheet, resolved from the direct-play probe.
    public enum DownloadChoice: Sendable, Equatable {
        /// Direct-download the original file (probe said whole-file direct play).
        case original
        /// Server-side optimize to a named preset (the server's real target name).
        case optimize(targetName: String)
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

    /// Run the download-time direct-play probe for `item` at the given media/part. Advertises
    /// the `.original` 200_000 kbps ceiling so a high-bitrate-but-compatible file still
    /// qualifies for a direct download — a cap must NEVER force a transcode verdict for
    /// downloads. Returns `(playsWholeFileDirectly, originalPart)`; on any probe failure
    /// returns `(false, part?)` so the caller falls back to the optimizer.
    public func directPlayProbe(for item: MediaItem, server: URL, token: String,
                                mediaIndex: Int, partIndex: Int)
        async -> (direct: Bool, part: Part?) {
        let part = item.media?[safe: mediaIndex]?.part[safe: partIndex]
        let metadataKey = item.key ?? "/library/metadata/\(item.ratingKey)"
        let transcode = TranscodeRequest(server: server, token: token,
                                         identity: appModel.identity,
                                         metadataKey: metadataKey,
                                         maxVideoBitrateKbps: 200_000,
                                         sessionID: "plex-avp-dl-probe-" + UUID().uuidString,
                                         mediaIndex: mediaIndex, partIndex: partIndex)
        do {
            let decision = try await appModel.client.send(transcode.directPlayProbeRequest(),
                                                          as: DecisionResponse.self)
            return (decision.playsWholeFileDirectly, part)
        } catch {
            downloadLog.error("download-probe-failed ratingKey=\(item.ratingKey, privacy: .public) err=\(String(describing: error), privacy: .public)")
            return (false, part)
        }
    }

    /// The server's real optimize preset names (`/media/processing/targets`), for the sheet.
    /// Returns [] on any failure so the sheet falls back to the built-in preset names.
    /// SERVER-SPECIFIC — confirmed by Phase 0.
    public func optimizePresetNames(server: URL, token: String) async -> [String] {
        guard let targets = try? await appModel.client.send(
            OptimizeRequest.mediaProcessingTargetsRequest(server: server, token: token,
                                                          identity: appModel.identity),
            as: MediaProcessingTargets.self)
        else { return [] }
        return targets.targets.map(\.name).filter { !$0.isEmpty }
    }

    /// Probe-driven download entry point (offline-download redesign). `choice` comes from the
    /// sheet, which already ran the direct-play probe: `.original` direct-downloads the source
    /// file; `.optimize` renders a compatible MP4 server-side then downloads it. Both converge
    /// on the same background-`URLSession` + validation pipeline. Records state rather than
    /// throwing.
    public func download(_ item: MediaItem, choice: DownloadChoice,
                         mediaIndex: Int = 0, partIndex: Int = 0) async {
        let ratingKey = item.ratingKey
        guard let token = appModel.serverToken, let server = appModel.serverBaseURL else {
            lastError[ratingKey] = .notAuthenticated
            return
        }
        guard !activeJobs.contains(ratingKey) else { return }
        activeJobs.insert(ratingKey)
        lastError[ratingKey] = nil
        defer { activeJobs.remove(ratingKey) }

        let chosenMedia = item.media?[safe: mediaIndex]
        let resolutionLabel = Self.resolutionLabel(for: chosenMedia)
        let metadata = Self.offlineMetadata(from: item, resolutionLabel: resolutionLabel,
                                            mediaIndex: mediaIndex, partIndex: partIndex)
        // D5: cache the poster locally (best-effort) so artwork shows offline. A fetch
        // failure is not a download failure — it just leaves the row without a poster.
        cachePoster(ratingKey: ratingKey, thumb: item.thumb ?? item.art,
                    server: server, token: token)

        switch choice {
        case .original:
            guard let part = chosenMedia?.part[safe: partIndex] else {
                lastError[ratingKey] = .transferFailed("No media part to download.")
                return
            }
            let ext = part.container ?? (part.file as NSString?)?.pathExtension ?? "mp4"
            let destination = store.destinationURL(ratingKey: ratingKey,
                                                   ext: ext.isEmpty ? "mp4" : ext)
            // Seed a 0% record so the UI shows the job immediately.
            store.upsert(DownloadRecord(ratingKey: ratingKey, title: item.title,
                                        localURL: destination, bytes: 0, progress: 0,
                                        metadata: metadata))
            refreshRecords()
            // The original file is a STATIC GET with a real Content-Length + valid moov atom.
            let url = OptimizeRequest.downloadURL(server: server, token: token, partKey: part.key)
            do {
                try session.start(ratingKey: ratingKey, from: url, to: destination,
                                  expectedBytes: part.size)
                refreshRecords()
            } catch let error as DownloadError {
                lastError[ratingKey] = error
                store.setStatus(ratingKey: ratingKey, .failed)
                refreshRecords()
            } catch {
                lastError[ratingKey] = .transferFailed(String(describing: error))
                store.setStatus(ratingKey: ratingKey, .failed)
                refreshRecords()
            }

        case .optimize(let targetName):
            await triggerOptimizeAndDownload(item: item, targetName: targetName,
                                             metadata: metadata, server: server, token: token)
        }
    }

    /// Whether a download already exists (completed or in-flight) for `ratingKey`.
    /// Lets the options sheet show "Downloaded" / disable re-download.
    public func hasDownload(for ratingKey: String) -> Bool {
        records.contains { $0.ratingKey == ratingKey }
    }

    /// Retry a previously `.failed` download (D3/D5). We rebuild the source `MediaItem`
    /// from the persisted `OfflineMetadata` snapshot (real type + media/part index) and
    /// re-run the probe-driven download path — re-probing so a now-compatible file goes
    /// direct. Rows persisted before D5 lack a snapshot, so we fall back to a minimal movie.
    public func retry(ratingKey: String) {
        guard let record = records.first(where: { $0.ratingKey == ratingKey }) else { return }
        lastError[ratingKey] = nil
        let metadata = record.metadata
        // Drop the stale `.failed` row so the re-run re-seeds it cleanly; this also
        // removes any leftover invalid file from the failed attempt.
        store.remove(ratingKey: ratingKey)
        refreshRecords()
        let item = metadata?.makeMediaItem()
            ?? MediaItem(ratingKey: record.ratingKey, title: record.title, type: "movie")
        let mediaIndex = metadata?.mediaIndex ?? 0
        let partIndex = metadata?.partIndex ?? 0
        // Re-probe so the retry takes the correct path: a now-compatible file goes direct,
        // otherwise re-render via the optimizer (default "Optimized for TV" preset).
        Task { [weak self] in
            guard let self,
                  let token = self.appModel.serverToken,
                  let server = self.appModel.serverBaseURL else { return }
            let probe = await self.directPlayProbe(for: item, server: server, token: token,
                                                   mediaIndex: mediaIndex, partIndex: partIndex)
            let choice: DownloadChoice = probe.direct ? .original
                : .optimize(targetName: "Optimized for TV")
            await self.download(item, choice: choice, mediaIndex: mediaIndex, partIndex: partIndex)
        }
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

    // MARK: - D5: offline metadata + poster caching

    /// Build the persisted snapshot of a source `MediaItem` + a human resolution label.
    /// Captures only the fields the offline UI/player/retry actually read. `resolutionLabel`
    /// is descriptive ("1080p"/"4K") for the offline-library caption — it is NOT a transcode
    /// cap (the redesign downloads either the original file or a server-rendered MP4).
    private static func offlineMetadata(from item: MediaItem,
                                        resolutionLabel: String?,
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
                        resolutionLabel: resolutionLabel,
                        mediaIndex: mediaIndex,
                        partIndex: partIndex,
                        posterRelativePath: nil)
    }

    /// Human-readable resolution label for the chosen media version, for the offline-library
    /// caption only (descriptive, never a transcode cap). Derived from the media's pixel
    /// height with the common consumer-resolution buckets; falls back to "W×H" then nil.
    static func resolutionLabel(for media: Media?) -> String? {
        guard let media else { return nil }
        switch (media.width, media.height) {
        case let (_, h?) where h >= 2160: return "4K"
        case let (_, h?) where h >= 1080: return "1080p"
        case let (_, h?) where h >= 720:  return "720p"
        case let (_, h?) where h >= 480:  return "480p"
        case let (w?, h?):                return "\(w)×\(h)"
        default:                          return nil
        }
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

    // MARK: - Optimize path (HIGH UNCERTAINTY — isolated; Phase 0 confirms the contract)

    /// Render a compatible MP4 server-side, poll for the rendered Part, then download it.
    ///
    /// Real contract (python-plexapi `Video.optimize`), implemented to the best-known shape:
    ///   1. GET /playlists?type=42  → read `backgroundProcessing.key` (e.g. /playlists/9/items)
    ///   2. GET /media/processing/targets → resolve the chosen preset NAME to its server
    ///      `targetTagID` (NOT a hardcoded 2/1/3; those are version-specific)
    ///   3. POST {key}  with the Item[...] grammar
    ///   4. poll item metadata for the new Part, then download it (static file, real size).
    ///
    /// // TODO(live, Phase 0): the background-processing key, the targets endpoint/shape, and
    /// the accepted POST grammar are confirmed by `scripts/live-optimize-probe.sh`. Until then
    /// this is the best-known contract and is NOT live-verified. Failures are recorded as
    /// `.optimizeFailed`; we still poll metadata so an out-of-band optimized part is picked up.
    private func triggerOptimizeAndDownload(item: MediaItem, targetName: String,
                                            metadata: OfflineMetadata,
                                            server: URL, token: String) async {
        let ratingKey = item.ratingKey
        let identity = appModel.identity
        // Seed a 0% record so the UI shows the job immediately while we set up the optimize.
        store.upsert(DownloadRecord(ratingKey: ratingKey, title: item.title,
                                    localURL: store.destinationURL(ratingKey: ratingKey, ext: "mp4"),
                                    bytes: 0, progress: 0, metadata: metadata))
        refreshRecords()

        do {
            try await triggerOptimize(item: item, targetName: targetName,
                                      server: server, token: token, identity: identity)
            let part = try await pollForOptimizedPart(ratingKey: ratingKey, server: server,
                                                      token: token, identity: identity)
            let ext = part.container ?? (part.file as NSString?)?.pathExtension ?? "mp4"
            let destination = store.destinationURL(ratingKey: ratingKey,
                                                   ext: ext.isEmpty ? "mp4" : ext)
            store.upsert(DownloadRecord(ratingKey: ratingKey, title: item.title,
                                        localURL: destination, bytes: 0, progress: 0,
                                        metadata: metadata))
            refreshRecords()
            let url = OptimizeRequest.downloadURL(server: server, token: token, partKey: part.key)
            try session.start(ratingKey: ratingKey, from: url, to: destination,
                              expectedBytes: part.size)
            refreshRecords()
        } catch let error as DownloadError {
            lastError[ratingKey] = error
            store.setStatus(ratingKey: ratingKey, .failed)
            refreshRecords()
        } catch {
            lastError[ratingKey] = .transferFailed(String(describing: error))
            store.setStatus(ratingKey: ratingKey, .failed)
            refreshRecords()
        }
    }

    /// Steps 1–3 of the optimize contract: fetch the background-processing key, resolve the
    /// target tag id from the server's targets, POST the optimize job. Isolated so the live
    /// (server-specific) path is the only thing Phase 0 needs to confirm.
    private func triggerOptimize(item: MediaItem, targetName: String,
                                 server: URL, token: String,
                                 identity: ClientIdentity) async throws {
        // 1. Background-processing playlist key.
        let bgKey: String
        do {
            let pl = try await appModel.client.send(
                OptimizeRequest.backgroundProcessingRequest(server: server, token: token, identity: identity),
                as: BackgroundProcessingPlaylist.self)
            guard let key = pl.key else {
                throw DownloadError.optimizeFailed("No background-processing playlist key.")
            }
            bgKey = key
        } catch let e as DownloadError {
            throw e
        } catch {
            throw DownloadError.optimizeFailed("playlists?type=42: \(String(describing: error))")
        }

        // 2. Resolve the chosen preset NAME to the server's targetTagID. If the targets
        //    endpoint isn't available, fall back to the conventional id so the POST still
        //    has a value (Phase 0 will confirm whether that's accepted).
        var targetTagID = Self.conventionalTagID(forName: targetName)
        if let targets = try? await appModel.client.send(
            OptimizeRequest.mediaProcessingTargetsRequest(server: server, token: token, identity: identity),
            as: MediaProcessingTargets.self),
           let resolved = targets.tagID(forName: targetName) {
            targetTagID = resolved
        }

        // 3. POST the optimize job to the background-processing playlist.
        let settings = Self.mediaSettings(forTargetName: targetName)
        let create = OptimizeRequest.createOnPlaylist(
            server: server, token: token, identity: identity,
            backgroundProcessingKey: bgKey, ratingKey: item.ratingKey,
            title: item.title, targetTagID: targetTagID, mediaSettings: settings)
        do {
            try await appModel.client.send(create)
        } catch {
            throw DownloadError.optimizeFailed("optimize POST: \(String(describing: error))")
        }
    }

    /// Conventional Plex target tag ids (fallback only — the live server's ids win when the
    /// targets endpoint resolves them). Phase 0 confirms the real ids.
    private static func conventionalTagID(forName name: String) -> Int {
        switch name.lowercased() {
        case "optimized for mobile": return 1
        case "original quality":     return 3
        default:                     return 2   // "Optimized for TV"
        }
    }

    /// Best-known render settings per preset name (fallback caps; the server preset governs).
    private static func mediaSettings(forTargetName name: String) -> OptimizeRequest.MediaSettings {
        switch name.lowercased() {
        case "optimized for mobile":
            return .init(videoQuality: 100, maxVideoBitrateKbps: 2000, videoResolution: "1280x720")
        case "original quality":
            return .init(videoQuality: 100, maxVideoBitrateKbps: nil, videoResolution: nil)
        default:
            return .init(videoQuality: 100, maxVideoBitrateKbps: 8000, videoResolution: "1920x1080")
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
