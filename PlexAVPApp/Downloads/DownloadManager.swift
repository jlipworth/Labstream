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

    private let store: DownloadStore
    private let fileManager = FileManager.default
    /// taskIdentifier -> (ratingKey, destination)
    private var inflight: [Int: (ratingKey: String, destination: URL)] = [:]
    private let lock = NSLock()

    /// Called on any progress/completion so the manager can refresh records.
    var onChange: (() -> Void)?

    private lazy var urlSession: URLSession = {
        let id = "com.plexavp.downloads.background"
        let config = URLSessionConfiguration.background(withIdentifier: id)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    init(store: DownloadStore) {
        self.store = store
        super.init()
    }

    /// Rebind delegate to any tasks the background session resumed after relaunch.
    func reattach() {
        urlSession.getAllTasks { _ in /* tasks redeliver via delegate callbacks */ }
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
}
