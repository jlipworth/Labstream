import Foundation
import Observation
import PMSKit
import AVFoundation   // D1: AVURLAsset playability probe on a finished download
import os

/// Diagnostic log for the offline-download pipeline. Inspect with:
///   log show --predicate 'subsystem == "com.jlipworth.VisionPlay"' --last 10m
/// Only scrubbed values are logged — never the token or full URL (the transcode
/// URL carries `X-Plex-Token` as a query param), so we log `url.path` only.
let downloadLog = Logger(subsystem: "com.jlipworth.VisionPlay", category: "Downloads")

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
        // Legacy UI mapping only. Plex optimize polling no longer fails by wall clock; long
        // server renders remain queued/transcoding until Plex reports a real terminal failure.
        case optimizeTimedOut
        // Deliberately never produced today: the optimize path surfaces `.optimizeFailed`
        // only when Plex reports a true terminal failure. Retained because `OfflineLibraryView`
        // still maps it to a user-facing message, so a future "optimized version had no Part"
        // diagnostic can be wired in without churn.
        case noOptimizedPart
        case storageFull
        case storageLimitExceeded(String)
        case transferFailed(String)
        /// The transfer finished with a 2xx but the body wasn't a usable video
        /// container (HTML/JSON error page, truncated transcode, unplayable). D1:
        /// previously such bodies were saved as "complete" and failed at playback.
        case invalidDownload(String)
        /// #95: a recoverable interruption (e.g. headset-off killed the transfer) that handed
        /// back URLSession resume data. NOT a hard failure — the partial + resume blob are kept
        /// and the row is `.paused`; the UI shows a "will resume" affordance rather than a red error.
        case interruptedResumable
    }

    /// What the user chose in the download sheet, resolved from the direct-play probe.
    public enum DownloadChoice: Sendable, Equatable {
        /// Direct-download the original file (probe said whole-file direct play).
        case original
        /// Server-side optimize to a named preset (the server's real target name).
        case optimize(targetName: String)
        /// #83: original-quality compatible remux (Jellyfin/Emby only) — copy the video stream into
        /// an offline-playable MP4, transcoding only audio/container as needed. Forward-only (a
        /// remux stream is not range-resumable). Plex falls back to `.optimize` for this choice.
        case optimizeCompatible
    }

    /// Internal control-flow error for async optimize work that outlived the row it belonged to.
    ///
    /// Deleting/retrying a Plex optimize row removes the visible row and can immediately enqueue a
    /// replacement with a new queue title. The old async poller is not a URLSession task, so it may
    /// wake up later after Plex has produced a Part. Treat that as a no-op, not as a user-visible
    /// failure, and never let it overwrite the newer row or start a duplicate transfer.
    private enum DownloadLifecycleCancellation: Error {
        case staleOptimizeAttempt
    }

    /// Live records (in-progress + completed), backed by `DownloadStore`.
    public private(set) var records: [DownloadRecord] = []

    /// ratingKeys with an active (optimize or transfer) job in flight.
    public private(set) var activeJobs: Set<String> = []

    /// Full optimize-queue titles (`"<title> [VisionPlay <hex>]"`) of in-flight jobs. Used to
    /// protect them from `cleanStaleOptimizeJobs`, which only removes abandoned items.
    private var activeQueueTitles: Set<String> = []

    /// ratingKey -> the optimize-queue title we submitted for its in-flight download. Lets the
    /// download-completion/failure path release the right `activeQueueTitles` entry. CRITICAL:
    /// the queue title must stay protected for the REAL download lifetime (until the file
    /// finishes/fails), NOT just until the optimize kickoff returns — `session.start` only
    /// KICKS OFF the URLSession transfer, so releasing it when `triggerOptimizeAndDownload`
    /// returns would leave the rendered Part unprotected while it is still downloading, and
    /// a concurrent job's `cleanStaleOptimizeJobs` could then delete that Part out from under it.
    private var queueTitleByRatingKey: [String: String] = [:]

    /// Last error per ratingKey, for UI surfacing.
    public private(set) var lastError: [String: DownloadError] = [:]

    /// Smoothed transfer rate (bytes/sec) per actively-downloading ratingKey, derived
    /// in `refreshRecords` by diffing cumulative bytes between progress callbacks.
    /// Ephemeral (never persisted); drives the "x MB/s" + ETA readout in the UI.
    public private(set) var downloadSpeed: [String: Double] = [:]

    /// Last (bytes, time) sample per ratingKey, used to compute `downloadSpeed`.
    private var speedSamples: [String: (bytes: Int, time: Date)] = [:]

    /// Estimated seconds remaining for the FILE-DOWNLOAD phase, per actively-downloading
    /// ratingKey. Derived from the smoothed `downloadSpeed` and the remaining bytes
    /// (`expectedTotal − bytesWritten`, where `expectedTotal` is recovered from the record's
    /// `bytes / progress`). Suppressed (absent) when the rate is ~0, the total is unknown, or
    /// the estimate is implausible (>12h) — mirrors the suppression in `updateOptimizeETA`.
    /// Ephemeral (never persisted); drives the "~M min left" readout in the download phase.
    public private(set) var downloadETA: [String: TimeInterval] = [:]

    /// Server-side optimize/transcode progress (0.0…1.0) per ratingKey, polled from
    /// `GET /activities` during the "Preparing on server…" phase. Absent when the server
    /// reports no matching activity (caller falls back to the indeterminate caption).
    /// Ephemeral (never persisted); drives the "Transcoding… 37%" readout.
    public private(set) var optimizeProgress: [String: Double] = [:]

    /// Estimated seconds remaining for the server-side optimize, derived from an EMA over
    /// the moving percent. Present only when the rate is stable enough to be meaningful;
    /// suppressed while noisy/indeterminate. Labelled "estimated" in the UI.
    public private(set) var optimizeETA: [String: TimeInterval] = [:]

    /// Coarse optimize state label per ratingKey: "queued" (job seen but no progress yet)
    /// or "transcoding" (progress reported). Absent when no matching activity is found.
    public private(set) var optimizeState: [String: String] = [:]

    /// Active downloads whose byte stream is gated by the server's transcoder rather than by
    /// the network — i.e. the file is being served AS it renders, so a slow rate means "the
    /// server is still transcoding", NOT "slow Wi-Fi". Set for optimize/transcode downloads
    /// (where this is the reality) and surfaced in the caption so the rate isn't misread as a
    /// network problem. Ephemeral; never persisted. Membership alone marks a download as
    /// transcode-sourced; `isDownloadTranscodeLimited` adds the "running well below realtime"
    /// test so a fast-rendering job isn't mislabelled.
    private var transcodeSourcedDownloads: Set<String> = []

    /// ratingKey -> the server `PlaySessionId` minted/assigned for a TRANSCODED download.
    /// Required for encoder teardown: active server encoders must be killed with
    /// `DELETE /Videos/ActiveEncodings?PlaySessionId=..` when the transfer reaches a terminal
    /// state. Fired from `releaseInFlight` (complete/failed/cancel/delete). Original/static
    /// downloads use no encoder, so they are never recorded here.
    ///
    /// #84: the same PlaySessionId is also mirrored into `OfflineMetadata.playSessionID` after the
    /// row is seeded. Normal terminal transitions tear down from this in-memory map and clear the
    /// persisted copy on success; hard-kill/relaunch cleanup uses the persisted copy in
    /// `teardownOrphanedEncodersOnLaunch()`.
    private var embyPlaySessionByRatingKey: [String: String] = [:]
    private var jellyfinPlaySessionByRatingKey: [String: String] = [:]

    /// Last (progress 0…1, time) sample per ratingKey, used to derive `optimizeETA` rate.
    private var optimizeProgressSamples: [String: (p: Double, time: Date)] = [:]
    /// Smoothed %/sec rate per ratingKey (EMA), used to derive `optimizeETA`.
    private var optimizeRate: [String: Double] = [:]

    private let appModel: AppModel
    private let store: DownloadStore
    private let session: BackgroundDownloadSession

    /// Poll cadence for Plex server-side optimize jobs. Deliberately no wall-clock timeout:
    /// long 4K/HDR software transcodes can legitimately run for hours, and the app must base
    /// failure only on server truth (metadata/background queue status), not elapsed time.
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
        // row. Hard failures record a `.failed` status in the store and hand us the
        // reason here so `lastError` can drive the OfflineLibraryView message + retry.
        self.session.onError = { [weak self] ratingKey, error in
            Task { @MainActor in
                guard let self else { return }
                self.lastError[ratingKey] = error
                if case .invalidDownload = error {
                    await self.fallbackOriginalValidationFailureIfPossible(ratingKey: ratingKey)
                }
                self.refreshRecords()
            }
        }
        // D2: rows with no live task can't be told apart from a stall, so reconcile
        // them to `.failed` (retryable) once we know which tasks survived, except
        // server-prep optimized rows that can resume polling after relaunch. The
        // `getAllTasks` completion lands off the main actor; the store is thread-safe,
        // so we reconcile there and hop to `@MainActor` to publish records and kick any
        // now-queued optimized jobs. This second kick closes the launch-order race where
        // auth restore called `resumePendingServerPrepDownloads()` before reattach reset
        // a stale `.downloading` optimized row back to `.queued`.
        self.session.reattach { [weak self, store] liveKeys in
            store.reconcile(liveRatingKeys: liveKeys)
            Task { @MainActor in
                self?.refreshRecords()
                self?.resumePendingServerPrepDownloads()
                // #84: reclaim any server encoder leaked by a HARD app kill (the in-memory
                // PlaySessionId maps are empty on a fresh launch; the persisted `playSessionID`
                // on each row is the only handle left to DELETE the encoder).
                self?.teardownOrphanedEncodersOnLaunch()
            }
        }
    }

    /// #84: launch-time sweep that tears down server encoders whose download reached a terminal
    /// state but whose `releaseInFlight` teardown never fired (e.g. a hard app kill mid-transfer,
    /// so the in-memory PlaySession maps were lost). Resolves each row's backend via the migration
    /// fallback and only fires when that backend lane is still configured (a DELETE needs creds).
    /// The persisted `playSessionID` is cleared ONLY once the encoder is confirmed gone, so a
    /// teardown that fails (server unreachable / wrong server) retries on a later launch instead
    /// of leaking the encoder forever.
    func teardownOrphanedEncodersOnLaunch() {
        for record in records {
            guard let md = record.metadata, let psid = md.playSessionID, !psid.isEmpty,
                  record.status == .failed || record.status == .complete || record.status == .unverified else { continue }
            let kind = md.resolvedBackendKind(ratingKey: record.ratingKey)
            // Need a live session for that backend to issue the DELETE.
            guard let live = appModel.backendSession(for: kind) else { continue }
            // Only tear down on the SAME server the encoder lives on. If the lane was re-pointed
            // at a different server (re-login elsewhere), firing the DELETE there would hit the
            // wrong server and leak the original encoder — skip and keep the psid so a later
            // launch on the matching server retries.
            guard Self.backendSessionMatchesPersistedServer(metadata: md, live: live) else { continue }
            let key = record.ratingKey
            switch kind {
            case .jellyfin:
                recordDownloadDiagnostic("downloads.jellyfin_encoder_teardown", fields: [
                    "download_id": .identifier(key),
                    "phase": .label("launch_sweep"),
                ])
                let service = JellyfinBrowseService(appModel: appModel)
                Task { if await service.stopActiveEncoding(playSessionId: psid, session: live) { store.clearPlaySessionID(ratingKey: key) } }
            case .emby:
                recordDownloadDiagnostic("downloads.emby_encoder_teardown", fields: [
                    "download_id": .identifier(key),
                    "phase": .label("launch_sweep"),
                ])
                let service = EmbyBrowseService(appModel: appModel)
                Task { if await service.stopActiveEncoding(playSessionId: psid, session: live) { store.clearPlaySessionID(ratingKey: key) } }
            case .plex:
                // Plex optimize renders server-side then serves a static file — no live encoder to
                // tear down (the queue item is reaped separately). Clear the unused psid.
                store.clearPlaySessionID(ratingKey: key)
            }
        }
    }

    /// Confirm a persisted encoder handle belongs to the currently-restored backend lane before
    /// sending `DELETE /Videos/ActiveEncodings`. Prefer stable server ids; fall back to the saved
    /// base URL for servers that did not provide one.
    private static func backendSessionMatchesPersistedServer(metadata: OfflineMetadata,
                                                             live: BackendSession) -> Bool {
        if let persistedID = metadata.backendServerID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !persistedID.isEmpty {
            return live.serverID == persistedID
        }
        guard let persistedURLString = metadata.backendBaseURLString,
              let persistedURL = URL(string: persistedURLString) else {
            // Legacy/partial metadata has no server identity to compare. Allow the best-effort
            // cleanup rather than permanently leaking a known PlaySessionId.
            return true
        }
        return sameBackendBaseURL(persistedURL, live.baseURL)
    }

    private static func sameBackendBaseURL(_ lhs: URL, _ rhs: URL) -> Bool {
        let lhsScheme = lhs.scheme?.lowercased()
        let rhsScheme = rhs.scheme?.lowercased()
        guard lhsScheme == rhsScheme,
              lhs.host?.lowercased() == rhs.host?.lowercased(),
              effectivePort(lhs) == effectivePort(rhs) else { return false }
        return normalizedBasePath(lhs.path) == normalizedBasePath(rhs.path)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    private static func normalizedBasePath(_ path: String) -> String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Absolute local URL for a completed download, if present on disk.
    public func localURL(for ratingKey: String) -> URL? {
        store.localURL(for: ratingKey)
    }

    /// Absolute cached Plex BIF index URL for a completed download, if present on disk.
    public func plexBIFURL(for ratingKey: String) -> URL? {
        store.plexBIFURL(for: ratingKey)
    }

    /// Absolute cached Jellyfin trickplay playlist URL for a completed download, if present on disk.
    public func jellyfinTrickPlayPlaylistURL(for ratingKey: String) -> URL? {
        store.jellyfinTrickPlayPlaylistURL(for: ratingKey)
    }

    /// Absolute cached per-chapter image URLs (chapter index → file) for a completed download (#88/#89).
    public func chapterImageURLs(for ratingKey: String) -> [Int: URL] {
        store.chapterImageURLs(for: ratingKey)
    }

    /// Whether an active download's byte stream is gated by the server's transcoder (the file
    /// is served as it renders) rather than by the network — so a slow rate means "server still
    /// transcoding", not "slow connection". True only for a transcode-SOURCED download (marked
    /// at start) that is ALSO currently flowing well below realtime, so a fast-rendering optimize
    /// job isn't mislabelled. The UI uses this to caption the phase honestly + avoid implying a
    /// fabricated network speed. The derived ETA already reflects the real (gated) byte rate.
    public func isDownloadTranscodeLimited(_ ratingKey: String) -> Bool {
        guard transcodeSourcedDownloads.contains(ratingKey),
              let record = records.first(where: { $0.ratingKey == ratingKey }),
              record.status == .downloading else { return false }
        // "Well below realtime": a transcode keeping up with realtime playback would deliver at
        // least roughly the encode bitrate; a sub-realtime render dribbles far below it. We don't
        // persist the target bitrate, so use an absolute floor — a healthy network transfer of a
        // multi-Mbps file sustains MB/s, whereas a sub-realtime 4K→720p render trickles at tens of
        // KB/s. Below ~500 KB/s on a transcode-sourced download is overwhelmingly transcode-gated.
        guard let rate = downloadSpeed[ratingKey] else { return true }   // no rate yet → assume gated
        return rate < 500_000
    }

    /// #84: whether the backend lane a row needs is currently configured/authenticated. The
    /// offline UI uses this to caption a server-prep row whose lane is signed out honestly
    /// ("…signed out") instead of implying the server is still preparing. The row stays `.queued`
    /// and auto-resumes once the lane returns (see `resumePendingServerPrepDownloads`).
    public func isBackendConfigured(for record: DownloadRecord) -> Bool {
        let kind = record.metadata?.resolvedBackendKind(ratingKey: record.ratingKey)
            ?? DownloadBackendKind(ratingKeyPrefix: record.ratingKey)
        return appModel.backendSession(for: kind) != nil
    }

    /// Store identity for a SPECIFIC backend. Filenames/rows are keyed by IDs, not titles, so
    /// duplicate episode/movie names are safe. Jellyfin/Emby IDs are namespaced so they cannot
    /// collide with a Plex ratingKey in the shared offline index. The `backend` is passed
    /// explicitly (rather than read from `appModel.activeBackend`) so keying never depends on the
    /// globally-active lane — at the UI call site the active backend IS the correct backend (the
    /// user downloads what they're browsing), but the key is then stable regardless of switches.
    public func recordKey(for item: MediaItem, backend: DownloadBackendKind) -> String {
        switch backend {
        case .plex:
            return item.ratingKey
        case .jellyfin:
            return Self.jellyfinRecordKey(item.ratingKey)
        case .emby:
            return Self.embyRecordKey(item.ratingKey)
        }
    }

    fileprivate static func jellyfinRecordKey(_ itemId: String) -> String {
        "jellyfin:\(itemId)"
    }

    private static func isJellyfinRecordKey(_ ratingKey: String) -> Bool {
        ratingKey.hasPrefix("jellyfin:")
    }

    private static func jellyfinItemID(fromRecordKey ratingKey: String) -> String {
        isJellyfinRecordKey(ratingKey)
            ? String(ratingKey.dropFirst("jellyfin:".count))
            : ratingKey
    }

    fileprivate static func embyRecordKey(_ itemId: String) -> String {
        "emby:\(itemId)"
    }

    private static func isEmbyRecordKey(_ ratingKey: String) -> Bool {
        ratingKey.hasPrefix("emby:")
    }

    private static func embyItemID(fromRecordKey ratingKey: String) -> String {
        isEmbyRecordKey(ratingKey)
            ? String(ratingKey.dropFirst("emby:".count))
            : ratingKey
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
                                         sessionID: "visionplay-dl-probe-" + UUID().uuidString,
                                         mediaIndex: mediaIndex, partIndex: partIndex)
        do {
            let decision = try await appModel.client.send(transcode.directPlayProbeRequest(),
                                                          as: DecisionResponse.self)
            let eligibility = OfflineDownloadDecision.originalEligibility(decision: decision, part: part)
            var fields: [String: DiagnosticFieldValue] = [
                "download_id": .identifier(item.ratingKey),
                "direct": .bool(decision.playsWholeFileDirectly),
                "container": .label(eligibility.container),
                "local_playable": .bool(eligibility.localPlayableContainer),
                "saves_video_encode": .bool(decision.savesVideoEncode),
                "route": .label(eligibility.route),
            ]
            if let reason = eligibility.optimizeReason { fields["reason"] = .label(reason) }
            if let code = decision.mdeDecisionCode { fields["mde_code"] = .int(code) }
            if let code = decision.generalDecisionCode { fields["general_code"] = .int(code) }
            if let d = decision.partDecision { fields["part_decision"] = .label(d) }
            if let d = decision.videoDecision { fields["video_decision"] = .label(d) }
            if let d = decision.audioDecision { fields["audio_decision"] = .label(d) }
            recordDownloadDiagnostic("downloads.original_probe", fields: fields)
            return (eligibility.playsWholeFileDirectly, part)
        } catch {
            downloadLog.error("download-probe-failed ratingKey=\(item.ratingKey, privacy: .public) err=\(String(describing: error), privacy: .public)")
            recordDownloadDiagnostic("downloads.original_probe", fields: [
                "download_id": .identifier(item.ratingKey),
                "probe": .label("failed"),
                "container": .label(OfflineDownloadDecision.containerLabel(part: part)),
                "local_playable": .bool(Self.isLocallyPlayableOriginal(part: part)),
            ])
            return (false, part)
        }
    }

    /// Download quality labels for the sheet. Plex exposes three server Media Optimizer
    /// target tags, but first-party clients also offer custom sync/videoQuality profiles
    /// (Universal TV + 20/12/10/8 Mbps 1080p, 720p, 480p, etc.). Always include those
    /// custom profiles so the offline picker matches the iPad-style quality ladder.
    public func optimizePresetNames(server: URL, token: String) async -> [String] {
        let serverTargets = (try? await appModel.client.send(
            OptimizeRequest.mediaProcessingTargetsRequest(server: server, token: token,
                                                          identity: appModel.identity),
            as: MediaProcessingTargets.self))?.targets.map(\.name) ?? []
        return Self.dedup(serverTargets + Self.customDownloadProfileNames)
            .filter(Self.isVisibleDownloadPresetName)
            .filter { !$0.isEmpty }
    }

    /// Probe-driven download entry point (offline-download redesign). `choice` comes from the
    /// sheet, which already ran the direct-play probe: `.original` direct-downloads the source
    /// file; `.optimize` renders a compatible MP4 server-side then downloads it. Both converge
    /// on the same background-`URLSession` + validation pipeline. Records state rather than
    /// throwing.
    public func download(_ item: MediaItem, choice: DownloadChoice,
                         mediaIndex: Int = 0, partIndex: Int = 0) async {
        let ratingKey = item.ratingKey
        // #84: resolve the Plex session ONCE from its own lane (never `appModel.activeBackend`),
        // then never re-read a per-lane credential field for the rest of this job.
        // (Named `backendSession` to avoid shadowing the instance `session` URLSession wrapper.)
        guard let backendSession = appModel.backendSession(for: .plex) else {
            recordDownloadDiagnostic("downloads.enqueue_failed", fields: [
                "backend": .label("Plex"),
                "reason": .label("not_authenticated"),
            ])
            lastError[ratingKey] = .notAuthenticated
            return
        }
        let token = backendSession.token
        let server = backendSession.baseURL
        guard !activeJobs.contains(ratingKey) else {
            recordDownloadDiagnostic("downloads.enqueue_ignored", fields: [
                "download_id": .identifier(ratingKey),
                "reason": .label("already_active"),
            ])
            return
        }
        activeJobs.insert(ratingKey)
        lastError[ratingKey] = nil
        // NOTE: no `defer { activeJobs.remove }` here — that fired when this function returned,
        // which (for both choices) is right after `session.start` merely KICKS OFF the transfer,
        // dropping in-flight protection while the file was still downloading. The protection is
        // now released terminally from `refreshRecords` (on `.complete`/`.failed`) and explicitly
        // on the exit paths below that never start a transfer.

        if case .optimize = choice,
           rejectIfOverStorageLimit(ratingKey: ratingKey, backend: "Plex",
                                    expectedBytes: estimatedBytes(for: item, choice: choice,
                                                                  mediaIndex: mediaIndex,
                                                                  partIndex: partIndex,
                                                                  backend: .plex)) {
            releaseInFlight(ratingKey: ratingKey)
            return
        }

        let chosenMedia = item.media?[safe: mediaIndex]
        let resolutionLabel = Self.displayResolutionLabel(choice: choice, chosenMedia: chosenMedia)
        let optimizeTargetName: String?
        if case .optimize(let targetName) = choice {
            optimizeTargetName = targetName
        } else {
            optimizeTargetName = nil
        }
        let metadata = Self.offlineMetadata(from: item, resolutionLabel: resolutionLabel,
                                            mediaIndex: mediaIndex, partIndex: partIndex,
                                            optimizeTargetName: optimizeTargetName,
                                            session: backendSession,
                                            downloadLane: Self.downloadLane(for: choice))
        recordDownloadDiagnostic("downloads.enqueue", fields: downloadDiagnosticFields(
            item: item,
            choice: choice,
            backend: "Plex",
            backendKind: .plex,
            mediaIndex: mediaIndex,
            partIndex: partIndex
        ))
        // D5/#102: cache poster-shaped artwork locally so artwork shows offline. Episodes
        // often expose a landscape still as `thumb`, which looks wrong in the Offline tab's
        // small portrait tile; prefer the show/season poster when TV hierarchy provides it.
        cachePoster(ratingKey: ratingKey, thumb: Self.offlinePosterRef(for: item),
                    server: server, token: token)
        cachePlexBIF(ratingKey: ratingKey, item: item, mediaIndex: mediaIndex,
                     server: server, token: token)

        switch choice {
        case .original:
            guard let part = chosenMedia?.part[safe: partIndex] else {
                recordDownloadDiagnostic("downloads.start_failed", fields: [
                    "download_id": .identifier(ratingKey),
                    "backend": .label("Plex"),
                    "reason": .label("no_media_part"),
                ])
                lastError[ratingKey] = .transferFailed("No media part to download.")
                releaseInFlight(ratingKey: ratingKey)
                return
            }
            // The original file is a STATIC GET with a real Content-Length + valid moov atom.
            let url = OptimizeRequest.downloadURL(server: server, token: token, partKey: part.key)
            let preflight = await preflightOriginalPlayback(ratingKey: ratingKey, url: url,
                                                            token: token, expectedBytes: part.size,
                                                            durationMs: part.duration ?? item.duration)
            guard preflight else {
                let fallback = Self.originalFallbackOptimizeTarget()
                recordDownloadDiagnostic("downloads.original_preflight_fallback", fields: [
                    "download_id": .identifier(ratingKey),
                    "target": .label(fallback),
                ])
                await triggerOptimizeAndDownload(item: item, targetName: fallback,
                                                 metadata: metadata, session: backendSession)
                return
            }

            let expectedBytes = estimatedBytes(for: item, choice: choice,
                                               mediaIndex: mediaIndex,
                                               partIndex: partIndex,
                                               backend: .plex) ?? part.size
            if rejectIfOverStorageLimit(ratingKey: ratingKey, backend: "Plex", expectedBytes: expectedBytes) {
                releaseInFlight(ratingKey: ratingKey)
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
            cacheChapterImages(ratingKey: ratingKey, item: item, backend: .plex,
                               server: server, token: token)
            cachePlexTextSubtitles(ratingKey: ratingKey, part: part, server: server, token: token)
            do {
                recordDownloadDiagnostic("downloads.start", fields: [
                    "download_id": .identifier(ratingKey),
                    "backend": .label("Plex"),
                    "choice": .label("original"),
                    "url_shape": .urlShape(url),
                    "expected_bytes": .bytes(part.size),
                ])
                try session.start(ratingKey: ratingKey, from: url, to: destination,
                                  expectedBytes: part.size)
                refreshRecords()
            } catch let error as DownloadError {
                recordDownloadDiagnostic("downloads.start_failed", fields: [
                    "download_id": .identifier(ratingKey),
                    "backend": .label("Plex"),
                    "error": .label(String(describing: error)),
                ])
                lastError[ratingKey] = error
                store.setStatus(ratingKey: ratingKey, .failed)
                refreshRecords()
            } catch {
                recordDownloadDiagnostic("downloads.start_failed", fields: [
                    "download_id": .identifier(ratingKey),
                    "backend": .label("Plex"),
                    "error": .error(error),
                ])
                lastError[ratingKey] = .transferFailed(String(describing: error))
                store.setStatus(ratingKey: ratingKey, .failed)
                refreshRecords()
            }

        case .optimize(let targetName):
            await triggerOptimizeAndDownload(item: item, targetName: targetName,
                                             metadata: metadata, session: backendSession)

        case .optimizeCompatible:
            // #83 is a Jellyfin/Emby-only lane. Plex's optimized-version model already produces a
            // compatible file at original video quality via its "Original video quality" target, so
            // map the choice onto that target rather than introducing a no-op Plex path.
            await triggerOptimizeAndDownload(item: item, targetName: Self.originalFallbackOptimizeTarget(),
                                             metadata: metadata, session: backendSession)
        }
    }

    private func fallbackOriginalValidationFailureIfPossible(ratingKey: String) async {
        // If this was already an optimizer/transcode-sourced file, do not loop. The fallback is
        // only for a true-original transfer that downloaded successfully but failed the final
        // local AVPlayer startup validation.
        //
        // #84: gate on the ROW's own backend (via the migration fallback), not `activeBackend`,
        // and resolve the Plex session from its lane — so the original→optimize fallback fires
        // even if the user has since switched to Jellyfin/Emby, as long as the Plex lane is still
        // configured (lanes persist independently).
        guard let record = store.records.first(where: { $0.ratingKey == ratingKey }),
              let metadata = record.metadata,
              metadata.resolvedBackendKind(ratingKey: ratingKey) == .plex,
              !transcodeSourcedDownloads.contains(ratingKey),
              queueTitleByRatingKey[ratingKey] == nil,
              metadata.optimizeTargetName?.isEmpty != false,
              let backendSession = appModel.backendSession(for: .plex) else { return }
        let item = metadata.makeMediaItem()
        let target = Self.originalFallbackOptimizeTarget()
        recordDownloadDiagnostic("downloads.original_validation_fallback", fields: [
            "download_id": .identifier(ratingKey),
            "target": .label(target),
        ])
        activeJobs.insert(ratingKey)
        lastError[ratingKey] = nil
        await triggerOptimizeAndDownload(item: item, targetName: target,
                                         metadata: metadata, session: backendSession)
    }

    private static func originalFallbackOptimizeTarget(defaults: UserDefaults = .standard) -> String {
        let stored = defaults.string(forKey: PlaybackPreferences.Keys.defaultDownloadQuality)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, isExplicitDownloadPresetName(stored) { return stored }
        return PlaybackPreferences.defaultDownloadQuality
    }

    private static func isExplicitDownloadPresetName(_ name: String) -> Bool {
        customDownloadProfile(named: name) != nil
    }

    private static func isVisibleDownloadPresetName(_ name: String) -> Bool {
        ![
            "Original Quality",
            "Optimized for TV",
            "Optimized for Mobile",
        ].contains { hidden in
            name.localizedCaseInsensitiveCompare(hidden) == .orderedSame
        }
    }

    /// Second-stage safety gate for user-selected Plex original downloads. The decision endpoint
    /// can say "direct play" but still not prove AVFoundation will open the static source URL as
    /// a local/offline-style file. Before committing a potentially huge transfer, briefly start
    /// the source in a muted `AVPlayer`. Passing means the original path continues; failing means
    /// we transparently fall back to the server optimizer.
    private func preflightOriginalPlayback(ratingKey: String, url: URL, token: String,
                                           expectedBytes: Int?, durationMs: Int?) async -> Bool {
        let policy = OfflinePlaybackValidationPolicy.make(durationMs: durationMs, isRemotePreflight: true)
        recordDownloadDiagnostic("downloads.original_playback_preflight", fields: [
            "download_id": .identifier(ratingKey),
            "phase": .label("start"),
            "url_shape": .urlShape(url),
            "expected_bytes": .bytes(expectedBytes),
            "required_playback_seconds": .secondsBucket(policy.requiredPlaybackSeconds),
            "timeout_seconds": .secondsBucket(policy.timeoutSeconds),
        ])

        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": PlexHeaders.media(identity: appModel.identity, token: token),
        ])
        let assetPlayable = (try? await asset.load(.isPlayable)) ?? false
        guard assetPlayable else {
            recordDownloadDiagnostic("downloads.original_playback_preflight", fields: [
                "download_id": .identifier(ratingKey),
                "phase": .label("failed"),
                "reason": .label("asset_not_playable"),
            ])
            return false
        }

        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.volume = 0
        player.automaticallyWaitsToMinimizeStalling = true
        player.play()
        defer {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }

        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(policy.timeoutSeconds * 1000)))
        var sawReady = false
        while ContinuousClock.now < deadline {
            switch item.status {
            case .failed:
                recordDownloadDiagnostic("downloads.original_playback_preflight", fields: [
                    "download_id": .identifier(ratingKey),
                    "phase": .label("failed"),
                    "reason": .label("item_failed"),
                    "error": .error(item.error),
                ])
                return false
            case .readyToPlay:
                sawReady = true
            case .unknown:
                break
            @unknown default:
                break
            }

            let seconds = player.currentTime().seconds
            if sawReady, seconds.isFinite, seconds >= policy.requiredPlaybackSeconds {
                recordDownloadDiagnostic("downloads.original_playback_preflight", fields: [
                    "download_id": .identifier(ratingKey),
                    "phase": .label("passed"),
                    "played": .secondsBucket(seconds),
                ])
                return true
            }
            try? await Task.sleep(for: .milliseconds(policy.pollIntervalMilliseconds))
        }

        recordDownloadDiagnostic("downloads.original_playback_preflight", fields: [
            "download_id": .identifier(ratingKey),
            "phase": .label("failed"),
            "reason": .label(sawReady ? "no_playback_progress" : "timeout_not_ready"),
        ])
        return false
    }

    /// Jellyfin download entry point. Original downloads use Jellyfin's static video stream
    /// endpoint; optimized choices stream a server-rendered MP4 from the
    /// video transcoder with auth in headers. Both paths use the same background transfer +
    /// validation pipeline as Plex downloads.
    public func downloadJellyfin(_ item: MediaItem, choice: DownloadChoice,
                                 mediaIndex: Int = 0,
                                 partIndex: Int = 0,
                                 mediaSourceIDOverride: String? = nil) async {
        let itemId = item.ratingKey
        let ratingKey = Self.jellyfinRecordKey(itemId)
        // #84: capture the Jellyfin session from its own lane; never re-read `appModel.jellyfin*`
        // or `activeBackend` for the rest of this job.
        // (Named `backendSession` to avoid shadowing the instance `session` URLSession wrapper.)
        guard let backendSession = appModel.backendSession(for: .jellyfin) else {
            recordDownloadDiagnostic("downloads.enqueue_failed", fields: [
                "backend": .label("Jellyfin"),
                "reason": .label("not_authenticated"),
            ])
            lastError[ratingKey] = .notAuthenticated
            return
        }
        let server = backendSession.baseURL
        let token = backendSession.token
        guard !activeJobs.contains(ratingKey) else {
            recordDownloadDiagnostic("downloads.enqueue_ignored", fields: [
                "download_id": .identifier(ratingKey),
                "backend": .label("Jellyfin"),
                "reason": .label("already_active"),
            ])
            return
        }
        activeJobs.insert(ratingKey)
        lastError[ratingKey] = nil
        // No `defer { activeJobs.remove }` — same in-flight-lifetime fix as the Plex path:
        // `session.start` only kicks off the transfer, so protection is released terminally
        // from `refreshRecords` (on `.complete`/`.failed`) plus the explicit no-start exits.

        if rejectIfOverStorageLimit(ratingKey: ratingKey, backend: "Jellyfin",
                                    expectedBytes: estimatedBytes(for: item, choice: choice,
                                                                  mediaIndex: mediaIndex,
                                                                  partIndex: partIndex,
                                                                  backend: .jellyfin)) {
            releaseInFlight(ratingKey: ratingKey)
            return
        }

        let media = item.media.flatMap { $0.indices.contains(mediaIndex) ? $0[mediaIndex] : nil }
        let part = media?.part.indices.contains(partIndex) == true ? media?.part[partIndex] : nil
        let resolutionLabel = Self.displayResolutionLabel(choice: choice, chosenMedia: media)
        let jellyfinMediaSourceID = mediaSourceIDOverride ?? Self.jellyfinMediaSourceID(media: media, part: part)
        var resolvedJellyfinMediaSourceID = jellyfinMediaSourceID
        let metadata = Self.offlineMetadata(from: item, resolutionLabel: resolutionLabel,
                                            mediaIndex: mediaIndex, partIndex: partIndex,
                                            optimizeTargetName: {
                                                if case .optimize(let targetName) = choice { return targetName }
                                                return nil
                                            }(),
                                            session: backendSession,
                                            mediaSourceID: jellyfinMediaSourceID,
                                            downloadLane: Self.downloadLane(for: choice))
        recordDownloadDiagnostic("downloads.enqueue", fields: downloadDiagnosticFields(
            item: item,
            choice: choice,
            backend: "Jellyfin",
            backendKind: .jellyfin,
            mediaIndex: mediaIndex,
            partIndex: partIndex
        ))
        let identity = appModel.identity.jellyfin
        var request: URLRequest
        var destination: URL
        var expectedBytes: Int?
        // #84: captured here so the minted PlaySessionId can be PERSISTED after the row is seeded
        // (below), enabling encoder teardown after a hard app kill — not just in-memory teardown.
        var mintedPlaySessionId: String?
        do {
            switch choice {
            case .original:
                let ext = part?.container ?? media?.container ?? "mp4"
                destination = store.destinationURL(ratingKey: ratingKey,
                                                   ext: ext.isEmpty ? "mp4" : ext)
                request = try JellyfinLibrary.downloadRequest(server: server,
                                                              token: token,
                                                              identity: identity,
                                                              itemId: itemId,
                                                              mediaSourceId: jellyfinMediaSourceID,
                                                              container: ext)
                expectedBytes = part?.size

            case .optimize(let targetName):
                let profile = Self.jellyfinTranscodeProfile(named: targetName)
                destination = store.destinationURL(ratingKey: ratingKey, ext: "mp4")
                expectedBytes = Self.estimatedTranscodeBytes(durationMs: item.duration,
                                                             videoBitrateBps: profile.videoBitrateBps)
                let playSessionId = "visionplay-download-\(UUID().uuidString)"
                let transcodedRequest: URLRequest = Self.jellyfinTranscodedDownloadRequest(
                    server, token, identity, itemId, jellyfinMediaSourceID, playSessionId, profile)
                request = transcodedRequest
                jellyfinPlaySessionByRatingKey[ratingKey] = playSessionId
                mintedPlaySessionId = playSessionId

            case .optimizeCompatible:
                // #83: original-quality compatible remux. Re-probe PlaybackInfo here instead of
                // trusting the in-memory `Part` streams: retry after relaunch reconstructs a lean
                // `MediaItem` without stream arrays, and the server's codec/container verdict
                // is the authoritative remux gate.
                guard let userId = backendSession.userID, !userId.isEmpty else {
                    throw DownloadError.notAuthenticated
                }
                destination = store.destinationURL(ratingKey: ratingKey, ext: "mp4")
                let infoReq = try JellyfinPlayback.downloadPlaybackInfoRequest(
                    server: server, token: token, identity: identity,
                    itemId: itemId, userId: userId,
                    mediaSourceId: jellyfinMediaSourceID,
                    maxStaticBitrate: 200_000_000)
                let (data, response) = try await URLSession.shared.data(for: infoReq)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw DownloadError.transferFailed("PlaybackInfo HTTP \(http.statusCode)")
                }
                let info = try JellyfinPlaybackInfoResponse.decode(from: data)
                let decision = try JellyfinPlayback.downloadDecision(response: info,
                                                                     preferredMediaSourceId: jellyfinMediaSourceID)
                resolvedJellyfinMediaSourceID = decision.mediaSourceId
                let eligibility = OfflineDownloadDecision.compatibleRemuxEligibility(
                    videoCodec: decision.videoCodec,
                    audioCodec: decision.audioCodec,
                    sourceContainer: decision.container)
                let routeIsRemux = eligibility.isEligible
                recordDownloadDiagnostic("downloads.jellyfin_decision", fields: [
                    "download_id": .identifier(ratingKey),
                    "negotiated_direct_play": .bool(decision.supportsDirectPlay),
                    "negotiated_direct_stream": .bool(decision.supportsDirectStream),
                    "container": .label(decision.container ?? "unknown"),
                    "route": .label(routeIsRemux ? "compatible_remux" : "transcode"),
                    "reasons": .label(decision.transcodeReasons.joined(separator: ",")),
                ])
                if routeIsRemux, let videoCodec = eligibility.videoCodec {
                    // Output keeps original video bytes → expected size ≈ original source size.
                    expectedBytes = decision.size ?? part?.size
                    request = try JellyfinLibrary.compatibleRemuxDownloadRequest(
                        server: server, token: token, identity: identity, itemId: itemId,
                        mediaSourceId: decision.mediaSourceId,
                        videoCodec: videoCodec, copyAudio: eligibility.copiesAudio,
                        playSessionId: decision.playSessionId)
                } else {
                    // Stale UI/retry fallback: keep the download safe and playable when the
                    // source video cannot be copied into the compatible MP4 lane.
                    let profile = Self.jellyfinTranscodeProfile(named: Self.jellyfinDefaultDownloadPreset)
                    expectedBytes = Self.estimatedTranscodeBytes(durationMs: item.duration,
                                                                 videoBitrateBps: profile.videoBitrateBps)
                    request = Self.jellyfinTranscodedDownloadRequest(
                        server, token, identity, itemId, decision.mediaSourceId,
                        decision.playSessionId, profile)
                }
                jellyfinPlaySessionByRatingKey[ratingKey] = decision.playSessionId
                mintedPlaySessionId = decision.playSessionId
            }
        } catch {
            recordDownloadDiagnostic("downloads.start_failed", fields: [
                "download_id": .identifier(ratingKey),
                "backend": .label("Jellyfin"),
                "error": .error(error),
            ])
            lastError[ratingKey] = .transferFailed(String(describing: error))
            store.setStatus(ratingKey: ratingKey, .failed)
            releaseInFlight(ratingKey: ratingKey)
            refreshRecords()
            return
        }

        store.upsert(DownloadRecord(ratingKey: ratingKey, title: item.title,
                                    localURL: destination, bytes: 0, progress: 0,
                                    metadata: metadata))
        // #84: persist the minted PlaySessionId onto the now-seeded row so a hard app kill can
        // still tear the encoder down on next launch (was in-memory only).
        if let mintedPlaySessionId {
            store.setPlaySessionID(ratingKey: ratingKey, mintedPlaySessionId)
        }
        if let resolvedJellyfinMediaSourceID,
           resolvedJellyfinMediaSourceID != jellyfinMediaSourceID {
            store.setMediaSourceID(ratingKey: ratingKey, resolvedJellyfinMediaSourceID)
        }
        refreshRecords()
        // #102: cache the poster locally (best-effort) so artwork shows offline. Unlike the
        // Plex lane this MUST use the authenticated MediaBrowser image request.
        cacheJellyfinPoster(ratingKey: ratingKey, item: item, server: server,
                            token: token, identity: identity)
        cacheJellyfinTrickPlay(ratingKey: ratingKey, itemId: itemId, mediaSourceId: resolvedJellyfinMediaSourceID,
                               server: server, token: token, identity: identity)
        cacheChapterImages(ratingKey: ratingKey, item: item, backend: .jellyfin,
                           server: server, token: token)
        if case .original = choice {
            cacheJellyfinTextSubtitles(ratingKey: ratingKey, itemId: itemId, mediaSourceId: resolvedJellyfinMediaSourceID,
                                       part: part, server: server, token: token, identity: identity)
        }

        do {
            recordDownloadDiagnostic("downloads.start", fields: [
                "download_id": .identifier(ratingKey),
                "backend": .label("Jellyfin"),
                "choice": .label(Self.diagnosticChoiceLabel(choice)),
                "url_shape": .urlShape(request.url),
                "expected_bytes": .bytes(expectedBytes),
            ])
            // A Jellyfin `.optimize`/`.optimizeCompatible` download streams the file directly from
            // the transcoder/remuxer — there is no separate "render then static download" phase, so
            // the byte rate is encoder-gated and the stream is forward-only (not range-resumable).
            // Mark it so the rate isn't misread as a network problem. `.original` is a static file
            // stream → network-bound, range-resumable, not marked.
            switch choice {
            case .optimize, .optimizeCompatible: transcodeSourcedDownloads.insert(ratingKey)
            case .original: break
            }
            try session.start(ratingKey: ratingKey,
                              with: request,
                              to: destination,
                              expectedBytes: expectedBytes)
            refreshRecords()
        } catch let error as DownloadError {
            recordDownloadDiagnostic("downloads.start_failed", fields: [
                "download_id": .identifier(ratingKey),
                "backend": .label("Jellyfin"),
                "error": .label(String(describing: error)),
            ])
            lastError[ratingKey] = error
            store.setStatus(ratingKey: ratingKey, .failed)
            releaseInFlight(ratingKey: ratingKey)
            refreshRecords()
        } catch {
            recordDownloadDiagnostic("downloads.start_failed", fields: [
                "download_id": .identifier(ratingKey),
                "backend": .label("Jellyfin"),
                "error": .error(error),
            ])
            lastError[ratingKey] = .transferFailed(String(describing: error))
            store.setStatus(ratingKey: ratingKey, .failed)
            releaseInFlight(ratingKey: ratingKey)
            refreshRecords()
        }
    }

    public func downloadJellyfinOriginal(_ item: MediaItem,
                                         mediaIndex: Int = 0,
                                         partIndex: Int = 0) async {
        await downloadJellyfin(item, choice: .original, mediaIndex: mediaIndex, partIndex: partIndex)
    }

    /// Best-effort cache of Jellyfin trickplay assets for offline scrubbing (#79). Fetches the
    /// playlist, downloads each referenced tile through header auth (stripping ApiKey from tile
    /// URLs in the request builder), then writes a sanitized local playlist whose tile lines are
    /// only local filenames. A miss/corrupt playlist never fails the media download.
    private func cacheJellyfinTrickPlay(ratingKey: String,
                                        itemId: String,
                                        mediaSourceId: String?,
                                        server: URL,
                                        token: String,
                                        identity: JellyfinClientIdentity,
                                        width: Int = 320) {
        guard let mediaSourceId, !mediaSourceId.isEmpty else { return }
        let store = self.store
        Task { [weak self] in
            do {
                let playlistReq = try JellyfinLibrary.trickPlayPlaylistRequest(server: server,
                                                                               token: token,
                                                                               identity: identity,
                                                                               itemId: itemId,
                                                                               mediaSourceId: mediaSourceId,
                                                                               width: width)
                let (playlistData, playlistResponse) = try await URLSession.shared.data(for: playlistReq)
                guard let playlistHTTP = playlistResponse as? HTTPURLResponse,
                      (200..<300).contains(playlistHTTP.statusCode),
                      let playlistText = String(data: playlistData, encoding: .utf8) else { return }
                let playlist = try JellyfinTrickPlayPlaylistParser.parse(playlistText)
                // Fetch the tile sheets CONCURRENTLY — they are independent and a long movie has many
                // sheets, so serial round-trips dominate the cache time. Disk writes + the URI→filename
                // map are then built deterministically in tile order. A tile that fails to fetch is
                // simply dropped (its frame just has no offline thumbnail).
                let fetched: [(index: Int, uri: String, data: Data)] = await withTaskGroup(of: (Int, String, Data)?.self) { group in
                    for (index, tile) in playlist.tiles.enumerated() {
                        guard let tileReq = try? JellyfinLibrary.trickPlayTileRequest(server: server,
                                                                                      token: token,
                                                                                      identity: identity,
                                                                                      itemId: itemId,
                                                                                      mediaSourceId: mediaSourceId,
                                                                                      width: width,
                                                                                      tileURI: tile.uri) else { continue }
                        let uri = tile.uri
                        group.addTask {
                            guard let (tileData, tileResponse) = try? await URLSession.shared.data(for: tileReq),
                                  let tileHTTP = tileResponse as? HTTPURLResponse,
                                  (200..<300).contains(tileHTTP.statusCode),
                                  !tileData.isEmpty else { return nil }
                            return (index, uri, tileData)
                        }
                    }
                    var out: [(index: Int, uri: String, data: Data)] = []
                    for await result in group { if let result { out.append(result) } }
                    return out.sorted { $0.index < $1.index }
                }
                var tileRelatives: [String] = []
                var tileFilenamesByURI: [String: String] = [:]
                for entry in fetched {
                    let destination = store.jellyfinTrickPlayTileDestinationURL(ratingKey: ratingKey, index: entry.index)
                    try entry.data.write(to: destination, options: .atomic)
                    tileFilenamesByURI[entry.uri] = destination.lastPathComponent
                    tileRelatives.append(destination.lastPathComponent)
                }
                guard !tileRelatives.isEmpty else { return }
                let sanitized = JellyfinTrickPlayOfflineCachePlanner.sanitizedPlaylist(playlistText, tileFilenamesByURI: tileFilenamesByURI)
                guard !sanitized.localizedCaseInsensitiveContains("apikey=") else { return }
                let playlistURL = store.jellyfinTrickPlayPlaylistDestinationURL(ratingKey: ratingKey)
                try sanitized.data(using: .utf8)?.write(to: playlistURL, options: .atomic)
                await MainActor.run {
                    store.setJellyfinTrickPlayRelativePaths(ratingKey: ratingKey,
                                                            playlist: playlistURL.lastPathComponent,
                                                            tiles: tileRelatives)
                    self?.refreshRecords()
                }
            } catch {
                // Optional asset cache. Never log token-bearing playlist/tile URLs.
            }
        }
    }

    /// Emby download entry point. Mirrors `downloadJellyfin`'s structure, with the Emby-specific
    /// corrections proven live against the worst-case MKV item:
    ///
    /// - The route is decided by an AUTHORITATIVE download PlaybackInfo POST (the naked-item
    ///   `SupportsDirectPlay` is optimistic garbage). We advertise a Static-mp4 DOWNLOAD device
    ///   profile (NOT the HLS playback profile) so the negotiated transcode URL is a single
    ///   downloadable file rather than a `.m3u8` playlist.
    /// - Original ⇔ negotiated `SupportsDirectPlay && isLocallyPlayableOriginal(container)`.
    ///   Original uses the static `stream.{container}?static=true` GET (HTTP 206, resumable);
    ///   expected bytes = `MediaSource.Size` (Emby's `Part.size` is always nil).
    /// - Everything else downloads the SERVER-MINTED `TranscodingUrl` (you cannot hand-build it —
    ///   Emby requires the PlaybackInfo-minted `PlaySessionId`). Transcoded streams are not
    ///   range-resumable, so they restart on failure (like Jellyfin), expected bytes are the
    ///   quality×runtime estimate, and the minted `PlaySessionId` is persisted so the FFmpeg
    ///   encoder is torn down on every terminal transition (`releaseInFlight`).
    public func downloadEmby(_ item: MediaItem, choice: DownloadChoice,
                             mediaIndex: Int = 0,
                             partIndex: Int = 0,
                             mediaSourceIDOverride: String? = nil) async {
        let itemId = item.ratingKey
        let ratingKey = Self.embyRecordKey(itemId)
        // #84: capture the Emby session from its own lane; never re-read `appModel.emby*` or
        // `activeBackend` for the rest of this job.
        // (Named `backendSession` to avoid shadowing the instance `session` URLSession wrapper.)
        guard let backendSession = appModel.backendSession(for: .emby),
              let userId = backendSession.userID else {
            recordDownloadDiagnostic("downloads.enqueue_failed", fields: [
                "backend": .label("Emby"),
                "reason": .label("not_authenticated"),
            ])
            lastError[ratingKey] = .notAuthenticated
            return
        }
        let server = backendSession.baseURL
        let token = backendSession.token
        guard !activeJobs.contains(ratingKey) else {
            recordDownloadDiagnostic("downloads.enqueue_ignored", fields: [
                "download_id": .identifier(ratingKey),
                "backend": .label("Emby"),
                "reason": .label("already_active"),
            ])
            return
        }
        activeJobs.insert(ratingKey)
        lastError[ratingKey] = nil
        // No `defer { activeJobs.remove }` — same in-flight-lifetime contract as the other lanes:
        // `session.start` only kicks off the transfer, so protection (and the encoder-teardown
        // PlaySessionId) is released terminally from `refreshRecords`/`releaseInFlight`.

        if rejectIfOverStorageLimit(ratingKey: ratingKey, backend: "Emby",
                                    expectedBytes: estimatedBytes(for: item, choice: choice,
                                                                  mediaIndex: mediaIndex,
                                                                  partIndex: partIndex,
                                                                  backend: .emby)) {
            releaseInFlight(ratingKey: ratingKey)
            return
        }

        let media = item.media?[safe: mediaIndex]
        let part = media?.part[safe: partIndex]
        let resolutionLabel = Self.displayResolutionLabel(choice: choice, chosenMedia: media)
        // Pre-decision media-source hint; the authoritative id (from PlaybackInfo) is persisted
        // onto the row after the decision is known (see below).
        let embyMediaSourceHint = mediaSourceIDOverride ?? Self.embyMediaSourceID(media: media, part: part)
        let metadata = Self.offlineMetadata(from: item, resolutionLabel: resolutionLabel,
                                            mediaIndex: mediaIndex, partIndex: partIndex,
                                            optimizeTargetName: {
                                                if case .optimize(let targetName) = choice { return targetName }
                                                return nil
                                            }(),
                                            session: backendSession,
                                            mediaSourceID: embyMediaSourceHint,
                                            downloadLane: Self.downloadLane(for: choice))
        recordDownloadDiagnostic("downloads.enqueue", fields: downloadDiagnosticFields(
            item: item,
            choice: choice,
            backend: "Emby",
            backendKind: .emby,
            mediaIndex: mediaIndex,
            partIndex: partIndex
        ))
        let identity = appModel.identity.emby
        // Authoritative negotiation: POST the DOWNLOAD device profile and read the negotiated
        // verdict. ~200 Mbps ceiling so a high-bitrate-but-compatible file still qualifies for an
        // original download — a bitrate cap must NEVER force a transcode verdict for a download.
        let decision: EmbyPlayback.EmbyDownloadPlaybackDecision
        do {
            let infoReq: URLRequest
            if case .optimizeCompatible = choice {
                // #83: keep the normal download profile conservative for the forced-transcode lane,
                // but use a remux profile here so HEVC stream-copy eligibility is visible.
                infoReq = try EmbyPlayback.compatibleRemuxDownloadPlaybackInfoRequest(
                    server: server, token: token, identity: identity,
                    userId: userId, itemId: itemId,
                    mediaSourceId: embyMediaSourceHint,
                    maxStaticBitrate: 200_000_000)
            } else {
                infoReq = try EmbyPlayback.downloadPlaybackInfoRequest(
                    server: server, token: token, identity: identity,
                    userId: userId, itemId: itemId,
                    mediaSourceId: embyMediaSourceHint,
                    maxStaticBitrate: 200_000_000)
            }
            let (data, response) = try await URLSession.shared.data(for: infoReq)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw DownloadError.transferFailed("PlaybackInfo HTTP \(http.statusCode)")
            }
            let info = try EmbyPlaybackInfoResponse.decode(from: data)
            decision = try EmbyPlayback.downloadDecision(response: info,
                                                         preferredMediaSourceId: embyMediaSourceHint)
        } catch {
            recordDownloadDiagnostic("downloads.start_failed", fields: [
                "download_id": .identifier(ratingKey),
                "backend": .label("Emby"),
                "phase": .label("playback_info"),
                "error": .error(error),
            ])
            lastError[ratingKey] = (error as? DownloadError) ?? .transferFailed(String(describing: error))
            store.setStatus(ratingKey: ratingKey, .failed)
            releaseInFlight(ratingKey: ratingKey)
            refreshRecords()
            return
        }

        // Three-way route detection against the AUTHORITATIVE negotiated verdict:
        //   .original          ⇔ negotiated DirectPlay AND locally playable container
        //   .compatibleRemux   ⇔ user chose it AND source video copyable (#83)
        //   .transcode         ⇔ otherwise (forced h264/aac re-encode)
        // The user's `.optimize` choice always forces the transcode lane.
        let containerGate = Self.isLocallyPlayableOriginal(part: part)
            || ["mp4", "m4v", "mov"].contains((decision.container ?? "").lowercased())
        let remuxEligibility = OfflineDownloadDecision.compatibleRemuxEligibility(
            videoCodec: decision.videoCodec, audioCodec: decision.audioCodec,
            sourceContainer: decision.container)
        enum EmbyDownloadRoute { case original, compatibleRemux, transcode }
        let route: EmbyDownloadRoute
        switch choice {
        case .original:
            route = (decision.supportsDirectPlay && containerGate) ? .original : .transcode
        case .optimizeCompatible:
            // Honour the compatible lane when the source video is stream-copy eligible. The
            // negotiated DirectStream flag may be false for audio-only transcode cases (for
            // example HEVC + DTS -> MP4 + AAC), which still preserve original video quality.
            route = remuxEligibility.isEligible ? .compatibleRemux : .transcode
        case .optimize:
            route = .transcode
        }
        recordDownloadDiagnostic("downloads.emby_decision", fields: [
            "download_id": .identifier(ratingKey),
            "negotiated_direct_play": .bool(decision.supportsDirectPlay),
            "negotiated_direct_stream": .bool(decision.supportsDirectStream),
            "container": .label(decision.container ?? "unknown"),
            "container_gate": .bool(containerGate),
            "route": .label(route == .original ? "original" : route == .compatibleRemux ? "compatible_remux" : "transcode"),
            "reasons": .label(decision.transcodeReasons.joined(separator: ",")),
        ])

        var request: URLRequest
        var destination: URL
        var expectedBytes: Int?
        // Both the transcode and compatible-remux lanes are encoder-served, forward-only, and mint a
        // server-side session that MUST be torn down on a terminal transition.
        let useServerSession = (route != .original)
        do {
            switch route {
            case .original:
                let ext = decision.container ?? part?.container ?? media?.container ?? "mp4"
                destination = store.destinationURL(ratingKey: ratingKey,
                                                   ext: ext.isEmpty ? "mp4" : ext)
                request = try EmbyLibrary.downloadOriginalRequest(
                    server: server, token: token, identity: identity, userId: userId,
                    itemId: itemId, mediaSourceId: decision.mediaSourceId, container: ext)
                // Emby's Part.size is nil — MediaSource.Size is the only storage signal.
                expectedBytes = decision.size

            case .compatibleRemux:
                // #83: copy the original video into MP4, transcode audio→AAC as needed. Output keeps
                // original video bytes → expected size ≈ source size (the AVPlayer probe + HEVC tag
                // fixup are the correctness gate; a server copy failure falls to a retry, not silent
                // corruption).
                destination = store.destinationURL(ratingKey: ratingKey, ext: "mp4")
                request = try EmbyLibrary.compatibleRemuxDownloadRequest(
                    server: server, token: token, identity: identity, userId: userId,
                    itemId: itemId, mediaSourceId: decision.mediaSourceId,
                    playSessionId: decision.playSessionId,
                    videoCodec: remuxEligibility.videoCodec ?? "h264",
                    copyAudio: remuxEligibility.copiesAudio,
                    audioBitrate: 192_000)
                expectedBytes = decision.size

            case .transcode:
                // Emby mints a codecless `/videos/{id}/stream` URL that ffmpeg stream-COPIES and
                // fails on (HTTP 500) for HEVC/DTS sources; build the EXPLICIT static `stream.mp4`
                // transcode URL with the minted PlaySessionId instead (see transcodedDownloadRequest).
                destination = store.destinationURL(ratingKey: ratingKey, ext: "mp4")
                // Transcode is rendered as it downloads → estimate, no Content-Length.
                let profile = Self.jellyfinTranscodeProfile(named: {
                    if case .optimize(let targetName) = choice { return targetName }
                    return Self.jellyfinDefaultDownloadPreset
                }())
                request = try EmbyLibrary.transcodedDownloadRequest(
                    server: server, token: token, identity: identity, userId: userId,
                    itemId: itemId, mediaSourceId: decision.mediaSourceId,
                    playSessionId: decision.playSessionId,
                    videoBitrate: profile.videoBitrateBps,
                    audioBitrate: 192_000)
                expectedBytes = Self.estimatedTranscodeBytes(durationMs: item.duration,
                                                             videoBitrateBps: profile.videoBitrateBps)
            }
        } catch {
            recordDownloadDiagnostic("downloads.start_failed", fields: [
                "download_id": .identifier(ratingKey),
                "backend": .label("Emby"),
                "error": .error(error),
            ])
            lastError[ratingKey] = (error as? DownloadError) ?? .transferFailed(String(describing: error))
            store.setStatus(ratingKey: ratingKey, .failed)
            releaseInFlight(ratingKey: ratingKey)
            refreshRecords()
            return
        }

        store.upsert(DownloadRecord(ratingKey: ratingKey, title: item.title,
                                    localURL: destination, bytes: 0, progress: 0,
                                    metadata: metadata))
        // #84: the authoritative media-source id comes from the PlaybackInfo decision; persist it
        // (replacing the pre-decision hint) so a retry can re-issue without re-deriving.
        if !decision.mediaSourceId.isEmpty, decision.mediaSourceId != embyMediaSourceHint {
            store.setMediaSourceID(ratingKey: ratingKey, decision.mediaSourceId)
        }
        refreshRecords()
        // #102: cache the poster locally (best-effort) so artwork shows offline. The Emby image
        // endpoint needs the authenticated request (token + userId in the header), unlike Plex.
        cacheEmbyPoster(ratingKey: ratingKey, item: item, server: server,
                        token: token, identity: identity, userId: userId)
        // #88/#89: cache per-chapter images for the offline Chapters rail AND the Emby offline
        // scrubber. This is a static `/Items/{id}/Images/Chapter/{index}` GET — no PlaySessionId /
        // encoder negotiation — so it is safe to fire here independent of the media transfer.
        cacheChapterImages(ratingKey: ratingKey, item: item, backend: .emby,
                           server: server, token: token)

        do {
            recordDownloadDiagnostic("downloads.start", fields: [
                "download_id": .identifier(ratingKey),
                "backend": .label("Emby"),
                "choice": .label(route == .original ? "original" : route == .compatibleRemux ? "optimize_compatible" : Self.diagnosticChoiceLabel(choice)),
                "url_shape": .urlShape(request.url),
                "expected_bytes": .bytes(expectedBytes),
            ])
            if useServerSession {
                // Transcode/remux download: rate is encoder-gated (served as it renders), forward-only
                // (not range-resumable), and the minted PlaySessionId MUST be torn down on terminal
                // transition. #84: persist it onto the row so a hard app kill can still tear the
                // encoder down on next launch.
                transcodeSourcedDownloads.insert(ratingKey)
                embyPlaySessionByRatingKey[ratingKey] = decision.playSessionId
                store.setPlaySessionID(ratingKey: ratingKey, decision.playSessionId)
            }
            try session.start(ratingKey: ratingKey,
                              with: request,
                              to: destination,
                              expectedBytes: expectedBytes)
            refreshRecords()
        } catch let error as DownloadError {
            recordDownloadDiagnostic("downloads.start_failed", fields: [
                "download_id": .identifier(ratingKey),
                "backend": .label("Emby"),
                "error": .label(String(describing: error)),
            ])
            lastError[ratingKey] = error
            store.setStatus(ratingKey: ratingKey, .failed)
            releaseInFlight(ratingKey: ratingKey)
            refreshRecords()
        } catch {
            recordDownloadDiagnostic("downloads.start_failed", fields: [
                "download_id": .identifier(ratingKey),
                "backend": .label("Emby"),
                "error": .error(error),
            ])
            lastError[ratingKey] = .transferFailed(String(describing: error))
            store.setStatus(ratingKey: ratingKey, .failed)
            releaseInFlight(ratingKey: ratingKey)
            refreshRecords()
        }
    }

    /// Extract an Emby `mediaSourceId` from a `MediaItem`'s synthesized part keys
    /// (`emby://item/{itemId}/media/{mediaSourceId}`). The authoritative id comes from the
    /// download PlaybackInfo decision; this only seeds the PlaybackInfo `MediaSourceId` hint.
    private static func embyMediaSourceID(media: Media?, part: Part?) -> String? {
        let keys = [part?.key] + (media?.part.map(\.key) ?? [])
        for key in keys.compactMap({ $0 }) {
            guard let marker = key.range(of: "/media/") else { continue }
            let source = String(key[marker.upperBound...])
            if !source.isEmpty { return source }
        }
        return nil
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
        recordDownloadDiagnostic("downloads.retry", fields: [
            "download_id": .identifier(ratingKey),
        ])
        lastError[ratingKey] = nil
        // #95: a recoverably-interrupted (`.paused`) row with persisted resume data should
        // CONTINUE from its byte offset rather than discarding the partial and restarting. This
        // path is backend-agnostic — only range-resumable sources (static originals) ever have
        // resume data, so transcoded JF/Emby rows naturally fall through to the clean restart
        // below. If the resume task is later rejected by the server (200 full-restart / 416), the
        // normal failure path makes the row retryable again from scratch.
        if record.status == .paused,
           store.supportsPersistedResumeData(ratingKey: ratingKey),
           let resumeData = store.resumeData(ratingKey: ratingKey) {
            store.clearResumeData(ratingKey: ratingKey)
            store.setStatus(ratingKey: ratingKey, .downloading)
            if session.resume(ratingKey: ratingKey, resumeData: resumeData, to: record.localURL) {
                activeJobs.insert(ratingKey)
                refreshRecords()
                return
            }
            // resume() refused the blob — fall through to a clean restart below.
            store.setStatus(ratingKey: ratingKey, .failed)
        }
        if Self.isJellyfinRecordKey(ratingKey) {
            retryJellyfin(record: record)
            return
        }
        if Self.isEmbyRecordKey(ratingKey) {
            retryEmby(record: record)
            return
        }
        let metadata = record.metadata
        let item = metadata?.makeMediaItem()
            ?? MediaItem(ratingKey: record.ratingKey, title: record.title, type: "movie")
        let mediaIndex = metadata?.mediaIndex ?? 0
        let partIndex = metadata?.partIndex ?? 0
        // Re-probe so the retry takes the correct path: a now-compatible file goes direct,
        // otherwise re-render via the optimizer using the user's explicit default preset. Keep the
        // failed row visible until after auth/server preflight succeeds; otherwise tapping retry
        // while disconnected/not-ready removes the only visible retry affordance.
        Task { [weak self] in
            guard let self else { return }
            // #84: resolve the Plex session from its own lane (not `activeBackend`); a row whose
            // lane is unconfigured stays `.failed`/retryable with the accurate not-signed-in reason.
            guard let backendSession = self.appModel.backendSession(for: .plex) else {
                self.lastError[ratingKey] = .notAuthenticated
                self.store.setStatus(ratingKey: ratingKey, .failed)
                self.refreshRecords()
                return
            }
            let server = backendSession.baseURL
            let token = backendSession.token
            guard !self.activeJobs.contains(ratingKey) else { return }
            let currentItem = await self.fetchCurrentMediaItem(ratingKey: ratingKey,
                                                               server: server,
                                                               token: token,
                                                               identity: self.appModel.identity) ?? item
            let probe = await self.directPlayProbe(for: currentItem, server: server, token: token,
                                                   mediaIndex: mediaIndex, partIndex: partIndex)
            let media = currentItem.media?.indices.contains(mediaIndex) == true ? currentItem.media?[mediaIndex] : currentItem.media?.first
            let part = probe.part ?? (media?.part.indices.contains(partIndex) == true ? media?.part[partIndex] : media?.part.first)
            let choice: DownloadChoice = (probe.direct && Self.isLocallyPlayableOriginal(part: part))
                ? .original
                : .optimize(targetName: Self.originalFallbackOptimizeTarget())
            // Drop the stale `.failed` row only once we know the replacement can be seeded.
            // This also removes any leftover invalid/partial file from the failed attempt.
            self.store.remove(ratingKey: ratingKey)
            await self.download(currentItem, choice: choice, mediaIndex: mediaIndex, partIndex: partIndex)
            self.refreshRecords()
        }
    }

    private func retryJellyfin(record: DownloadRecord) {
        let metadata = record.metadata
        let item = metadata?.makeMediaItem()
            ?? MediaItem(ratingKey: Self.jellyfinItemID(fromRecordKey: record.ratingKey),
                         title: record.title,
                         type: "movie")
        let mediaIndex = metadata?.mediaIndex ?? 0
        let partIndex = metadata?.partIndex ?? 0
        let media = item.media?.indices.contains(mediaIndex) == true ? item.media?[mediaIndex] : item.media?.first
        let part = media?.part.indices.contains(partIndex) == true ? media?.part[partIndex] : media?.part.first
        let choice: DownloadChoice
        if let targetName = metadata?.optimizeTargetName, !targetName.isEmpty {
            choice = .optimize(targetName: Self.jellyfinDownloadPreset(named: targetName))
        } else if metadata?.resolvedDownloadLane() == .compatibleRemux {
            // #83: a persisted compatible-remux row has no optimizeTargetName, so without the lane
            // discriminator it would rehydrate as `.original` and silently drop the user's intent.
            choice = .optimizeCompatible
        } else if metadata != nil {
            // #84: stored rows know the original user intent. `makeMediaItem()` intentionally does
            // not rehydrate full MediaSource/Part arrays, so deriving this from `part` after a
            // relaunch would incorrectly turn original retries into optimized transcodes.
            // #90 (won't-fix): deliberately NO Emby-style PlaybackInfo re-probe here — Jellyfin's
            // normal `.original` path doesn't probe either, and re-probing only on retry would make
            // retry behave differently from the first attempt. The theoretical
            // `.original`→fail→`.original` loop needs a non-transient route-specific failure and is
            // self-limiting (manual retry only). If a real stuck loop is ever reported, the minimal
            // fix is an attempt-count escalation to the default download preset after N consecutive
            // `.original` failures — cheaper than a speculative re-probe (mediaSourceID IS persisted).
            choice = .original
        } else if Self.isLocallyPlayableOriginal(part: part) {
            choice = .original
        } else {
            choice = .optimize(targetName: Self.jellyfinDefaultDownloadPreset)
        }

        Task { [weak self] in
            guard let self else { return }
            // #84: gate on the Jellyfin lane being configured (resolved from its own session),
            // independent of `activeBackend`; an unconfigured lane stays retryable with the
            // accurate not-signed-in reason.
            guard self.appModel.backendSession(for: .jellyfin) != nil else {
                self.lastError[record.ratingKey] = .notAuthenticated
                self.store.setStatus(ratingKey: record.ratingKey, .failed)
                self.refreshRecords()
                return
            }
            guard !self.activeJobs.contains(record.ratingKey) else { return }
            // Keep the failed row visible until `downloadJellyfin` successfully seeds the
            // replacement. If PlaybackInfo/auth/network preflight fails, its start-failed path can
            // mark this existing row `.failed` instead of making the retry affordance disappear.
            await self.downloadJellyfin(item, choice: choice,
                                        mediaIndex: mediaIndex,
                                        partIndex: partIndex,
                                        mediaSourceIDOverride: metadata?.mediaSourceID)
            self.refreshRecords()
        }
    }

    private func retryEmby(record: DownloadRecord) {
        let metadata = record.metadata
        let item = metadata?.makeMediaItem()
            ?? MediaItem(ratingKey: Self.embyItemID(fromRecordKey: record.ratingKey),
                         title: record.title,
                         type: "movie")
        let mediaIndex = metadata?.mediaIndex ?? 0
        let partIndex = metadata?.partIndex ?? 0
        // Choice intent only — `downloadEmby` re-probes PlaybackInfo and decides the real route, so
        // a now-compatible file goes original even if the failed row had an optimize target. We
        // pass `.original` unless the row explicitly recorded an optimize preset, in which case we
        // honour the user's downscale request via the explicit ladder.
        let choice: DownloadChoice
        if let targetName = metadata?.optimizeTargetName, !targetName.isEmpty {
            choice = .optimize(targetName: Self.jellyfinDownloadPreset(named: targetName))
        } else if metadata?.resolvedDownloadLane() == .compatibleRemux {
            // #83: preserve the compatible-remux intent (downloadEmby re-probes PlaybackInfo and
            // re-decides remux-vs-transcode, falling back safely if the source is no longer copyable).
            choice = .optimizeCompatible
        } else {
            choice = .original
        }

        Task { [weak self] in
            guard let self else { return }
            // #84: gate on the Emby lane being configured (resolved from its own session),
            // independent of `activeBackend`; an unconfigured lane stays retryable with the
            // accurate not-signed-in reason.
            guard self.appModel.backendSession(for: .emby) != nil else {
                self.lastError[record.ratingKey] = .notAuthenticated
                self.store.setStatus(ratingKey: record.ratingKey, .failed)
                self.refreshRecords()
                return
            }
            guard !self.activeJobs.contains(record.ratingKey) else { return }
            // Keep the failed row visible until `downloadEmby` successfully seeds the replacement.
            // If PlaybackInfo/auth/network preflight fails, its start-failed path can mark this
            // existing row `.failed` instead of making the retry affordance disappear.
            await self.downloadEmby(item, choice: choice,
                                    mediaIndex: mediaIndex,
                                    partIndex: partIndex,
                                    mediaSourceIDOverride: metadata?.mediaSourceID)
            self.refreshRecords()
        }
    }

    /// Resume server-side Plex optimize rows that were persisted while Plex was still rendering.
    ///
    /// During "Preparing on server…" there is intentionally no URLSession task yet, so a relaunch
    /// must not reconcile the row as a dead transfer. Once auth is restored, this method resumes
    /// polling Plex for the optimized Part and starts the static file download when it appears.
    public func resumePendingServerPrepDownloads() {
        // #84: no longer gated on `activeBackend == .plex`. Each candidate is resolved against its
        // OWN backend lane, so a Plex optimize-prep row resumes on relaunch even when the app
        // launched into Jellyfin/Emby — as long as the Plex lane is still configured.
        let candidates = records.filter { record in
            record.status == .queued
                && record.bytes == 0
                && record.progress == 0
                && record.metadata?.optimizeTargetName?.isEmpty == false
                && !activeJobs.contains(record.ratingKey)
        }
        guard !candidates.isEmpty else { return }

        for record in candidates {
            guard let metadata = record.metadata,
                  let targetName = metadata.optimizeTargetName else { continue }
            // Only Plex has a server-side render/poll PREP phase. Jellyfin/Emby optimize is a live
            // transcode stream with no separate queued-prep row, so a JF/Emby row in this state was
            // interrupted mid-transfer and is handled by reconcile (-> .failed -> retryable).
            let kind = metadata.resolvedBackendKind(ratingKey: record.ratingKey)
            guard kind == .plex, let backendSession = appModel.backendSession(for: .plex) else { continue }
            let server = backendSession.baseURL
            let token = backendSession.token
            let ratingKey = record.ratingKey
            activeJobs.insert(ratingKey)
            if let queueTitle = metadata.optimizeQueueTitle {
                activeQueueTitles.insert(queueTitle)
                queueTitleByRatingKey[ratingKey] = queueTitle
            }
            recordDownloadDiagnostic("downloads.optimize_resume", fields: [
                "download_id": .identifier(ratingKey),
                "target": .label(targetName),
                "has_queue_title": .bool(metadata.optimizeQueueTitle != nil),
            ])

            Task { [weak self] in
                await self?.resumePendingOptimizeDownload(record: record,
                                                          metadata: metadata,
                                                          targetName: targetName,
                                                          server: server,
                                                          token: token)
            }
        }
    }

    private func resumePendingOptimizeDownload(record: DownloadRecord,
                                               metadata: OfflineMetadata,
                                               targetName: String,
                                               server: URL,
                                               token: String) async {
        let ratingKey = record.ratingKey
        let identity = appModel.identity
        do {
            try assertCurrentOptimizeAttempt(ratingKey: ratingKey,
                                             metadata: metadata,
                                             targetName: targetName)
            let currentItem = await fetchCurrentMediaItem(ratingKey: ratingKey, server: server,
                                                         token: token, identity: identity)
                ?? metadata.makeMediaItem()
            try assertCurrentOptimizeAttempt(ratingKey: ratingKey,
                                             metadata: metadata,
                                             targetName: targetName)
            let originalPartIDs = Self.resumeOriginalPartIDs(metadata: metadata, item: currentItem)
            guard !originalPartIDs.isEmpty else {
                throw DownloadError.optimizeFailed("No source media parts found while resuming optimize.")
            }
            if let existingPart = Self.existingServerOptimizedDownloadCandidate(
                from: currentItem.media ?? [],
                selectedSourcePartID: metadata.sourcePartID,
                targetName: targetName) {
                clearOptimizeProgress(ratingKey: ratingKey)
                try startOptimizedPartDownload(ratingKey: ratingKey,
                                               title: record.title,
                                               part: existingPart,
                                               metadata: metadata,
                                               server: server,
                                               token: token)
                return
            }
            let backgroundProcessingKey = await bgKeyForPolling(server: server,
                                                                 token: token,
                                                                 identity: identity)
            if let backgroundProcessingKey,
               let queueTitle = metadata.optimizeQueueTitle,
               await optimizerQueueStatus(backgroundProcessingKey: backgroundProcessingKey,
                                          queueTitle: queueTitle,
                                          server: server,
                                          token: token,
                                          identity: identity) == nil {
                recordDownloadDiagnostic("downloads.optimize_resume_recreate", fields: [
                    "download_id": .identifier(ratingKey),
                    "target": .label(targetName),
                ])
                try await triggerOptimize(item: currentItem, targetName: targetName,
                                          queueTitle: queueTitle,
                                          server: server, token: token, identity: identity)
                try assertCurrentOptimizeAttempt(ratingKey: ratingKey,
                                                 metadata: metadata,
                                                 targetName: targetName)
            }
            let part = try await pollForOptimizedPart(ratingKey: ratingKey,
                                                      originalPartIDs: originalPartIDs,
                                                      targetName: targetName,
                                                      backgroundProcessingKey: backgroundProcessingKey,
                                                      queueTitle: metadata.optimizeQueueTitle,
                                                      mediaTitle: record.title,
                                                      server: server,
                                                      token: token,
                                                      identity: identity)
            try assertCurrentOptimizeAttempt(ratingKey: ratingKey,
                                             metadata: metadata,
                                             targetName: targetName)
            try startOptimizedPartDownload(ratingKey: ratingKey,
                                           title: record.title,
                                           part: part,
                                           metadata: metadata,
                                           server: server,
                                           token: token)
        } catch DownloadLifecycleCancellation.staleOptimizeAttempt {
            recordDownloadDiagnostic("downloads.optimize_resume_stale", fields: [
                "download_id": .identifier(ratingKey),
                "target": .label(targetName),
            ])
        } catch let error as DownloadError {
            recordDownloadDiagnostic("downloads.optimize_resume_failed", fields: [
                "download_id": .identifier(ratingKey),
                "target": .label(targetName),
                "error": .label(String(describing: error)),
            ])
            lastError[ratingKey] = error
            store.setStatus(ratingKey: ratingKey, .failed)
            clearOptimizeProgress(ratingKey: ratingKey)
            releaseInFlight(ratingKey: ratingKey)
            refreshRecords()
        } catch is CancellationError {
            clearOptimizeProgress(ratingKey: ratingKey)
            releaseInFlight(ratingKey: ratingKey)
            refreshRecords()
        } catch {
            recordDownloadDiagnostic("downloads.optimize_resume_failed", fields: [
                "download_id": .identifier(ratingKey),
                "target": .label(targetName),
                "error": .error(error),
            ])
            lastError[ratingKey] = .transferFailed(String(describing: error))
            store.setStatus(ratingKey: ratingKey, .failed)
            clearOptimizeProgress(ratingKey: ratingKey)
            releaseInFlight(ratingKey: ratingKey)
            refreshRecords()
        }
    }

    private static func resumeOriginalPartIDs(metadata: OfflineMetadata, item: MediaItem) -> Set<Int> {
        if let baseline = metadata.optimizeBaselinePartIDs, !baseline.isEmpty {
            return Set(baseline)
        }
        if let sourcePartID = metadata.sourcePartID { return [sourcePartID] }
        if let mediaIndex = metadata.mediaIndex,
           let partIndex = metadata.partIndex,
           let id = item.media?[safe: mediaIndex]?.part[safe: partIndex]?.id {
            return [id]
        }
        return Set((item.media ?? []).flatMap { media in
            media.part.filter { isLocallyPlayableOriginal(part: $0) == false }.map(\.id)
        })
    }

    public var totalDownloadedBytes: Int {
        records.reduce(0) { $0 + $1.bytes + $1.sideAssetBytes }
    }

    public var storageLimitBytes: Int {
        PlaybackPreferences.downloadStorageLimitBytes()
    }

    public func storageLimitMessage(adding expectedBytes: Int?) -> String? {
        guard let expectedBytes, expectedBytes > 0 else { return nil }
        let limit = storageLimitBytes
        guard limit > 0 else { return nil }
        let projected = totalDownloadedBytes + expectedBytes
        guard projected > limit else { return nil }
        let incoming = ByteCountFormatter.string(fromByteCount: Int64(expectedBytes), countStyle: .file)
        let used = ByteCountFormatter.string(fromByteCount: Int64(totalDownloadedBytes), countStyle: .file)
        let cap = DownloadStorageLimit.label(bytes: limit)
        return "This download needs about \(incoming), but \(used) is already used and the limit is \(cap). Increase the limit or remove downloads first."
    }

    public func estimatedBytes(for item: MediaItem, choice: DownloadChoice,
                               mediaIndex: Int = 0, partIndex: Int = 0,
                               backend: DownloadBackendKind? = nil) -> Int? {
        // #84: the trickplay surcharge is a Jellyfin-only sidecar. Resolve the backend explicitly
        // when the caller is on a specific lane (the download pipeline always passes it); the
        // default falls back to `activeBackend` for the UI sheet, which is on the active backend.
        let resolvedBackend = backend ?? appModel.activeBackend.downloadBackendKind
        let media = item.media?[safe: mediaIndex]
        let part = media?.part[safe: partIndex]
        let mediaBytes: Int?
        switch choice {
        case .original:
            mediaBytes = part?.size
        case .optimizeCompatible:
            // #83: the video stream is COPIED, so the output is close to the original size (audio may
            // shrink slightly when transcoded to AAC). Use the source size as the storage estimate.
            mediaBytes = part?.size
        case .optimize(let targetName):
            if targetName.localizedCaseInsensitiveCompare("Original Quality") == .orderedSame {
                mediaBytes = part?.size
            } else if let profile = Self.customDownloadProfile(named: targetName) {
                if let kbps = profile.settings.maxVideoBitrateKbps {
                    mediaBytes = Self.estimatedTranscodeBytes(durationMs: item.duration,
                                                             videoBitrateBps: kbps * 1_000)
                } else {
                    mediaBytes = part?.size
                }
            } else {
                mediaBytes = Self.estimatedTranscodeBytes(durationMs: item.duration,
                                                          videoBitrateBps: Self.mediaSettings(forTargetName: targetName).maxVideoBitrateKbps.map { $0 * 1_000 } ?? 8_000_000)
            }
        }
        // Add the thumbnail-cache estimate for every backend that caches one (not just Jellyfin) so
        // the preflight doesn't under-count for Plex/Emby. Text-subtitle sidecars are small and
        // variable, so they're accounted post-hoc from disk via `DownloadRecord.sideAssetBytes`
        // rather than pre-estimated here. Resolve against the job's OWN backend (#84), never the
        // active lane.
        let chapterImageCount = item.chapters?.filter { $0.thumb?.isEmpty == false }.count ?? 0
        let sideAssetBytes = Self.estimatedSideAssetBytes(durationMs: item.duration,
                                                         backend: resolvedBackend,
                                                         chapterImageCount: chapterImageCount)
        guard sideAssetBytes > 0 else { return mediaBytes }
        return (mediaBytes ?? 0) + sideAssetBytes
    }

    /// Rough pre-download estimate of a backend's thumbnail-cache side assets. Plex BIF + Jellyfin
    /// tile sheets are duration-proportional scrub-preview data of comparable magnitude and share
    /// one model. EVERY backend now also caches per-chapter images (#88/#89), bounded by the actual
    /// chapter image count carried by the source item.
    private static func estimatedSideAssetBytes(durationMs: Int?,
                                                backend: DownloadBackendKind,
                                                chapterImageCount: Int) -> Int {
        let chapterImages = estimatedChapterImageBytes(chapterImageCount: chapterImageCount)
        switch backend {
        case .jellyfin, .plex:
            return JellyfinTrickPlayOfflineCachePlanner.estimatedTileBytes(durationMs: durationMs) + chapterImages
        case .emby:
            return chapterImages
        }
    }

    /// Coarse per-chapter-image cache estimate (#88/#89). Chapters are typically a few dozen ~30 KB
    /// 480×270 JPEGs; only chapters with a thumbnail key are fetched.
    private static func estimatedChapterImageBytes(chapterImageCount: Int) -> Int {
        max(0, chapterImageCount) * 30_000
    }

    private func rejectIfOverStorageLimit(ratingKey: String, backend: String, expectedBytes: Int?) -> Bool {
        guard let message = storageLimitMessage(adding: expectedBytes) else { return false }
        recordDownloadDiagnostic("downloads.enqueue_failed", fields: [
            "download_id": .identifier(ratingKey),
            "backend": .label(backend),
            "reason": .label("storage_limit"),
            "expected_bytes": .bytes(expectedBytes),
        ])
        lastError[ratingKey] = .storageLimitExceeded(message)
        refreshRecords()
        return true
    }

    public func deleteCompletedDownloads() {
        for record in records where record.isComplete { delete(ratingKey: record.ratingKey) }
    }

    public func deleteAllDownloads() {
        for record in records { delete(ratingKey: record.ratingKey) }
    }

    /// Delete a download and its backing file.
    public func delete(ratingKey: String) {
        recordDownloadDiagnostic("downloads.cancel_or_delete", fields: [
            "download_id": .identifier(ratingKey),
        ])
        session.cancel(ratingKey: ratingKey)
        store.remove(ratingKey: ratingKey)
        lastError[ratingKey] = nil
        // Releasing the in-flight protection here matters because the row is now GONE, so the
        // terminal-status sweep in `refreshRecords` (which keys off `.complete`/`.failed` rows)
        // can no longer find it to release — without this, a cancelled/deleted job would leak
        // its `activeJobs` slot (blocking re-download) and keep its queue title protected forever.
        releaseInFlight(ratingKey: ratingKey)
        refreshRecords()
    }

    private func recordDownloadDiagnostic(_ name: String,
                                          fields: [String: DiagnosticFieldValue] = [:]) {
        AppDiagnostics.record(.downloads, name, fields: fields)
    }

    private func downloadDiagnosticFields(item: MediaItem,
                                          choice: DownloadChoice,
                                          backend: String,
                                          backendKind: DownloadBackendKind,
                                          mediaIndex: Int,
                                          partIndex: Int) -> [String: DiagnosticFieldValue] {
        let media = item.media.flatMap { mediaItems -> Media? in
            if mediaItems.indices.contains(mediaIndex) { return mediaItems[mediaIndex] }
            return mediaItems.first
        }
        let part = media?.part.indices.contains(partIndex) == true ? media?.part[partIndex] : media?.part.first
        var fields: [String: DiagnosticFieldValue] = [
            "download_id": .identifier(recordKey(for: item, backend: backendKind)),
            "backend": .label(backend),
            "choice": .label(Self.diagnosticChoiceLabel(choice)),
            "item_type": .label(item.type),
            "media_index": .int(mediaIndex),
            "part_index": .int(partIndex),
            "source_container": .label(media?.container ?? part?.container),
            "source_video_codec": .label(media?.videoCodec ?? part?.videoStreams.first?.codec),
            "source_audio_codec": .label(media?.audioCodec ?? part?.audioStreams.first?.codec),
            "source_bitrate_kbps": .int(media?.bitrate ?? 0),
            "expected_bytes": .bytes(part?.size),
        ]
        if let width = media?.width, let height = media?.height {
            fields["source_resolution"] = .label("\(width)x\(height)")
        }
        return fields
    }

    private static func diagnosticChoiceLabel(_ choice: DownloadChoice) -> String {
        switch choice {
        case .original:
            return "original"
        case .optimize(let targetName):
            return "optimize:\(targetName)"
        case .optimizeCompatible:
            return "optimize_compatible"
        }
    }

    /// #83: the persisted lane discriminator for a choice. Stored on the row so a retry/resume after
    /// an app kill preserves the user's intent — original and compatible-remux both lack an
    /// `optimizeTargetName`, so the legacy inference can't tell them apart.
    private static func downloadLane(for choice: DownloadChoice) -> DownloadLane {
        switch choice {
        case .original: return .original
        case .optimize: return .optimize
        case .optimizeCompatible: return .compatibleRemux
        }
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
        // Derive a file-download ETA from the smoothed rate + remaining bytes. Prefer the
        // server-reported Content-Length path (`bytes / progress`). Jellyfin/Emby optimized
        // downloads stream directly from the transcoder and often report no Content-Length,
        // leaving progress at 0 while bytes climb; for those rows, fall back to the same
        // duration×target-bitrate estimate already used for storage preflight. Suppress the
        // same way the optimize ETA does (>12h → drop).
        for record in fresh where record.status == .downloading {
            guard let rate = downloadSpeed[record.ratingKey], rate > 0,
                  record.bytes > 0 else {
                downloadETA[record.ratingKey] = nil
                continue
            }
            let expectedTotal: Double?
            if record.progress > 0 {
                expectedTotal = Double(record.bytes) / record.progress
            } else {
                expectedTotal = Self.estimatedTranscodeBytes(for: record).map(Double.init)
            }
            guard let expectedTotal, expectedTotal > Double(record.bytes) else {
                downloadETA[record.ratingKey] = nil
                continue
            }
            let remainingBytes = expectedTotal - Double(record.bytes)
            let eta = remainingBytes / rate
            downloadETA[record.ratingKey] = (eta.isFinite && eta < 60 * 60 * 12) ? eta : nil
        }
        // Drop samples for rows no longer downloading (complete / failed / removed).
        speedSamples = speedSamples.filter { activeKeys.contains($0.key) }
        downloadSpeed = downloadSpeed.filter { activeKeys.contains($0.key) }
        downloadETA = downloadETA.filter { activeKeys.contains($0.key) }
        records = fresh

        // Release the in-flight protection for any job whose download has reached a terminal
        // state (complete / failed). The optimize-queue title and `activeJobs` slot must stay
        // held for the REAL download lifetime, not just the optimize kickoff — so the actual
        // release happens HERE, driven by the store's terminal status, rather than in a `defer`
        // at the end of `triggerOptimizeAndDownload`/`download` (which fires while the file is
        // still transferring). Once released, `cleanStaleOptimizeJobs` is free to remove the
        // now-abandoned (completed-but-unprotected) marked queue item on the next optimize run.
        // #95: a `.paused` (recoverably-interrupted) row has genuinely stopped transferring, so it
        // releases too — its slot is re-acquired by `retry()` on resume, and releasing also fires
        // any encoder teardown should a transcoded row ever land here.
        let terminalKeys = Set(fresh.filter {
            $0.status == .complete || $0.status == .unverified
                || $0.status == .failed || $0.status == .paused
        }.map(\.ratingKey))
        for key in terminalKeys { releaseInFlight(ratingKey: key) }
    }

    /// Drop the in-flight protection (`activeJobs` slot + protected optimize-queue title) for a
    /// ratingKey once its download is no longer in flight (completed, failed, cancelled, or
    /// deleted). Idempotent. Keeping the queue title protected past this point would block the
    /// clean-slate cleanup from ever removing the now-abandoned completed optimize item.
    private func releaseInFlight(ratingKey: String) {
        activeJobs.remove(ratingKey)
        transcodeSourcedDownloads.remove(ratingKey)
        if let title = queueTitleByRatingKey.removeValue(forKey: ratingKey) {
            activeQueueTitles.remove(title)
        }
        // CLEANUP INVARIANT: a transcoded Emby download leaves a live FFmpeg encoder running on
        // the server until ActiveEncodings is deleted. Fire teardown for the minted PlaySessionId
        // on EVERY terminal transition (complete / failed / cancelled / deleted). Best-effort and
        // idempotent — the session map entry is removed so it never fires twice.
        // Resolve the job's OWN backend lane (never `appModel.activeBackend`): a Jellyfin/Emby
        // download can reach a terminal state while the user has switched to another backend, and
        // the DELETE must hit the server the encoder actually runs on. If that lane is no longer
        // configured (signed out), skip now — the persisted `playSessionID` stays put and the launch
        // sweep retries once the lane returns.
        if let playSessionId = embyPlaySessionByRatingKey.removeValue(forKey: ratingKey),
           let session = appModel.backendSession(for: .emby) {
            recordDownloadDiagnostic("downloads.emby_encoder_teardown", fields: [
                "download_id": .identifier(ratingKey),
            ])
            let service = EmbyBrowseService(appModel: appModel)
            let store = self.store
            Task {
                if await service.stopActiveEncoding(playSessionId: playSessionId, session: session) {
                    store.clearPlaySessionID(ratingKey: ratingKey)
                }
            }
        }
        if let playSessionId = jellyfinPlaySessionByRatingKey.removeValue(forKey: ratingKey),
           let session = appModel.backendSession(for: .jellyfin) {
            recordDownloadDiagnostic("downloads.jellyfin_encoder_teardown", fields: [
                "download_id": .identifier(ratingKey),
            ])
            let service = JellyfinBrowseService(appModel: appModel)
            let store = self.store
            Task {
                if await service.stopActiveEncoding(playSessionId: playSessionId, session: session) {
                    store.clearPlaySessionID(ratingKey: ratingKey)
                }
            }
        }
    }

    // MARK: - D5: offline metadata + poster caching

    /// Build the persisted snapshot of a source `MediaItem` + a human resolution label.
    /// Captures only the fields the offline UI/player/retry actually read. `resolutionLabel`
    /// is descriptive ("1080p"/"4K") for the offline-library caption — it is NOT a transcode
    /// cap (the redesign downloads either the original file or a server-rendered MP4).
    private static func offlineMetadata(from item: MediaItem,
                                        resolutionLabel: String?,
                                        mediaIndex: Int,
                                        partIndex: Int,
                                        optimizeTargetName: String? = nil,
                                        optimizeQueueTitle: String? = nil,
                                        session: BackendSession,
                                        mediaSourceID: String? = nil,
                                        downloadLane: DownloadLane? = nil) -> OfflineMetadata {
        let sourcePartID = item.media?[safe: mediaIndex]?.part[safe: partIndex]?.id
        return OfflineMetadata(ratingKey: item.ratingKey,
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
                               grandparentTitle: item.grandparentTitle,
                               grandparentRatingKey: item.grandparentRatingKey,
                               grandparentThumb: item.grandparentThumb,
                               parentTitle: item.parentTitle,
                               parentRatingKey: item.parentRatingKey,
                               parentThumb: item.parentThumb,
                               parentIndex: item.parentIndex,
                               index: item.index,
                               thumb: item.thumb,
                               art: item.art,
                               chapters: item.chapters?.map(OfflineChapter.init),
                               markers: item.markers?.map(OfflineMarker.init),
                               resolutionLabel: resolutionLabel,
                               librarySectionID: item.librarySectionID,
                               librarySectionKey: item.librarySectionKey,
                               mediaIndex: mediaIndex,
                               partIndex: partIndex,
                               sourcePartID: sourcePartID,
                               optimizeTargetName: optimizeTargetName,
                               optimizeQueueTitle: optimizeQueueTitle,
                               posterRelativePath: nil,
                               // #84: per-job backend context captured at ENQUEUE from the job's own
                               // `BackendSession`, so resume/retry/cleanup never read `appModel.active*`.
                               backendKind: session.kind,
                               backendBaseURLString: session.baseURL.absoluteString,
                               backendServerID: session.serverID,
                               backendUserID: session.userID,
                               mediaSourceID: mediaSourceID,
                               playSessionID: nil,
                               downloadLane: downloadLane)
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

    /// Resolution label to STORE/DISPLAY on the offline row.
    ///
    /// For a `.optimize` choice whose target encodes a resolution (the custom "720p …"/"1080p …"
    /// profiles, or the built-in server targets), this is the TARGET resolution — NOT the source.
    /// Showing the source was misleading: a "720p 4 Mbps" job against a 4K source displayed "4K",
    /// implying a 4K file the user is not getting. For DIRECT (`.original`) downloads and the
    /// "Original"/"Original Quality" optimize target (no downscale), the source resolution IS
    /// correct, so we keep it. Falls back to the source whenever the target's resolution can't be
    /// derived — we never fabricate a resolution.
    static func displayResolutionLabel(choice: DownloadChoice, chosenMedia: Media?) -> String? {
        let sourceLabel = resolutionLabel(for: chosenMedia)
        guard case .optimize(let targetName) = choice else { return sourceLabel }
        // Resolve the target's "WIDTHxHEIGHT" from the custom profile first, then the built-in
        // server target settings. A nil videoResolution means "no downscale" (Original) → source.
        let videoResolution = customDownloadProfile(named: targetName)?.settings.videoResolution
            ?? mediaSettings(forTargetName: targetName).videoResolution
        guard let videoResolution else { return sourceLabel }
        return resolutionLabel(forVideoResolution: videoResolution) ?? sourceLabel
    }

    /// Map an optimize target's `"WIDTHxHEIGHT"` videoResolution (e.g. "1280x720") to the same
    /// human bucket label as `resolutionLabel(for:)` ("4K"/"1080p"/"720p"/"480p"/"W×H"). Accepts
    /// the lowercase `x` separator the MediaSettings strings use. Returns nil for an unparseable
    /// value so the caller can fall back to the source label.
    static func resolutionLabel(forVideoResolution raw: String) -> String? {
        let parts = raw.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
        switch (w, h) {
        case let (_, h) where h >= 2160: return "4K"
        case let (_, h) where h >= 1080: return "1080p"
        case let (_, h) where h >= 720:  return "720p"
        case let (_, h) where h >= 480:  return "480p"
        default:                         return "\(w)×\(h)"
        }
    }

    /// Whether the original source part is a good local-file download target. PMS may be able
    /// to stream/copy an MKV through HLS, but AVFoundation often cannot open that same MKV as a
    /// downloaded local file. Keep direct-original conservative and route other containers
    /// through the optimizer presets.
    static func isLocallyPlayableOriginal(part: Part?) -> Bool {
        OfflineDownloadDecision.isLocallyPlayableOriginal(part: part)
    }

    /// Artwork reference to cache for the Offline tab's small portrait tile. For episodes,
    /// prefer the show poster, then season poster, before the episode still/backdrop; forcing a
    /// landscape still into the portrait row tile was visibly distorted during b8 live testing.
    private static func offlinePosterRef(for item: MediaItem) -> String? {
        if item.kind == .episode {
            return item.grandparentThumb ?? item.parentThumb ?? item.thumb ?? item.art
        }
        return item.thumb ?? item.art
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
        Task { [weak self] in
            // Fetch + atomic disk write happen OFF the main actor (mirrors
            // PlaybackController.fetchArtworkData); only the store mutation hops back on.
            guard await Self.fetchAndWritePoster(from: url, to: posterURL) else { return }
            await MainActor.run {
                store.setPosterRelativePath(ratingKey: ratingKey,
                                            posterURL.lastPathComponent)
                self?.refreshRecords()
            }
        }
    }

    /// Best-effort poster fetch + atomic write, fully off the main actor. Returns `true`
    /// only when a non-empty poster landed on disk at `destination`; any failure (HTTP
    /// error, empty body, write failure) returns `false` and is never surfaced — a missing
    /// poster is never a download error.
    private nonisolated static func fetchAndWritePoster(from url: URL, to destination: URL) async -> Bool {
        await fetchAndWritePoster(request: URLRequest(url: url), to: destination)
    }

    /// Same best-effort fetch + atomic write as the URL variant, but driven by a
    /// pre-resolved `URLRequest`. The MediaBrowser (Jellyfin/Emby) image endpoints are
    /// NOT satisfied by Plex-style token-in-query — they need the `Authorization` header
    /// (Emby also `userId`) that `*.authenticatedRequest(...)` attaches — so those lanes
    /// must come through here with an authenticated request.
    private nonisolated static func fetchAndWritePoster(request: URLRequest, to destination: URL) async -> Bool {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) { return false }
            guard !data.isEmpty else { return false }
            try data.write(to: destination, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Best-effort cache of a Jellyfin item's poster so the offline library shows artwork
    /// without the server (#102). Mirrors `cacheJellyfinTrickPlay` (authenticated,
    /// off-main-actor side-asset cache). Resolves the item's inline synthetic Primary ref
    /// (`item.thumb`), falling back to the Backdrop ref (`item.art`); a fetch failure
    /// leaves the row poster-less and never fails the download.
    private func cacheJellyfinPoster(ratingKey: String, item: MediaItem, server: URL,
                                     token: String, identity: JellyfinClientIdentity) {
        let posterURL = store.posterDestinationURL(ratingKey: ratingKey)
        let store = self.store
        let primaryRef = Self.offlinePosterRef(for: item)
        let backdropRef = item.art
        Task { [weak self] in
            let request = (try? JellyfinLibrary.posterRequest(syntheticRef: primaryRef, server: server,
                                                              token: token, identity: identity))
                ?? (try? JellyfinLibrary.posterRequest(syntheticRef: backdropRef, server: server,
                                                       token: token, identity: identity))
            guard let request,
                  await Self.fetchAndWritePoster(request: request, to: posterURL) else { return }
            await MainActor.run {
                store.setPosterRelativePath(ratingKey: ratingKey, posterURL.lastPathComponent)
                self?.refreshRecords()
            }
        }
    }

    /// Best-effort cache of an Emby item's poster (#102). Same shape as
    /// `cacheJellyfinPoster`, but the Emby image endpoint additionally needs `userId` on
    /// the authenticated request.
    private func cacheEmbyPoster(ratingKey: String, item: MediaItem, server: URL,
                                 token: String, identity: EmbyClientIdentity, userId: String) {
        let posterURL = store.posterDestinationURL(ratingKey: ratingKey)
        let store = self.store
        let primaryRef = Self.offlinePosterRef(for: item)
        let backdropRef = item.art
        Task { [weak self] in
            let request = (try? EmbyLibrary.posterRequest(syntheticRef: primaryRef, server: server,
                                                          token: token, identity: identity, userId: userId))
                ?? (try? EmbyLibrary.posterRequest(syntheticRef: backdropRef, server: server,
                                                   token: token, identity: identity, userId: userId))
            guard let request,
                  await Self.fetchAndWritePoster(request: request, to: posterURL) else { return }
            await MainActor.run {
                store.setPosterRelativePath(ratingKey: ratingKey, posterURL.lastPathComponent)
                self?.refreshRecords()
            }
        }
    }

    /// Build the `/photo/:/transcode` URL for an image path, mirroring `PosterImage`.
    /// Requests a poster-sized image so the cached file stays small.
    private static func posterTranscodeURL(thumb: String, server: URL, token: String) -> URL? {
        guard var comps = URLComponents(url: server.appendingPathComponent("/photo/:/transcode"),
                                        resolvingAgainstBaseURL: false) else { return nil }
        PlexURLQueryEncoder.replaceQueryItems([
            .init(name: "url", value: thumb),
            .init(name: "width", value: "400"),
            .init(name: "height", value: "600"),
            .init(name: "minSize", value: "1"),
            .init(name: "upscale", value: "1"),
            .init(name: "X-Plex-Token", value: token),
        ], in: &comps)
        return comps.url
    }

    private func cachePlexTextSubtitles(ratingKey: String, part: Part, server: URL, token: String) {
        let streams = part.subtitleStreams.enumerated().filter { OfflineTextSubtitleCachePlanner.isCompatibleTextSubtitle($0.element) }
        guard !streams.isEmpty else { return }
        let store = self.store
        Task { [weak self] in
            var tracks: [OfflineTextSubtitleTrack] = []
            for (fallbackIndex, stream) in streams {
                guard let key = stream.key, let url = Self.plexSubtitleURL(server: server, token: token, key: key) else { continue }
                let ext = OfflineTextSubtitleCachePlanner.fileExtension(for: stream)
                let destination = store.textSubtitleDestinationURL(ratingKey: ratingKey, streamID: stream.id, ext: ext)
                guard await Self.fetchAndWriteTextSubtitle(request: URLRequest(url: url), to: destination) else { continue }
                if let track = OfflineTextSubtitleCachePlanner.track(for: stream,
                                                                     relativePath: destination.lastPathComponent,
                                                                     fallbackIndex: fallbackIndex) {
                    tracks.append(track)
                }
            }
            guard !tracks.isEmpty else { return }
            await MainActor.run {
                store.setOfflineTextSubtitles(ratingKey: ratingKey, tracks)
                self?.refreshRecords()
            }
        }
    }

    private func cacheJellyfinTextSubtitles(ratingKey: String,
                                           itemId: String,
                                           mediaSourceId: String?,
                                           part: Part?,
                                           server: URL,
                                           token: String,
                                           identity: JellyfinClientIdentity) {
        guard let mediaSourceId, !mediaSourceId.isEmpty, let part else { return }
        let streams = part.subtitleStreams.enumerated().filter { OfflineTextSubtitleCachePlanner.isCompatibleTextSubtitle($0.element) }
        guard !streams.isEmpty else { return }
        let store = self.store
        Task { [weak self] in
            var tracks: [OfflineTextSubtitleTrack] = []
            for (fallbackIndex, stream) in streams {
                let ext = OfflineTextSubtitleCachePlanner.fileExtension(for: stream)
                let destination = store.textSubtitleDestinationURL(ratingKey: ratingKey, streamID: stream.id, ext: ext)
                let streamIndex = stream.index ?? stream.id
                guard let request = try? JellyfinLibrary.textSubtitleRequest(server: server,
                                                                             token: token,
                                                                             identity: identity,
                                                                             itemId: itemId,
                                                                             mediaSourceId: mediaSourceId,
                                                                             streamIndex: streamIndex,
                                                                             format: ext),
                      await Self.fetchAndWriteTextSubtitle(request: request, to: destination) else { continue }
                if let track = OfflineTextSubtitleCachePlanner.track(for: stream,
                                                                     relativePath: destination.lastPathComponent,
                                                                     fallbackIndex: fallbackIndex) {
                    tracks.append(track)
                }
            }
            guard !tracks.isEmpty else { return }
            await MainActor.run {
                store.setOfflineTextSubtitles(ratingKey: ratingKey, tracks)
                self?.refreshRecords()
            }
        }
    }

    private nonisolated static func plexSubtitleURL(server: URL, token: String, key: String) -> URL? {
        let raw = key.hasPrefix("/") ? key : "/\(key)"
        guard var comps = URLComponents(url: server.appendingPathComponent(raw), resolvingAgainstBaseURL: false) else { return nil }
        // Drop any token the key already carried, then append the token through the project's strict
        // encoder so it is percent-encoded consistently with every other Plex URL builder.
        if var items = comps.queryItems {
            items.removeAll { $0.name.caseInsensitiveCompare("X-Plex-Token") == .orderedSame }
            comps.queryItems = items.isEmpty ? nil : items
        }
        PlexURLQueryEncoder.appendQueryItems([.init(name: "X-Plex-Token", value: token)], to: &comps)
        return comps.url
    }

    private nonisolated static func fetchAndWriteTextSubtitle(request: URLRequest, to destination: URL) async -> Bool {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return false }
            guard let text = String(data: data, encoding: .utf8),
                  !OfflineTextSubtitleParser.parse(text).isEmpty else { return false }
            try data.write(to: destination, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Download + cache Plex's BIF trick-play index for the selected source Part so the
    /// local custom player can keep showing scrub previews fully offline (#78). Best-effort:
    /// a missing/invalid BIF never fails the media download. The request carries the token in
    /// query, so do not log the URL or surfaced error.
    private func cachePlexBIF(ratingKey: String, item: MediaItem, mediaIndex: Int,
                              server: URL, token: String) {
        guard let part = Self.selectedPlexBIFPart(from: item, mediaIndex: mediaIndex) else { return }
        let destination = store.plexBIFDestinationURL(ratingKey: ratingKey)
        let request = TrickPlayRequest.plexBIFIndex(server: server,
                                                    token: token,
                                                    identity: appModel.identity,
                                                    partID: part.id,
                                                    quality: "sd")
        let client = appModel.client
        let store = self.store
        Task { [weak self] in
            do {
                let data = try await client.send(request)
                guard !data.isEmpty, (try? BIFParser.parse(data)) != nil else { return }
                try data.write(to: destination, options: .atomic)
                await MainActor.run {
                    store.setPlexBIFRelativePath(ratingKey: ratingKey, destination.lastPathComponent)
                    self?.refreshRecords()
                }
            } catch {
                // Expected for items/servers without BIFs, auth churn, or cache races.
                // Keep silent and never log token-bearing URLs.
            }
        }
    }

    private static func selectedPlexBIFPart(from item: MediaItem, mediaIndex: Int) -> Part? {
        guard let media = item.media, !media.isEmpty else { return nil }
        let selectedMedia = media.indices.contains(mediaIndex) ? media[mediaIndex] : media[0]
        guard let part = selectedMedia.part.first, part.hasStandardDefinitionBIFIndex else { return nil }
        return part
    }

    /// Download + cache each chapter's image at download time so the offline Chapters menu rail
    /// shows real per-chapter thumbnails (#88) and the Emby offline scrubber has a coarse preview
    /// source (#89). One shared index-keyed cache feeds both consumers.
    ///
    /// Best-effort, exactly like `cachePlexBIF`/`cacheJellyfinTrickPlay`: a failed image is simply
    /// dropped (that chapter shows the online-equivalent placeholder offline), and the whole cache
    /// failing never fails the media download. Each backend builds the same image URL its online
    /// chapter resolver uses (Plex `/photo/:/transcode`; Jellyfin/Emby chapter-image endpoint). The
    /// requests carry tokens (Plex in query, JF/Emby in headers) so URLs are never logged.
    private func cacheChapterImages(ratingKey: String, item: MediaItem, backend: DownloadBackendKind,
                                    server: URL, token: String) {
        let chapters = item.chapters ?? []
        guard !chapters.isEmpty else { return }
        // Build (chapter index, request) for every chapter that carries an image key. The index is
        // the chapter's position in `chapters` — the same enumeration the Chapters rail and the
        // offline scrub provider use, so it is the stable join key offline.
        let identity = appModel.identity
        var requests: [(index: Int, request: URLRequest)] = []
        for (index, chapter) in chapters.enumerated() {
            guard let thumb = chapter.thumb, !thumb.isEmpty else { continue }
            switch backend {
            case .plex:
                guard let url = Self.chapterImageTranscodeURL(thumb: thumb, server: server, token: token) else { continue }
                requests.append((index, URLRequest(url: url)))
            case .jellyfin:
                guard let parsed = Self.parsedSyntheticChapterImageKey(thumb, scheme: "jellyfin"),
                      let url = try? JellyfinLibrary.chapterImageURL(server: server, itemId: parsed.itemId,
                                                                    chapterIndex: parsed.index, tag: parsed.tag,
                                                                    width: 480, height: 270) else { continue }
                var req = JellyfinLibrary.authenticatedRequest(url: url, token: token, identity: identity.jellyfin)
                req.setValue("*/*", forHTTPHeaderField: "Accept")
                requests.append((index, req))
            case .emby:
                guard let parsed = Self.parsedSyntheticChapterImageKey(thumb, scheme: "emby"),
                      let url = try? EmbyLibrary.chapterImageURL(server: server, itemId: parsed.itemId,
                                                               chapterIndex: parsed.index, tag: parsed.tag,
                                                               width: 480, height: 270) else { continue }
                let userId = appModel.backendSession(for: .emby)?.userID
                var req = EmbyLibrary.authenticatedRequest(url: url, token: token, identity: identity.emby, userId: userId)
                req.setValue("*/*", forHTTPHeaderField: "Accept")
                requests.append((index, req))
            }
        }
        guard !requests.isEmpty else { return }
        let store = self.store
        Task { [weak self] in
            // Fetch concurrently — chapters are independent and a long film has many. A failed/empty
            // image is dropped; only chapters that landed on disk go into the map.
            let fetched: [(index: Int, data: Data)] = await withTaskGroup(of: (Int, Data)?.self) { group in
                for entry in requests {
                    group.addTask {
                        guard let (data, response) = try? await URLSession.shared.data(for: entry.request),
                              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                              !data.isEmpty else { return nil }
                        return (entry.index, data)
                    }
                }
                var out: [(index: Int, data: Data)] = []
                for await result in group { if let result { out.append(result) } }
                return out
            }
            guard !fetched.isEmpty else { return }
            var relativesByIndex: [Int: String] = [:]
            for entry in fetched {
                let destination = store.chapterImageDestinationURL(ratingKey: ratingKey, index: entry.index)
                guard (try? entry.data.write(to: destination, options: .atomic)) != nil else { continue }
                relativesByIndex[entry.index] = destination.lastPathComponent
            }
            guard !relativesByIndex.isEmpty else { return }
            await MainActor.run {
                store.setChapterImageRelativePaths(ratingKey: ratingKey, relativesByIndex)
                self?.refreshRecords()
            }
        }
    }

    /// `/photo/:/transcode` URL for a Plex chapter `thumb` key, 16:9 landscape — the same shape the
    /// online `PlaybackController.chapterThumbnailURL` builds for the Chapters rail.
    private static func chapterImageTranscodeURL(thumb: String, server: URL, token: String) -> URL? {
        guard var comps = URLComponents(url: server.appendingPathComponent("/photo/:/transcode"),
                                        resolvingAgainstBaseURL: false) else { return nil }
        PlexURLQueryEncoder.replaceQueryItems([
            .init(name: "url", value: thumb),
            .init(name: "width", value: "480"),
            .init(name: "height", value: "270"),
            .init(name: "minSize", value: "1"),
            .init(name: "upscale", value: "1"),
            .init(name: "X-Plex-Token", value: token),
        ], in: &comps)
        return comps.url
    }

    /// Parse a synthetic `<scheme>://item/{itemId}/Chapter/{index}?tag=` chapter-image key (Jellyfin
    /// or Emby). Mirrors the private parsers in `PlaybackController` / `EmbyChapterTrickPlayThumbnailProvider`.
    static func parsedSyntheticChapterImageKey(_ imagePath: String, scheme: String) -> (itemId: String, index: Int, tag: String?)? {
        guard let url = URL(string: imagePath), url.scheme == scheme, url.host == "item" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[1] == "Chapter", let index = Int(parts[2]) else { return nil }
        let tag = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "tag" }?.value
        return (parts[0], index, tag)
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
                                            session: BackendSession) async {
        let ratingKey = item.ratingKey
        // #84: the whole optimize/poll/download chain runs off the captured Plex session — the
        // server/token come from it, not from any `appModel.active*` re-read.
        let server = session.baseURL
        let token = session.token
        let identity = appModel.identity
        let queueTitle = metadata.optimizeQueueTitle
            ?? "\(item.title) [VisionPlay \(UUID().uuidString.prefix(8))]"
        var optimizeMetadata = metadata
        optimizeMetadata.optimizeTargetName = targetName
        optimizeMetadata.optimizeQueueTitle = queueTitle
        recordDownloadDiagnostic("downloads.optimize_start", fields: [
            "download_id": .identifier(ratingKey),
            "target": .label(targetName),
        ])
        // Seed a 0% record so the UI shows the job immediately while we set up the optimize.
        store.upsert(DownloadRecord(ratingKey: ratingKey, title: item.title,
                                    localURL: store.destinationURL(ratingKey: ratingKey, ext: "mp4"),
                                    bytes: 0, progress: 0, metadata: optimizeMetadata))
        refreshRecords()

        do {
            // Protect this job's queue item from the stale-job cleanup (and any concurrent
            // download's), so cleanup only ever removes abandoned items. CRITICAL: do NOT
            // release this with a `defer` — that fired when this function returned, i.e. right
            // after `session.start` KICKS OFF the URLSession transfer (it does not await the
            // file finishing), leaving the rendered Part unprotected mid-download so a
            // concurrent job's `cleanStaleOptimizeJobs` could delete the very Part being
            // downloaded. Protection is instead released terminally (on `.complete`/`.failed`)
            // via `releaseInFlight`, driven from `refreshRecords`, plus the explicit
            // error-path release below.
            activeQueueTitles.insert(queueTitle)
            queueTitleByRatingKey[ratingKey] = queueTitle
            let sourceItem = await fetchCurrentMediaItem(ratingKey: ratingKey, server: server,
                                                         token: token, identity: identity) ?? item
            try assertCurrentOptimizeAttempt(ratingKey: ratingKey,
                                             metadata: optimizeMetadata,
                                             targetName: targetName)
            let sourceMediaIndex = metadata.mediaIndex ?? 0
            let sourcePartIndex = metadata.partIndex ?? 0
            let refreshedResolutionLabel = Self.displayResolutionLabel(
                choice: .optimize(targetName: targetName),
                chosenMedia: sourceItem.media?[safe: sourceMediaIndex])
            let existingMetadata = records.first { $0.ratingKey == ratingKey }?.metadata
            optimizeMetadata = Self.offlineMetadata(from: sourceItem,
                                                    resolutionLabel: refreshedResolutionLabel,
                                                    mediaIndex: sourceMediaIndex,
                                                    partIndex: sourcePartIndex,
                                                    optimizeTargetName: targetName,
                                                    optimizeQueueTitle: queueTitle,
                                                    session: session)
            optimizeMetadata.posterRelativePath = existingMetadata?.posterRelativePath
            optimizeMetadata.plexBIFRelativePath = existingMetadata?.plexBIFRelativePath
            // #88: carry forward already-cached chapter images so an optimize re-fetch doesn't drop
            // the offline Chapters rail thumbnails.
            optimizeMetadata.chapterImageRelativePaths = existingMetadata?.chapterImageRelativePaths
            optimizeMetadata.optimizeBaselinePartIDs = (sourceItem.media ?? item.media ?? [])
                .flatMap { $0.part.map(\.id) }
            store.upsert(DownloadRecord(ratingKey: ratingKey, title: sourceItem.title,
                                        localURL: store.destinationURL(ratingKey: ratingKey, ext: "mp4"),
                                        bytes: 0, progress: 0, metadata: optimizeMetadata))
            refreshRecords()
            cacheChapterImages(ratingKey: ratingKey, item: sourceItem, backend: .plex,
                               server: server, token: token)
            if let sourcePart = sourceItem.media?[safe: sourceMediaIndex]?.part[safe: sourcePartIndex] {
                cachePlexTextSubtitles(ratingKey: ratingKey, part: sourcePart,
                                       server: server, token: token)
            }
            let originalPartIDs = Set(optimizeMetadata.optimizeBaselinePartIDs ?? [])
            guard !originalPartIDs.isEmpty else {
                throw DownloadError.optimizeFailed("No source media parts found before optimize.")
            }
            // Truth-first resume/retry: before creating another Plex conversion, reuse any
            // already-rendered compatible optimized version that Plex exposes on metadata. This
            // prevents a relaunch/retry from deleting a completed server render and starting a
            // multi-hour transcode over from 0%.
            let selectedSourcePartID = optimizeMetadata.sourcePartID
            if let existingPart = Self.existingServerOptimizedDownloadCandidate(
                from: sourceItem.media ?? item.media ?? [],
                selectedSourcePartID: selectedSourcePartID,
                targetName: targetName) {
                clearOptimizeProgress(ratingKey: ratingKey)
                try startOptimizedPartDownload(ratingKey: ratingKey,
                                               title: item.title,
                                               part: existingPart,
                                               metadata: optimizeMetadata,
                                               server: server,
                                               token: token)
                return
            }
            try assertCurrentOptimizeAttempt(ratingKey: ratingKey,
                                             metadata: optimizeMetadata,
                                             targetName: targetName)
            try await triggerOptimize(item: sourceItem, targetName: targetName,
                                      queueTitle: queueTitle,
                                      server: server, token: token, identity: identity)
            try assertCurrentOptimizeAttempt(ratingKey: ratingKey,
                                             metadata: optimizeMetadata,
                                             targetName: targetName)
            let part = try await pollForOptimizedPart(ratingKey: ratingKey,
                                                      originalPartIDs: originalPartIDs,
                                                      targetName: targetName,
                                                      backgroundProcessingKey: await bgKeyForPolling(server: server,
                                                                                               token: token,
                                                                                               identity: identity),
                                                      queueTitle: queueTitle,
                                                      mediaTitle: item.title,
                                                      server: server, token: token,
                                                      identity: identity)
            try assertCurrentOptimizeAttempt(ratingKey: ratingKey,
                                             metadata: optimizeMetadata,
                                             targetName: targetName)
            try startOptimizedPartDownload(ratingKey: ratingKey,
                                           title: item.title,
                                           part: part,
                                           metadata: optimizeMetadata,
                                           server: server,
                                           token: token)
        } catch DownloadLifecycleCancellation.staleOptimizeAttempt {
            recordDownloadDiagnostic("downloads.optimize_stale", fields: [
                "download_id": .identifier(ratingKey),
                "target": .label(targetName),
            ])
        } catch let error as DownloadError {
            recordDownloadDiagnostic("downloads.optimize_failed", fields: [
                "download_id": .identifier(ratingKey),
                "target": .label(targetName),
                "error": .label(String(describing: error)),
            ])
            lastError[ratingKey] = error
            store.setStatus(ratingKey: ratingKey, .failed)
            clearOptimizeProgress(ratingKey: ratingKey)
            refreshRecords()
        } catch is CancellationError {
            releaseInFlight(ratingKey: ratingKey)
            clearOptimizeProgress(ratingKey: ratingKey)
            refreshRecords()
        } catch {
            recordDownloadDiagnostic("downloads.optimize_failed", fields: [
                "download_id": .identifier(ratingKey),
                "target": .label(targetName),
                "error": .error(error),
            ])
            lastError[ratingKey] = .transferFailed(String(describing: error))
            store.setStatus(ratingKey: ratingKey, .failed)
            clearOptimizeProgress(ratingKey: ratingKey)
            refreshRecords()
        }
    }

    private func startOptimizedPartDownload(ratingKey: String,
                                            title: String,
                                            part: Part,
                                            metadata: OfflineMetadata,
                                            server: URL,
                                            token: String) throws {
        let targetName = metadata.optimizeTargetName ?? "unknown"
        let ext = part.container ?? (part.file as NSString?)?.pathExtension ?? "mp4"
        let destination = store.destinationURL(ratingKey: ratingKey,
                                               ext: ext.isEmpty ? "mp4" : ext)
        if rejectIfOverStorageLimit(ratingKey: ratingKey, backend: "Plex", expectedBytes: part.size) {
            store.setStatus(ratingKey: ratingKey, .failed)
            releaseInFlight(ratingKey: ratingKey)
            throw lastError[ratingKey] ?? DownloadError.storageLimitExceeded("Storage limit exceeded.")
        }
        try assertCurrentOptimizeAttempt(ratingKey: ratingKey,
                                         metadata: metadata,
                                         targetName: targetName)
        var downloadMetadata = metadata
        // If the #88 chapter-image cache landed while the Plex optimize job was rendering, preserve
        // it across this final "start the rendered Part" upsert instead of racing it back to nil.
        if downloadMetadata.chapterImageRelativePaths == nil {
            downloadMetadata.chapterImageRelativePaths = store.records.first { $0.ratingKey == ratingKey }?
                .metadata?.chapterImageRelativePaths
        }
        store.upsert(DownloadRecord(ratingKey: ratingKey, title: title,
                                    localURL: destination, bytes: 0, progress: 0,
                                    metadata: downloadMetadata))
        refreshRecords()
        try assertCurrentOptimizeAttempt(ratingKey: ratingKey,
                                         metadata: downloadMetadata,
                                         targetName: targetName)
        let url = OptimizeRequest.downloadURL(server: server, token: token, partKey: part.key)
        recordDownloadDiagnostic("downloads.start", fields: [
            "download_id": .identifier(ratingKey),
            "backend": .label("Plex"),
            "choice": .label("optimize"),
            "target": .label(targetName),
            "url_shape": .urlShape(url),
            "expected_bytes": .bytes(part.size),
        ])
        // Plex often exposes downloadable text subtitle streams only on the rendered optimized
        // Part, not on the original source Part (where subtitle `key` can be nil). Cache from the
        // exact Part we are downloading so optimized offline playback has the same sidecars.
        cachePlexTextSubtitles(ratingKey: ratingKey, part: part, server: server, token: token)
        // The rendered Part is a static file by this point (the poll waited for it to
        // appear), so a Plex optimize download is usually network-bound — but the server
        // can still be finalizing/serving it as it writes, so mark it transcode-sourced and
        // let `isDownloadTranscodeLimited` decide from the live rate.
        transcodeSourcedDownloads.insert(ratingKey)
        try session.start(ratingKey: ratingKey, from: url, to: destination,
                          expectedBytes: part.size)
        refreshRecords()
    }

    /// Ensure an async Plex optimize poller still owns the visible row before it mutates the store
    /// or starts a file transfer.
    ///
    /// This closes the delete/retry race where an old poller survives row deletion, later observes a
    /// completed Plex Part, and overwrites a newer retry's row or downloads to the same destination.
    /// The queue title is the per-attempt identity; the target check catches stale rows from older
    /// builds that may not have a queue-title mapping.
    private func assertCurrentOptimizeAttempt(ratingKey: String,
                                              metadata: OfflineMetadata,
                                              targetName: String) throws {
        guard activeJobs.contains(ratingKey) else {
            throw DownloadLifecycleCancellation.staleOptimizeAttempt
        }
        if let queueTitle = metadata.optimizeQueueTitle {
            guard queueTitleByRatingKey[ratingKey] == queueTitle else {
                throw DownloadLifecycleCancellation.staleOptimizeAttempt
            }
        }
        guard let current = store.records.first(where: { $0.ratingKey == ratingKey }),
              current.status == .queued,
              current.bytes == 0,
              current.progress == 0 else {
            throw DownloadLifecycleCancellation.staleOptimizeAttempt
        }
        let currentMetadata = current.metadata
        if let queueTitle = metadata.optimizeQueueTitle,
           currentMetadata?.optimizeQueueTitle != queueTitle {
            throw DownloadLifecycleCancellation.staleOptimizeAttempt
        }
        guard currentMetadata?.optimizeTargetName == targetName else {
            throw DownloadLifecycleCancellation.staleOptimizeAttempt
        }
    }

    /// Steps 1–3 of the optimize contract: fetch the background-processing key, resolve the
    /// target tag id from the server's targets, POST the optimize job. Isolated so the live
    /// (server-specific) path is the only thing Phase 0 needs to confirm.
    private func triggerOptimize(item: MediaItem, targetName: String,
                                 queueTitle: String,
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

        // Clear our own abandoned optimize jobs first so this new one isn't stuck waiting
        // behind a backlog of dead items in the server's background-processing queue.
        await cleanStaleOptimizeJobs(backgroundProcessingKey: bgKey, server: server,
                                     token: token, identity: identity)

        // The real candidate fix: if the server's background conversion queue is idle-PAUSED,
        // queued optimize jobs never run while the user is connected (the queue sits, no
        // `media.download` activity ever appears). Mirror python-plexapi `conversions(pause=False)`
        // and clear it — but only when a read confirms it IS paused (conditional write, so we
        // never needlessly mutate a server that's already fine).
        await unpauseBackgroundQueueIfNeeded(server: server, token: token, identity: identity)

        // 2. Resolve built-in PMS target tags from the server. Custom iPad-style
        //    quality rows intentionally leave targetTagID empty and instead send
        //    Item[Device][profile] + Item[MediaSettings], matching python-plexapi.
        let custom = Self.customDownloadProfile(named: targetName)
        var targetTagID: Int? = custom == nil ? Self.conventionalTagID(forName: targetName) : nil
        if custom == nil,
           let targets = try? await appModel.client.send(
            OptimizeRequest.mediaProcessingTargetsRequest(server: server, token: token, identity: identity),
            as: MediaProcessingTargets.self),
           let resolved = targets.tagID(forName: targetName) {
            targetTagID = resolved
        }

        let source = await optimizerSource(for: item, server: server, token: token, identity: identity)

        // 3. PUT the optimize job to the background-processing playlist.
        let settings = custom?.settings ?? Self.mediaSettings(forTargetName: targetName)
        let create = OptimizeRequest.createOnPlaylist(
            server: server, token: token, identity: identity,
            backgroundProcessingKey: bgKey, ratingKey: item.ratingKey,
            sourceURI: source?.uri, locationID: source?.locationID ?? -1,
            title: queueTitle, targetTagID: targetTagID,
            targetName: custom == nil ? "" : "Custom: \(custom!.deviceProfile)",
            deviceProfile: custom?.deviceProfile, mediaSettings: settings)
        do {
            try await appModel.client.send(create)
        } catch {
            throw DownloadError.optimizeFailed("optimize POST: \(String(describing: error))")
        }

        // 4. Optionally jump this just-enqueued conversion ahead of the PENDING items (but never
        //    the one currently transcoding). Opt-in via Settings; best-effort — never fails the
        //    download. The optimize POST above must have run first so our item already exists in
        //    the conversion queue when we re-fetch it.
        await prioritizeConversionIfEnabled(ratingKey: item.ratingKey, server: server,
                                            token: token, identity: identity)
    }

    /// When the "Prioritize quick downloads" setting is on, move OUR just-enqueued conversion to
    /// immediately AFTER the active conversion (so it is next up), never displacing the in-flight
    /// transcode — mirroring python-plexapi `Conversion.move(after:)`. If no conversion is active,
    /// move to the front (`after=-1`). Strictly scoped: only acts on the conversion whose
    /// `ratingKey` matches the item we just created; unrelated jobs are never reordered. Any
    /// failure (setting off, perms, shape mismatch, item not found) degrades to a no-op and is
    /// recorded via `downloads.conversion_prioritized`. NEVER throws.
    private func prioritizeConversionIfEnabled(ratingKey: String, server: URL, token: String,
                                               identity: ClientIdentity) async {
        guard PlaybackPreferences.prioritizeQuickDownloads() else {
            recordDownloadDiagnostic("downloads.conversion_prioritized", fields: [
                "download_id": .identifier(ratingKey),
                "moved": .bool(false),
                "reason": .label("disabled"),
            ])
            return
        }

        // Re-fetch the ordered conversion queue so our newly-created item is present.
        guard let queue = try? await appModel.client.send(
            BackgroundQueueRequest.conversionQueueRequest(server: server, token: token, identity: identity),
            as: ConversionQueue.self) else {
            recordDownloadDiagnostic("downloads.conversion_prioritized", fields: [
                "download_id": .identifier(ratingKey),
                "moved": .bool(false),
                "reason": .label("queue_fetch_failed"),
            ])
            return
        }

        let active = queue.activeItem
        let wasActivePresent = active != nil

        // Locate OUR item by ratingKey. Gate hard: only ever reorder this one.
        guard let mine = queue.items.first(where: { $0.ratingKey == ratingKey }),
              let mineItemID = mine.playQueueItemID else {
            recordDownloadDiagnostic("downloads.conversion_prioritized", fields: [
                "download_id": .identifier(ratingKey),
                "moved": .bool(false),
                "was_active_present": .bool(wasActivePresent),
                "queue_count": .int(queue.count),
                "reason": .label("item_not_found"),
            ])
            return
        }

        // If our item IS the active conversion, there is nothing to do — never preempt/restart it.
        if active?.playQueueItemID == mineItemID {
            recordDownloadDiagnostic("downloads.conversion_prioritized", fields: [
                "download_id": .identifier(ratingKey),
                "moved": .bool(false),
                "was_active_present": .bool(wasActivePresent),
                "queue_count": .int(queue.count),
                "reason": .label("already_active"),
            ])
            return
        }

        // Move target: immediately after the active conversion (next up, no preemption); if no
        // active conversion, move to absolute front via python-plexapi's `-1` marker.
        let afterItemID = active?.playQueueItemID ?? "-1"
        let ok = (try? await appModel.client.send(
            BackgroundQueueRequest.moveConversionRequest(
                server: server, token: token, identity: identity,
                playQueueItemID: mineItemID, afterItemID: afterItemID))) != nil

        recordDownloadDiagnostic("downloads.conversion_prioritized", fields: [
            "download_id": .identifier(ratingKey),
            "moved": .bool(ok),
            "was_active_present": .bool(wasActivePresent),
            "queue_count": .int(queue.count),
            "reason": .label(ok ? "moved" : "move_put_failed"),
        ])
    }

    /// Delete this client's abandoned, non-completed items from the server's type-42
    /// background-processing queue. Completed optimize items are server-side artifacts that may
    /// contain the rendered file a relaunched app still needs to discover/download; deleting the
    /// queue item deletes that optimized version in Plex. Scoped hard: only items carrying our
    /// `[VisionPlay …]` title marker, not currently in-flight (`activeQueueTitles`), and not in a
    /// completed state are removed — never another client's jobs or completed server renders.
    private func cleanStaleOptimizeJobs(backgroundProcessingKey: String, server: URL,
                                        token: String, identity: ClientIdentity) async {
        let trimmed = backgroundProcessingKey.hasPrefix("/")
            ? String(backgroundProcessingKey.dropFirst()) : backgroundProcessingKey
        let listReq = PlexRequest(url: server.appendingPathComponent(trimmed), method: "GET",
                                  queryItems: [],
                                  headers: PlexHeaders.standard(identity: identity, token: token))
        guard let queue = try? await appModel.client.send(listReq, as: BackgroundProcessingItems.self)
        else {
            recordDownloadDiagnostic("downloads.optimize_queue_cleaned", fields: [
                "queue_items": .int(-1), "fetch": .string("failed"),
            ])
            return
        }
        let marker = "[VisionPlay "
        let persistedProtectedTitles = Set(records.compactMap { record -> String? in
            guard record.status != .complete else { return nil }
            return record.metadata?.optimizeQueueTitle
        })
        let protectedTitles = activeQueueTitles.union(persistedProtectedTitles)
        // Server-truth policy: remove only our marked pending/failed clutter. NEVER delete a
        // completed optimized item here — Plex removes the rendered server-side version when the
        // type-42 item is deleted, and a completed item may be the exact Part a relaunched app
        // still needs to discover and download. Also protect persisted queue titles so relaunches
        // do not briefly expose still-valid server work before activeQueueTitles is rebuilt.
        let stale = queue.staleItemIDs(marker: marker, protectedTitles: protectedTitles)
        var removed = 0
        for id in stale {
            let del = OptimizeRequest.removeBackgroundItem(server: server, token: token,
                                                           identity: identity,
                                                           backgroundProcessingKey: backgroundProcessingKey,
                                                           itemID: id)
            if (try? await appModel.client.send(del)) != nil { removed += 1 }
        }
        // Always record — including the zero-match case — so we can tell "server didn't keep our
        // marker" (marked_count 0 while pending_count high) from "matched but all protected".
        recordDownloadDiagnostic("downloads.optimize_queue_cleaned", fields: [
            "queue_items": .int(queue.items.count),
            "marked_count": .int(queue.markedCount(marker: marker)),
            "pending_count": .int(queue.pendingCount),
            "protected": .int(protectedTitles.count),
            "stale_found": .int(stale.count),
            "removed": .int(removed),
        ])
    }

    /// If the server's background conversion queue is idle-paused, clear it so queued optimize
    /// jobs actually run. Conditional write: reads `BackgroundQueueIdlePaused` via `GET /:/prefs`
    /// first and only issues the `PUT /:/prefs?BackgroundQueueIdlePaused=0` when it is truthy —
    /// an unknown/absent setting or an already-unpaused queue is left untouched. Mirrors
    /// python-plexapi `PlexServer.conversions(pause=False)`. Emits `downloads.background_queue_unpaused`
    /// only when we actually attempted the toggle (so the human can see was_paused + whether the
    /// PUT succeeded). Best-effort: a failed read or PUT never fails the download.
    private func unpauseBackgroundQueueIfNeeded(server: URL, token: String,
                                                identity: ClientIdentity) async {
        guard let prefs = try? await appModel.client.send(
            BackgroundQueueRequest.prefsRequest(server: server, token: token, identity: identity),
            as: ServerPrefs.self),
              prefs.backgroundQueueIdlePaused == true else {
            return
        }
        let ok = (try? await appModel.client.send(
            BackgroundQueueRequest.setBackgroundQueueIdlePausedRequest(
                server: server, token: token, identity: identity, paused: false))) != nil
        recordDownloadDiagnostic("downloads.background_queue_unpaused", fields: [
            "was_paused": .bool(true),
            "ok": .bool(ok),
        ])
    }

    private struct LibrarySectionsResponse: Decodable {
        struct Container: Decodable {
            let directory: [Directory]
            enum CodingKeys: String, CodingKey { case directory = "Directory" }
        }
        struct Directory: Decodable {
            struct Location: Decodable { let id: Int; let path: String }
            let key: String
            let uuid: String?
            let location: [Location]
            enum CodingKeys: String, CodingKey {
                case key
                case uuid
                case location = "Location"
            }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                key = try container.decode(String.self, forKey: .key)
                uuid = try container.decodeIfPresent(String.self, forKey: .uuid)
                location = try container.decodeIfPresent([Location].self, forKey: .location) ?? []
            }
        }
        let mediaContainer: Container
        enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
    }

    private struct OptimizerSource {
        let uri: String
        let locationID: Int
    }

    private func optimizerSource(for item: MediaItem, server: URL, token: String,
                                 identity: ClientIdentity) async -> OptimizerSource? {
        let sectionID = item.librarySectionID.map(String.init)
            ?? item.librarySectionKey?.split(separator: "/").last.map(String.init)
        guard let sectionID else { return nil }
        let request = PlexRequest(url: server.appendingPathComponent("library/sections"),
                                  method: "GET", queryItems: [],
                                  headers: PlexHeaders.standard(identity: identity, token: token))
        guard let response = try? await appModel.client.send(request, as: LibrarySectionsResponse.self),
              let section = response.mediaContainer.directory.first(where: { $0.key == sectionID }),
              let uuid = section.uuid,
              let metadataKey = item.key ?? Optional("/library/metadata/\(item.ratingKey)")
        else { return nil }

        let sourceFiles = (item.media ?? []).flatMap { $0.part.compactMap(\.file) }
        let sourceLocationIDs = Set(section.location.compactMap { location -> Int? in
            sourceFiles.contains { Self.filePath($0, isUnder: location.path) } ? location.id : nil
        })
        // PlexAPI's `locationID = -1` means "beside the original file". If the library has
        // an extra location (for example a writable optimized-version mount), prefer that so
        // read-only media libraries do not force optimizer failures.
        let alternateLocationID = section.location.first { !sourceLocationIDs.contains($0.id) }?.id

        return OptimizerSource(uri: "library://\(uuid)/item/\(metadataKey.urlQueryEscapedForPlexPath)",
                               locationID: alternateLocationID ?? -1)
    }

    private static func filePath(_ file: String, isUnder directory: String) -> Bool {
        let normalizedDirectory = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        return file == normalizedDirectory || file.hasPrefix(normalizedDirectory + "/")
    }

    private struct CustomDownloadProfile {
        let name: String
        let deviceProfile: String
        let settings: OptimizeRequest.MediaSettings
    }

    private static let compatibleOriginalQualityName = "Original video quality"

    private static let customDownloadProfiles: [CustomDownloadProfile] = [
        .init(name: compatibleOriginalQualityName, deviceProfile: "Universal TV",
              settings: .init(videoQuality: 100, maxVideoBitrateKbps: nil, videoResolution: nil)),
        .init(name: "1080p 20 Mbps", deviceProfile: "Universal TV",
              settings: .init(videoQuality: 100, maxVideoBitrateKbps: 20_000, videoResolution: "1920x1080")),
        .init(name: "1080p 12 Mbps", deviceProfile: "Universal TV",
              settings: .init(videoQuality: 90, maxVideoBitrateKbps: 12_000, videoResolution: "1920x1080")),
        .init(name: "1080p 10 Mbps", deviceProfile: "Universal TV",
              settings: .init(videoQuality: 75, maxVideoBitrateKbps: 10_000, videoResolution: "1920x1080")),
        .init(name: "1080p 8 Mbps", deviceProfile: "Universal TV",
              settings: .init(videoQuality: 60, maxVideoBitrateKbps: 8_000, videoResolution: "1920x1080")),
        .init(name: "720p 4 Mbps", deviceProfile: "Universal TV",
              settings: .init(videoQuality: 100, maxVideoBitrateKbps: 4_000, videoResolution: "1280x720")),
        .init(name: "720p 3 Mbps", deviceProfile: "Universal TV",
              settings: .init(videoQuality: 75, maxVideoBitrateKbps: 3_000, videoResolution: "1280x720")),
        .init(name: "720p 2 Mbps", deviceProfile: "Universal TV",
              settings: .init(videoQuality: 60, maxVideoBitrateKbps: 2_000, videoResolution: "1280x720")),
        .init(name: "480p 1.5 Mbps", deviceProfile: "Universal Mobile",
              settings: .init(videoQuality: 60, maxVideoBitrateKbps: 1_500, videoResolution: "720x480")),
    ]

    private static var customDownloadProfileNames: [String] {
        customDownloadProfiles.map(\.name)
    }

    private static func customDownloadProfile(named name: String) -> CustomDownloadProfile? {
        customDownloadProfiles.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    private struct JellyfinTranscodeProfile {
        let videoBitrateBps: Int
        let maxWidth: Int?
        let maxHeight: Int?
    }

    private static let jellyfinDefaultDownloadPreset = "1080p 8 Mbps"

    private static func jellyfinDownloadPreset(named name: String) -> String {
        // Jellyfin does not have Plex's server-side "Original video quality" optimize queue.
        // If a row was written with that global/default label, retry via the explicit bitrate
        // ladder so Jellyfin still produces an MP4-compatible transcoded download.
        customDownloadProfile(named: name)?.settings.maxVideoBitrateKbps == nil
            ? jellyfinDefaultDownloadPreset
            : name
    }

    private static func jellyfinTranscodeProfile(named name: String) -> JellyfinTranscodeProfile {
        let settings = customDownloadProfile(named: jellyfinDownloadPreset(named: name))?.settings
        let bitrateKbps = settings?.maxVideoBitrateKbps ?? 8_000
        let resolution = settings?.videoResolution
        let dimensions = resolution?
            .lowercased()
            .split(separator: "x")
            .compactMap { Int($0) }
        let width = dimensions?.indices.contains(0) == true ? dimensions?[0] : nil
        let height = dimensions?.indices.contains(1) == true ? dimensions?[1] : nil
        return JellyfinTranscodeProfile(videoBitrateBps: bitrateKbps * 1_000,
                                        maxWidth: width,
                                        maxHeight: height)
    }

    private static func estimatedTranscodeBytes(durationMs: Int?, videoBitrateBps: Int) -> Int? {
        guard let durationMs, durationMs > 0 else { return nil }
        // Add a modest audio/container allowance to the selected video bitrate so the storage
        // preflight is conservative without requiring a Content-Length from Jellyfin's stream.
        let totalBitrate = videoBitrateBps + 256_000
        return Int((Double(durationMs) / 1000.0) * Double(totalBitrate) / 8.0)
    }

    private static func estimatedTranscodeBytes(for record: DownloadRecord) -> Int? {
        guard let targetName = record.metadata?.optimizeTargetName, !targetName.isEmpty else {
            return nil
        }
        let profile = jellyfinTranscodeProfile(named: targetName)
        return estimatedTranscodeBytes(durationMs: record.metadata?.duration,
                                       videoBitrateBps: profile.videoBitrateBps)
    }

    /// Unified download fraction for a row's bar + caption (#97), so Plex/Jellyfin/Emby
    /// all present progress the same way. Returns the EXACT `Content-Length` fraction when
    /// the server reported a size (`record.progress`), otherwise an ESTIMATED fraction
    /// (`bytes` / duration×bitrate estimate) for transcoder-streamed JF/Emby rows that ship
    /// no `Content-Length`. `nil` when neither is available (no bytes yet, or no estimate) →
    /// the caller keeps today's spinner. The estimated fraction is clamped strictly below
    /// 1.0 so the bar never reads 100% before the real `.complete` status flips the row.
    /// The selection is keyed on `record.progress`, not the backend kind, so it survives a
    /// relaunch (the in-memory `transcodeSourcedDownloads` set does not).
    public func displayFraction(for record: DownloadRecord) -> DownloadProgressDisplay.Fraction? {
        DownloadProgressDisplay.fraction(progress: record.progress,
                                         bytes: record.bytes,
                                         estimatedTotalBytes: Self.estimatedTranscodeBytes(for: record))
    }

    private static func jellyfinMediaSourceID(media: Media?, part: Part?) -> String? {
        let keys = [part?.key] + (media?.part.map(\.key) ?? [])
        for key in keys.compactMap({ $0 }) {
            guard let marker = key.range(of: "/media/") else { continue }
            let source = String(key[marker.upperBound...])
            if !source.isEmpty { return source }
        }
        return nil
    }

    private static func jellyfinTranscodedDownloadRequest(_ server: URL,
                                                          _ token: String,
                                                          _ identity: JellyfinClientIdentity,
                                                          _ itemId: String,
                                                          _ mediaSourceId: String?,
                                                          _ playSessionId: String,
                                                          _ profile: JellyfinTranscodeProfile) -> URLRequest {
        let base = server.appendingPathComponent("/Videos/\(itemId)/stream.mp4")
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        var query = [
            URLQueryItem(name: "static", value: "false"),
            URLQueryItem(name: "container", value: "mp4"),
            URLQueryItem(name: "videoCodec", value: "h264"),
            URLQueryItem(name: "audioCodec", value: "aac"),
            URLQueryItem(name: "videoBitRate", value: String(profile.videoBitrateBps)),
            URLQueryItem(name: "audioBitRate", value: "192000"),
            URLQueryItem(name: "maxAudioChannels", value: "6"),
            URLQueryItem(name: "allowVideoStreamCopy", value: "false"),
            URLQueryItem(name: "allowAudioStreamCopy", value: "false"),
            URLQueryItem(name: "enableAutoStreamCopy", value: "false"),
            URLQueryItem(name: "breakOnNonKeyFrames", value: "false"),
            URLQueryItem(name: "deviceId", value: identity.deviceId),
            URLQueryItem(name: "playSessionId", value: playSessionId),
        ]
        if let mediaSourceId, !mediaSourceId.isEmpty {
            query.append(URLQueryItem(name: "mediaSourceId", value: mediaSourceId))
        }
        if let maxWidth = profile.maxWidth {
            query.append(URLQueryItem(name: "maxWidth", value: String(maxWidth)))
        }
        if let maxHeight = profile.maxHeight {
            query.append(URLQueryItem(name: "maxHeight", value: String(maxHeight)))
        }
        comps.queryItems = query
        let url = comps.url!
        var request = URLRequest(url: url)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(JellyfinAuth.authorizationHeader(identity: identity, token: token),
                         forHTTPHeaderField: "Authorization")
        return request
    }

    private static func dedup(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in names {
            let key = name.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(name)
        }
        return result
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
                                      originalPartIDs: Set<Int>,
                                      targetName: String,
                                      backgroundProcessingKey: String?,
                                      queueTitle: String?,
                                      mediaTitle: String,
                                      server: URL,
                                      token: String,
                                      identity: ClientIdentity) async throws -> Part {
        while !Task.isCancelled {
            if let metadata = await fetchCurrentMediaItem(ratingKey: ratingKey, server: server,
                                                          token: token, identity: identity) {
                if let newPart = Self.optimizedDownloadCandidate(from: metadata.media ?? [],
                                                                 baselinePartIDs: originalPartIDs,
                                                                 targetName: targetName) {
                    clearOptimizeProgress(ratingKey: ratingKey)
                    return newPart
                }
            }
            // Surface server-side optimize/transcode progress for the "Preparing on
            // server…" caption. Best-effort: failures or no-match leave the existing
            // behavior untouched.
            // Do not use the historical sole-optimizer fallback here. Live PMS can run several
            // background transcodes while `/activities` exposes only one `media.download` entry,
            // so "one VisionPlay active job" is not enough to prove that lone activity belongs
            // to us. `recordServerQueueProbe` below reads `/status/sessions/background`, whose
            // per-job `ratingKey` is the safer progress source under concurrency.
            await pollOptimizeActivity(ratingKey: ratingKey, mediaTitle: mediaTitle,
                                       allowSoleFallback: false,
                                       server: server, token: token, identity: identity)
            // Disambiguation probe: distinguish "completed-item clutter" (inert) from a genuinely
            // stalled or idle-paused server conversion queue. Privacy-safe COUNTS + short state
            // tokens only — never a media title/path/URL.
            await recordServerQueueProbe(ratingKey: ratingKey, server: server,
                                         token: token, identity: identity)
            if let backgroundProcessingKey,
               let queueTitle,
               let status = await optimizerQueueStatus(backgroundProcessingKey: backgroundProcessingKey,
                                                       queueTitle: queueTitle, server: server,
                                                       token: token, identity: identity),
               status.isFailed {
                downloadLog.error("optimizer-failed failed=\(status.itemsFailedCount ?? -1, privacy: .public) successful=\(status.itemsSuccessfulCount ?? -1, privacy: .public)")
                recordDownloadDiagnostic("downloads.optimize_status_failed", fields: [
                    "download_id": .identifier(ratingKey),
                    "failed_count": .int(status.itemsFailedCount ?? -1),
                    "successful_count": .int(status.itemsSuccessfulCount ?? -1),
                ])
                throw DownloadError.optimizeFailed("Plex server could not create an optimized version; optimized-version storage may be read-only.")
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(optimizePollInterval * 1_000_000_000))
            } catch {
                throw error
            }
        }
        throw CancellationError()
    }

    /// Pick only a NEW Plex server-optimized output that the local/offline player can open.
    /// Multi-version libraries can have several pre-existing compatible source parts; excluding
    /// just the selected source part is not enough, and any concurrent/manual version creation for
    /// the same item should not win unless it has Plex's optimized-version path shape.
    private static func optimizedDownloadCandidate(from media: [Media],
                                                   baselinePartIDs: Set<Int>,
                                                   targetName: String) -> Part? {
        for mediaItem in media where serverOptimizedMedia(mediaItem, matchesTargetName: targetName) {
            if let part = mediaItem.part.first(where: { part in
                !baselinePartIDs.contains(part.id)
                    && isServerOptimizedPart(part)
                    && isLocallyPlayableOriginal(part: part)
            }) {
                return part
            }
        }
        return nil
    }

    /// Reuse a compatible optimized Part that Plex already exposes on item metadata. Plex stores
    /// server-rendered optimized versions under a `Plex Versions` path; deleting the matching
    /// type-42 queue item deletes this Part, so retries/relaunches must look for it before
    /// creating or cleaning conversions.
    private static func existingServerOptimizedDownloadCandidate(from media: [Media],
                                                                 selectedSourcePartID: Int?,
                                                                 targetName: String) -> Part? {
        for mediaItem in media where serverOptimizedMedia(mediaItem, matchesTargetName: targetName) {
            if let part = mediaItem.part.first(where: { part in
                part.id != selectedSourcePartID
                    && isServerOptimizedPart(part)
                    && isLocallyPlayableOriginal(part: part)
            }) {
                return part
            }
        }
        return nil
    }

    /// Decide whether an already-rendered Plex Version is the same effective target the current
    /// attempt requested. Plex metadata does not preserve our queue title on the rendered Part, so
    /// match on the durable media attributes PMS exposes: resolution and approximate bitrate. This
    /// prevents a retry from asking for 1080p 8 Mbps and silently reusing an old 720p 3 Mbps file.
    private static func serverOptimizedMedia(_ media: Media, matchesTargetName targetName: String) -> Bool {
        let settings = customDownloadProfile(named: targetName)?.settings ?? mediaSettings(forTargetName: targetName)
        if let targetResolution = settings.videoResolution,
           let targetHeight = resolutionHeight(targetResolution),
           let actualHeight = media.height {
            // Encoders round the rendered height up to a macroblock multiple, so a 1080 target can
            // legitimately come back as 1088. Allow a small tolerance — the next ladder rung down
            // (e.g. 720) is hundreds of px away, so this never blurs adjacent resolution steps.
            if abs(actualHeight - targetHeight) > 16 { return false }
        }
        if let targetKbps = settings.maxVideoBitrateKbps,
           let actualKbps = media.bitrate {
            // `media.bitrate` is the whole-container rate (video + audio), while `targetKbps` caps
            // VIDEO only. Allow the video variance (×1.10) plus a realistic ceiling for a rendered
            // surround track (~640 kbps AC3/AAC 5.1 + margin) so a valid optimized Part isn't judged
            // a mismatch and needlessly re-rendered. The slop stays well under the gap between bitrate
            // ladder rungs, so an 8 vs 10 Mbps render is still distinguished.
            let allowedKbps = Int(Double(targetKbps) * 1.10) + 768
            if actualKbps > allowedKbps { return false }
        }
        return true
    }

    private static func resolutionHeight(_ value: String) -> Int? {
        value.split(separator: "x").last.flatMap { Int($0) }
    }

    private static func isServerOptimizedPart(_ part: Part) -> Bool {
        guard let file = part.file?.lowercased() else { return false }
        return file.contains("/plex versions/")
    }

    private func fetchCurrentMediaItem(ratingKey: String, server: URL, token: String,
                                       identity: ClientIdentity) async -> MediaItem? {
        // Use the full detail shape, not the lean optimize status shape, so any offline
        // snapshot refreshed from this item carries chapters and part/stream metadata.
        // Optimized downloads need that source metadata just as much as original downloads:
        // the optimized MP4 itself is downloaded later, but chapters and external text
        // subtitles come from the source item.
        let req = PlexRequest(url: server.appendingPathComponent("/library/metadata/\(ratingKey)"),
                              method: "GET",
                              queryItems: [
                                  .init(name: "includeChapters", value: "1"),
                                  .init(name: "includeMarkers", value: "1"),
                                  .init(name: "includeExtras", value: "1"),
                              ],
                              headers: PlexHeaders.standard(identity: identity, token: token))
        return (try? await appModel.client.send(req, as: MetadataResponse.self))?
            .mediaContainer.metadata.first
    }


    private func bgKeyForPolling(server: URL, token: String, identity: ClientIdentity) async -> String? {
        guard let pl = try? await appModel.client.send(
            OptimizeRequest.backgroundProcessingRequest(server: server, token: token, identity: identity),
            as: BackgroundProcessingPlaylist.self)
        else { return nil }
        return pl.key
    }

    private struct OptimizerQueueResponse: Decodable {
        struct Container: Decodable {
            let item: [Item]
            enum CodingKeys: String, CodingKey { case item = "Item" }
        }
        struct Item: Decodable {
            let title: String?
            let status: Status?
            enum CodingKeys: String, CodingKey { case title; case status = "Status" }
        }
        struct Status: Decodable {
            let itemsSuccessfulCount: Int?
            let itemsFailedCount: Int?
            let state: String?
            var isFailed: Bool {
                (itemsFailedCount ?? 0) > 0 && (itemsSuccessfulCount ?? 0) == 0
                    && state?.lowercased() == "complete"
            }
        }
        let mediaContainer: Container
        enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
    }

    private func optimizerQueueStatus(backgroundProcessingKey: String, queueTitle: String,
                                      server: URL, token: String,
                                      identity: ClientIdentity) async -> OptimizerQueueResponse.Status? {
        let trimmed = backgroundProcessingKey.hasPrefix("/")
            ? String(backgroundProcessingKey.dropFirst()) : backgroundProcessingKey
        let req = PlexRequest(url: server.appendingPathComponent(trimmed), method: "GET",
                              queryItems: [],
                              headers: PlexHeaders.standard(identity: identity, token: token))
        guard let response = try? await appModel.client.send(req, as: OptimizerQueueResponse.self)
        else { return nil }
        return response.mediaContainer.item.last(where: { $0.title == queueTitle })?.status
    }

    // MARK: - Server-side optimize progress (GET /activities)

    /// Fetch `GET /activities`, correlate the matching optimize activity to this job, and
    /// publish `optimizeProgress`/`optimizeETA`/`optimizeState`. Best-effort: a request
    /// failure or absent match leaves the current state untouched (graceful fallback).
    ///
    /// PRIVACY: media titles in `Activity.title`/`subtitle` are matched in memory ONLY and
    /// never logged. We emit a single redaction-safe shape probe per poll (structural facts
    /// + numeric progress only) so the real PMS shape can be confirmed from logs.
    private func pollOptimizeActivity(ratingKey: String, mediaTitle: String,
                                      allowSoleFallback: Bool,
                                      server: URL, token: String,
                                      identity: ClientIdentity) async {
        let req = ActivitiesRequest.list(server: server, token: token, identity: identity)
        guard let activities = try? await appModel.client.send(req, as: Activities.self) else {
            return
        }

        // PROBE: redaction-safe shape of the raw /activities decode for live validation.
        // `probeShape` emits ONLY counts / field-presence flags / dotted types / numeric
        // progress — never a title/subtitle VALUE. The "types" string is a list of dotted
        // activity types (e.g. "media.optimize,library.update.section"), which are
        // server-vocabulary identifiers, not media titles, and pass through unredacted.
        let shape = activities.probeShape(ratingKey: ratingKey, title: mediaTitle,
                                          allowSoleFallback: allowSoleFallback)
        var probeFields: [String: DiagnosticFieldValue] = [
            "download_id": .identifier(ratingKey),
            "activity_count": .int(Int(shape["activity_count"] ?? "0") ?? 0),
            "optimize_count": .int(Int(shape["optimize_count"] ?? "0") ?? 0),
            "matched": .label(shape["matched"]),
            // Dotted activity-type vocabulary (NOT media titles); aids shape confirmation.
            "activity_types": .label(shape["types"]),
        ]
        // NOTE: the diagnostic redactor auto-omits any field whose KEY contains "title".
        // The presence flags below carry only "1"/"0"/"nil" (never a title value), so we
        // map the title/subtitle presence flags to redactor-safe key names to keep the
        // boolean visible — the VALUE is structural, not a media title.
        let probeKeyRemap: [String: String] = [
            "match_has_title": "match_has_name",
            "match_has_subtitle": "match_has_subname",
        ]
        for k in ["match_progress", "match_has_uuid", "match_has_context_ratingkey",
                  "match_has_metadata_id", "match_correlation_equal",
                  "match_has_title", "match_has_subtitle", "match_cancellable"] {
            if let v = shape[k] { probeFields[probeKeyRemap[k] ?? k] = .label(v) }
        }
        recordDownloadDiagnostic("downloads.optimize_activity_probe", fields: probeFields)

        guard let activity = activities.optimizeActivity(ratingKey: ratingKey,
                                                         title: mediaTitle,
                                                         allowSoleFallback: allowSoleFallback) else {
            return
        }

        // progress is 0…100, or -1 indeterminate. -1 / missing → "queued" (job seen but no
        // measurable progress yet); a real percent → "transcoding".
        guard let pct = activity.progress, pct >= 0 else {
            optimizeState[ratingKey] = "queued"
            optimizeProgress[ratingKey] = nil
            optimizeETA[ratingKey] = nil
            return
        }
        let p = min(1.0, Double(pct) / 100.0)
        optimizeProgress[ratingKey] = p
        optimizeState[ratingKey] = "transcoding"
        updateOptimizeETA(ratingKey: ratingKey, progress: p)
    }

    /// Fold the moving optimize percent into an EMA (same 0.75/0.25 weights as the transfer
    /// speed EMA) to derive a smooth `~N min left`. Suppress the ETA when the instantaneous
    /// rate is non-positive (progress stalled or went backwards) or implausibly large.
    private func updateOptimizeETA(ratingKey: String, progress p: Double) {
        let now = Date()
        guard let prev = optimizeProgressSamples[ratingKey] else {
            optimizeProgressSamples[ratingKey] = (p, now)
            return
        }
        let dt = now.timeIntervalSince(prev.time)
        let dp = p - prev.p
        // Resample on a ≥1s window for a less-noisy instantaneous rate; require forward
        // progress. (Matches the transfer-speed EMA cadence in refreshRecords.)
        guard dt >= 1.0, dp > 0 else {
            if p >= 1.0 { optimizeETA[ratingKey] = 0 }
            return
        }
        let instantaneous = dp / dt   // fraction per second
        let smoothed = optimizeRate[ratingKey].map { 0.75 * $0 + 0.25 * instantaneous }
            ?? instantaneous
        optimizeRate[ratingKey] = smoothed
        optimizeProgressSamples[ratingKey] = (p, now)
        if smoothed > 0 {
            let eta = (1.0 - p) / smoothed
            // Only surface a plausible estimate (< 12h); otherwise suppress (too noisy).
            optimizeETA[ratingKey] = (eta.isFinite && eta < 60 * 60 * 12) ? eta : nil
        }
    }

    /// PREFERRED transcode-ETA estimate from the server-reported realtime `speed` multiplier.
    ///
    /// `remaining_video_seconds = duration_sec × (1 − progress/100)`, then
    /// `transcode_remaining = remaining_video_seconds / speed`. The media duration (ms) is read
    /// from the persisted offline-metadata snapshot for this ratingKey. Returns `nil` (so the
    /// caller leaves the EMA estimate in place) when the duration is unknown, the inputs are
    /// degenerate, or the estimate is implausible (>12h) — same suppression as `updateOptimizeETA`.
    private func speedBasedTranscodeETA(ratingKey: String, progressPercent pct: Int,
                                        speed: Double) -> TimeInterval? {
        guard speed > 0, pct >= 0, pct < 100,
              // Prefer the already-published snapshot, but fall back to the store in case this
              // probe races a refresh during optimize resume/retry. Without a duration the
              // server-speed estimate cannot be converted into wall-clock seconds; the progress
              // EMA below still covers subsequent polls.
              let durationMs = (records.first(where: { $0.ratingKey == ratingKey })
                    ?? store.records.first(where: { $0.ratingKey == ratingKey }))?
                    .metadata?.duration,
              durationMs > 0 else { return nil }
        let durationSec = Double(durationMs) / 1000.0
        let remainingVideoSeconds = durationSec * (1.0 - Double(pct) / 100.0)
        let eta = remainingVideoSeconds / speed
        guard eta.isFinite, eta > 0, eta < 60 * 60 * 12 else { return nil }
        return eta
    }

    /// Drop all server-optimize progress state for a ratingKey (part found / job ended).
    /// Mirrors the `downloadSpeed` prune idiom in `refreshRecords`.
    private func clearOptimizeProgress(ratingKey: String) {
        optimizeProgress[ratingKey] = nil
        optimizeETA[ratingKey] = nil
        optimizeState[ratingKey] = nil
        optimizeProgressSamples[ratingKey] = nil
        optimizeRate[ratingKey] = nil
    }

    // MARK: - Server conversion queue probe

    /// Disambiguation probe (server-side conversion-queue health). Emits `downloads.optimize_server_probe`
    /// with PRIVACY-SAFE counts / numeric progress / short state tokens only — NEVER a media
    /// title/path/URL. Lets us tell completed-`Optimized`-item clutter (inert) apart from a
    /// stalled or idle-paused background queue, by reading the SEPARATE conversion machinery the
    /// type-42 registry doesn't expose. Each of the three GETs is independent + best-effort: a
    /// failure on one omits only its fields and never fails the download.
    private func recordServerQueueProbe(ratingKey: String, server: URL, token: String,
                                        identity: ClientIdentity) async {
        var fields: [String: DiagnosticFieldValue] = ["download_id": .identifier(ratingKey)]

        // 1. /playQueues/1 → ordered conversion queue (Conversion). This tells us whether this
        //    row is still in the optimize queue, but it is NOT a complete active-job signal:
        //    live PMS can run several optimizations concurrently while playQueues/1 exposes only
        //    one selected item. Use /status/sessions/background below for per-job attribution.
        var thisIsQueuedConversion = false
        if let queue = try? await appModel.client.send(
            BackgroundQueueRequest.conversionQueueRequest(server: server, token: token, identity: identity),
            as: ConversionQueue.self) {
            fields["conversion_count"] = .int(queue.count)
            fields["active_conversion_present"] = .bool(queue.hasActiveConversion)
            let inQueue = queue.items.contains { $0.ratingKey == ratingKey }
            fields["conversion_contains_rk"] = .bool(inQueue)
            if let selected = queue.activeItem?.ratingKey {
                // Historical/diagnostic only: this may be ONE selected conversion, not the full
                // set of active conversions. Do not use it to decide this row is inactive.
                fields["selected_rk_match"] = .bool(selected == ratingKey)
            }
            thisIsQueuedConversion = inQueue
        }

        // 2. /status/sessions/background → running/paused optimization jobs (TranscodeJob).
        if let jobs = try? await appModel.client.send(
            BackgroundQueueRequest.transcodeJobsRequest(server: server, token: token, identity: identity),
            as: BackgroundTranscodeJobs.self) {
            fields["bg_job_count"] = .int(jobs.jobs.count)
            let matchingJob = jobs.job(ratingKey: ratingKey)
            let attributedJob: BackgroundTranscodeJobs.Job? = matchingJob
                // Legacy fallback for older PMS shapes without per-job ratingKey: if there is
                // exactly one background job and exactly one active VisionPlay download, it is
                // unambiguous. Never use first-job fallback when PMS reports multiple jobs.
                ?? ((jobs.jobs.count == 1 && activeJobs.count == 1) ? jobs.jobs.first : nil)
            let isActiveConversion = attributedJob != nil
            if matchingJob != nil { fields["bg_rk_match"] = .bool(true) }
            if let p = attributedJob?.progress { fields["bg_progress"] = .int(p) }
            // `state` is a queued/running/paused-style vocabulary token, not a media title.
            if let s = attributedJob?.state { fields["bg_state"] = .label(s) }
            // Server-reported realtime multiplier (a number, never a title) — preferred ETA source.
            if let speed = attributedJob?.speed { fields["bg_speed"] = .double(speed) }
            fields["bg_attributed"] = .label(isActiveConversion ? "active"
                                             : (thisIsQueuedConversion ? "queued" : "none"))

            if isActiveConversion {
                // FROZEN-% FIX: the UI's "Transcoding NN%" reads `optimizeProgress`, normally set by
                // `pollOptimizeActivity` matching the `/activities` feed. Under concurrent/ambiguous
                // jobs that match returns none and the value FREEZES. The server's own `bg_progress`
                // (here) keeps climbing, so feed it into the SAME store — last-write-wins with the
                // activity match. Also feed the same background progress into the ETA EMA: the
                // activity feed can expose only one optimize activity even while PMS runs several
                // background transcoders, so a row could show "Transcoding 7%" from this endpoint
                // but never get a time estimate if ETA sampling stayed activity-only.
                if let pct = attributedJob?.progress, pct >= 0, pct <= 100 {
                    let bgFraction = min(1.0, Double(pct) / 100.0)
                    updateOptimizeETA(ratingKey: ratingKey, progress: bgFraction)
                    // Monotonic for display: never let it visibly step backward (prefer the
                    // larger), so a brief disagreement with the activity match can't jitter the bar.
                    optimizeProgress[ratingKey] = max(bgFraction, optimizeProgress[ratingKey] ?? 0)
                    if optimizeState[ratingKey] == nil { optimizeState[ratingKey] = "transcoding" }
                }

                // PREFERRED transcode-ETA source: remaining_video_seconds / speed (steadier than
                // the progress-rate EMA), written into the SINGLE published `optimizeETA` store —
                // superseding the EMA set above/earlier this poll by `pollOptimizeActivity` (last
                // write wins), falling back to the EMA when the server reports no usable speed.
                if let speed = attributedJob?.speed, speed > 0,
                   let pct = attributedJob?.progress, pct >= 0, pct < 100,
                   let etaSeconds = speedBasedTranscodeETA(ratingKey: ratingKey,
                                                           progressPercent: pct, speed: speed) {
                    optimizeETA[ratingKey] = etaSeconds
                    fields["bg_speed_eta_sec"] = .int(Int(etaSeconds))
                }
            } else if thisIsQueuedConversion {
                // Waiting behind the active conversion — say so honestly ("Queued on server")
                // instead of an indefinite "Preparing on server…". Never clobber a real % that's
                // already showing (a row that briefly drops out of the active slot keeps its bar).
                if optimizeProgress[ratingKey] == nil {
                    optimizeState[ratingKey] = "queued"
                }
            }
        }

        // 3. /:/prefs → BackgroundQueueIdlePaused (the gate on whether the queue runs at all).
        if let prefs = try? await appModel.client.send(
            BackgroundQueueRequest.prefsRequest(server: server, token: token, identity: identity),
            as: ServerPrefs.self),
           let paused = prefs.backgroundQueueIdlePaused {
            fields["idle_paused"] = .bool(paused)
        }

        recordDownloadDiagnostic("downloads.optimize_server_probe", fields: fields)
    }

}

private extension String {
    var urlQueryEscapedForPlexPath: String {
        addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? self
    }
}
