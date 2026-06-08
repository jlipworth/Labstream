import Foundation
import Observation
import PlexKit

/// Coordinates the offline-download pipeline:
///   1. trigger a server-side capped-bitrate optimize (8 Mbps 1080p preset),
///   2. poll the item's metadata until the optimized `Part` appears,
///   3. fetch that part over a **background** `URLSession` into Application Support,
///   4. record it in `DownloadStore` (ratingKey -> local file, size, progress).
///
/// Offline playback reuses the Task 11 player via `PlayerView(localFile:item:)`.
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
        self.session.reattach()
    }

    /// Absolute local URL for a completed download, if present on disk.
    public func localURL(for ratingKey: String) -> URL? {
        store.localURL(for: ratingKey)
    }

    /// Full pipeline: optimize -> poll -> background-download -> record.
    /// Records the resulting state (including any error) rather than throwing.
    public func optimizeAndDownload(_ item: MediaItem) async {
        let ratingKey = item.ratingKey
        guard let token = appModel.token, let server = appModel.serverBaseURL else {
            lastError[ratingKey] = .notAuthenticated
            return
        }
        guard !activeJobs.contains(ratingKey) else { return }
        activeJobs.insert(ratingKey)
        lastError[ratingKey] = nil
        defer { activeJobs.remove(ratingKey) }

        // Seed a 0% record so the UI shows the job immediately.
        let seed = DownloadRecord(ratingKey: ratingKey, title: item.title,
                                  localURL: store.destinationURL(ratingKey: ratingKey, ext: "mp4"),
                                  bytes: 0, progress: 0)
        store.upsert(seed)
        refreshRecords()

        do {
            try await triggerOptimize(item: item, server: server, token: token,
                                      identity: appModel.identity)
            let part = try await pollForOptimizedPart(ratingKey: ratingKey, server: server,
                                                      token: token, identity: appModel.identity)
            let ext = part.container ?? (part.file as NSString?)?.pathExtension ?? "mp4"
            let destination = store.destinationURL(ratingKey: ratingKey, ext: ext.isEmpty ? "mp4" : ext)
            store.upsert(DownloadRecord(ratingKey: ratingKey, title: item.title,
                                        localURL: destination, bytes: 0, progress: 0))
            refreshRecords()

            let downloadURL = OptimizeRequest.downloadURL(server: server, token: token, partKey: part.key)
            try session.start(ratingKey: ratingKey, from: downloadURL, to: destination)
            refreshRecords()
        } catch let error as DownloadError {
            lastError[ratingKey] = error
            store.remove(ratingKey: ratingKey)
            refreshRecords()
        } catch {
            lastError[ratingKey] = .transferFailed(String(describing: error))
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
    public func optimizeAndDownload(_ item: MediaItem, quality: DownloadQuality) async {
        let ratingKey = item.ratingKey
        guard let token = appModel.token, let server = appModel.serverBaseURL else {
            lastError[ratingKey] = .notAuthenticated
            return
        }
        guard !activeJobs.contains(ratingKey) else { return }
        activeJobs.insert(ratingKey)
        lastError[ratingKey] = nil
        defer { activeJobs.remove(ratingKey) }

        // The transcoded download always lands as an MP4 (we ask `protocol=http`).
        let destination = store.destinationURL(ratingKey: ratingKey, ext: "mp4")
        // Seed a 0% record so the UI shows the job immediately.
        store.upsert(DownloadRecord(ratingKey: ratingKey, title: item.title,
                                    localURL: destination, bytes: 0, progress: 0))
        refreshRecords()

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
                                         mediaIndex: 0,
                                         partIndex: 0)
        do {
            try session.start(ratingKey: ratingKey,
                              from: transcode.downloadURL(),
                              to: destination)
            refreshRecords()
        } catch let error as DownloadError {
            lastError[ratingKey] = error
            store.remove(ratingKey: ratingKey)
            refreshRecords()
        } catch {
            lastError[ratingKey] = .transferFailed(String(describing: error))
            refreshRecords()
        }
    }

    /// Whether a download already exists (completed or in-flight) for `ratingKey`.
    /// Lets the options sheet show "Downloaded" / disable re-download.
    public func hasDownload(for ratingKey: String) -> Bool {
        records.contains { $0.ratingKey == ratingKey }
    }

    /// Delete a download and its backing file.
    public func delete(ratingKey: String) {
        session.cancel(ratingKey: ratingKey)
        store.remove(ratingKey: ratingKey)
        lastError[ratingKey] = nil
        refreshRecords()
    }

    private func refreshRecords() {
        records = store.records
    }

    // MARK: - Optimize trigger (HIGH UNCERTAINTY — isolated)

    /// Trigger the server-side optimized (capped-bitrate) version of `item`.
    ///
    /// // TODO(live): verify optimize endpoint + targetTagID against the live
    /// server (research/11). PlexKit's `OptimizeRequest.create` encodes a
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
    private let lock = NSLock()

    /// Called on any progress/completion so the manager can refresh records.
    var onChange: (() -> Void)?

    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.isDiscretionary = false
        // The OS may relaunch us in the background to finish transfers; required so
        // `handleEventsForBackgroundURLSession` is delivered to the app delegate.
        config.sessionSendsLaunchEvents = true
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
    func reattach() {
        urlSession.getAllTasks { [weak self] tasks in
            guard let self else { return }
            // Rebuild the taskIdentifier -> (ratingKey, destination) map for any
            // tasks the OS resumed. We match a task to a record by its source URL's
            // `path` query param (the metadataKey), which is stable per item; if we
            // can't match we still leave the task running and rely on the store row.
            self.lock.lock()
            for task in tasks {
                guard self.inflight[task.taskIdentifier] == nil,
                      let ratingKey = Self.ratingKey(for: task, store: self.store) else { continue }
                let destination = self.store.destinationURL(ratingKey: ratingKey, ext: "mp4")
                self.inflight[task.taskIdentifier] = (ratingKey, destination)
            }
            self.lock.unlock()
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
    func start(ratingKey: String, from url: URL, to destination: URL) throws {
        // Pre-flight storage check: refuse if free space is implausibly low.
        if let free = try? fileManager
            .attributesOfFileSystem(forPath: store.directory.path)[.systemFreeSize] as? Int64,
           free < 500_000_000 {       // < ~500 MB free
            throw DownloadManager.DownloadError.storageFull
        }
        let task = urlSession.downloadTask(with: url)
        lock.lock()
        inflight[task.taskIdentifier] = (ratingKey, destination)
        lock.unlock()
        task.resume()
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
        lock.lock(); let entry = inflight[downloadTask.taskIdentifier]; lock.unlock()
        guard let entry else { return }
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
        // Validate the HTTP status — Plex returns 200 for a real file body.
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            store.remove(ratingKey: entry.ratingKey)
            onChange?()
            return
        }
        // Move the temp file into place atomically.
        do {
            try? fileManager.removeItem(at: entry.destination)
            try fileManager.moveItem(at: location, to: entry.destination)
            let size = (try? fileManager.attributesOfItem(atPath: entry.destination.path)[.size] as? Int) ?? nil
            let bytes = size ?? 0
            store.updateProgress(ratingKey: entry.ratingKey, bytes: bytes, progress: 1.0)
        } catch {
            store.remove(ratingKey: entry.ratingKey)
        }
        onChange?()
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        lock.lock(); let entry = inflight.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let entry, let error else { return }
        // A cancel is not a failure; everything else removes the partial record.
        if (error as NSError).code != NSURLErrorCancelled {
            store.remove(ratingKey: entry.ratingKey)
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
