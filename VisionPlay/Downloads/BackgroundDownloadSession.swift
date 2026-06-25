import Foundation
import AVFoundation
import PMSKit

/// Wraps a background `URLSession` so transfers survive app suspension and
/// relaunch. On visionOS the OS pauses background transfers while the headset is
/// OFF and resumes them when worn again — surface that reality in the UI
/// (research/10): a "download" is best-effort and may stall until the headset is
/// back on the user's head.
///
/// Delegate callbacks land off the main actor; we hop to `@MainActor` for record
/// updates via `onChange`. The store itself is internally locked.
final class BackgroundDownloadSession: NSObject, URLSessionDownloadDelegate, URLSessionDataDelegate, @unchecked Sendable {

    /// The fixed background-session identifier. Shared with the app delegate so it can
    /// route `handleEventsForBackgroundURLSession` to THIS session's completion handler.
    static let identifier = "com.visionplay.downloads.background"

    private let store: DownloadStore
    private let fileManager = FileManager.default
    /// taskIdentifier -> (ratingKey, destination)
    private var inflight: [Int: (ratingKey: String, destination: URL)] = [:]
    /// taskIdentifier -> app-managed byte-range transfer state. Unlike `URLSessionDownloadTask`,
    /// this writes bytes directly to the final partial file so a restart/network change can resume
    /// with an explicit `Range: bytes=<current-size>-` request even when URLSession supplies no
    /// opaque resume blob.
    private var rangeInflight: [Int: RangeTransfer] = [:]
    /// taskIdentifiers whose expected-size has already been logged once (diagnostics).
    private var loggedExpectation: Set<Int> = []
    /// Retry count by ratingKey for transient URLSession drops that provide resume data.
    private var retryCounts: [String: Int] = [:]
    /// Last UI refresh per ratingKey; progress callbacks can arrive many times per second.
    private var lastProgressNotify: [String: Date] = [:]
    /// Progress milestones already mirrored to the diagnostics ring buffer per task.
    private var loggedProgressMilestones: [Int: Set<Int>] = [:]
    private let maxTransientRetries = 3
    private let progressNotifyInterval: TimeInterval = 0.5
    private let lock = NSLock()

    private struct RangeTransfer {
        let ratingKey: String
        let destination: URL
        let expectedBytes: Int?
        var responseStatus: Int?
        var responseMIME: String?
        var baseOffset: Int
        var bytesThisTask: Int
        var handle: FileHandle?

        var totalBytes: Int { baseOffset + bytesThisTask }
    }

    /// Called on any progress/completion so the manager can refresh records.
    var onChange: (() -> Void)?

    /// D3: invoked from each delegate failure/validation path so the manager can
    /// surface a reason (`lastError`) instead of the row vanishing without cause.
    /// Lands off the main actor; the manager hops to `@MainActor` to apply it.
    var onError: ((_ ratingKey: String, _ error: DownloadManager.DownloadError) -> Void)?

    private lazy var urlSession: URLSession = {
        let config: URLSessionConfiguration
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--vp-probe-background-download-session") {
            config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
            config.isDiscretionary = false
            config.sessionSendsLaunchEvents = true
            downloadLog.info("using BACKGROUND URLSession (simulator probe override) for downloads")
        } else {
        // The background transfer daemon (`nsurlsessiond`) is unreliable in the visionOS
        // simulator: it intermittently refuses the XPC connection (NSCocoaError 4097), so
        // `downloadTask` creation fails and the task dies immediately with
        // NSURLErrorUnknown (-1) / 0 bytes received. A foreground (in-process) session
        // needs no daemon, so downloads work while developing in the sim. Real devices
        // always have the daemon, so they keep the background session below (which
        // survives app suspension/relaunch — the resume-after-kill path from D5/D8).
            config = URLSessionConfiguration.default
            downloadLog.info("using FOREGROUND URLSession (simulator) for downloads")
        }
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


    /// In-process session used only for app-managed byte-range checkpoints.
    ///
    /// A Foundation background session is still used for opaque `URLSessionDownloadTask` lanes,
    /// but these checkpointed static transfers write bytes directly into our partial file and
    /// explicitly resume with an HTTP Range header after interruption/relaunch. Keep them on a
    /// default session on both simulator and device; background sessions are for system-managed
    /// upload/download tasks, not arbitrary delegate-managed data writes.
    private lazy var rangeURLSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = true
        config.waitsForConnectivity = true
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
            // Build the indexed-key set ONCE (FS-free) before the task loop, instead of
            // stat'ing every store row per task under the held lock (was O(tasks×rows)).
            let knownKeys = self.store.allRatingKeys
            let destinations = self.store.destinationsByRatingKey
            self.lock.lock()
            for task in tasks {
                guard self.inflight[task.taskIdentifier] == nil,
                      let ratingKey = Self.ratingKey(for: task, knownKeys: knownKeys) else { continue }
                let destination = destinations[ratingKey]
                    ?? self.store.destinationURL(ratingKey: ratingKey, ext: "mp4")
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
    /// Prefer the task description we set at creation time. Fall back to URL-shape heuristics
    /// for older tasks: the original request URL may carry the item's metadata key as the `path`
    /// query param (`/library/metadata/<ratingKey>`) or a Jellyfin `/Items`/`/Videos` path. Plex
    /// `/library/parts/...` downloads do not include the source ratingKey, which is why the
    /// explicit task description is required for reliable force-quit/relaunch reattach.
    private static func ratingKey(for task: URLSessionTask, knownKeys: Set<String>) -> String? {
        if let taskDescription = task.taskDescription, knownKeys.contains(taskDescription) {
            return taskDescription
        }
        guard let url = task.originalRequest?.url,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let candidates: [String]
        if let path = comps.queryItems?.first(where: { $0.name == "path" })?.value {
            candidates = [(path as NSString).lastPathComponent]
        } else {
            let parts = comps.path.split(separator: "/").map(String.init)
            if let items = parts.firstIndex(of: "Items"), parts.indices.contains(items + 1) {
                candidates = [parts[items + 1]]
            } else if let videos = parts.firstIndex(of: "Videos"), parts.indices.contains(videos + 1) {
                candidates = [parts[videos + 1]]
            } else {
                candidates = []
            }
        }
        let expanded = candidates.flatMap { [$0, "jellyfin:\($0)"] }
        return expanded.first { knownKeys.contains($0) }
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
               expectedBytes: Int? = nil, byteRangeCheckpoint: Bool = false) throws {
        try start(ratingKey: ratingKey,
                  with: URLRequest(url: url),
                  to: destination,
                  expectedBytes: expectedBytes,
                  byteRangeCheckpoint: byteRangeCheckpoint)
    }

    /// Begin (or resume) a background download with an explicit request.
    ///
    /// Jellyfin downloads need auth headers; keep this overload so callers do not
    /// smuggle tokens into query strings just to satisfy `downloadTask(with: URL)`.
    func start(ratingKey: String, with request: URLRequest, to destination: URL,
               expectedBytes: Int? = nil, byteRangeCheckpoint: Bool = false) throws {
        // Pre-flight storage check: refuse if free space can't plausibly hold the
        // file. Sized against the expected bytes (plus headroom for the OS and the
        // temp-then-move copy) when known, so a 5 GB download with 600 MB free fails
        // here rather than mid-transfer.
        let headroom: Int64 = 500_000_000
        let required = max(headroom, Int64(expectedBytes ?? 0) + headroom)
        if let free = try? fileManager
            .attributesOfFileSystem(forPath: store.directory.path)[.systemFreeSize] as? Int64,
           free < required {
            AppDiagnostics.record(.downloads, "downloads.transfer_start_failed", fields: [
                "download_id": .identifier(ratingKey),
                "reason": .label("storage_full"),
                "required_bytes": .bytes(Int(required)),
                "free_bytes": .bytes(Int(free)),
            ])
            throw DownloadManager.DownloadError.storageFull
        }
        if byteRangeCheckpoint {
            try startRangeCheckpoint(ratingKey: ratingKey, with: request, to: destination,
                                     expectedBytes: expectedBytes)
            return
        }

        let task = urlSession.downloadTask(with: request)
        task.taskDescription = ratingKey
        lock.lock()
        retryCounts[ratingKey] = 0
        lastProgressNotify[ratingKey] = nil
        loggedProgressMilestones[task.taskIdentifier] = []
        inflight[task.taskIdentifier] = (ratingKey, destination)
        lock.unlock()
        downloadLog.info("start ratingKey=\(ratingKey, privacy: .public) path=\(request.url?.path ?? "nil", privacy: .public)")
        AppDiagnostics.record(.downloads, "downloads.transfer_start", fields: [
            "download_id": .identifier(ratingKey),
            "url_shape": .urlShape(request.url),
            "expected_bytes": .bytes(expectedBytes),
            "has_expected_bytes": .bool(expectedBytes != nil),
        ])
        task.resume()
    }

    /// Start an app-managed static transfer from the current durable byte checkpoint.
    ///
    /// The final destination itself is the partial file. On retry/relaunch, its current size is the
    /// checkpoint and the new request carries `Range: bytes=<size>-`. If the server ignores Range
    /// with HTTP 200, we truncate and restart honestly from 0; if it honors Range with 206, progress
    /// never jumps backwards.
    private func startRangeCheckpoint(ratingKey: String, with request: URLRequest, to destination: URL,
                                      expectedBytes: Int?) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        var offset = 0
        if fileManager.fileExists(atPath: destination.path) {
            let attrs = try? fileManager.attributesOfItem(atPath: destination.path)
            offset = attrs?[.size] as? Int ?? 0
            if let expectedBytes, offset > expectedBytes {
                try? fileManager.removeItem(at: destination)
                offset = 0
            }
        } else {
            fileManager.createFile(atPath: destination.path, contents: nil)
        }
        if let expectedBytes, offset >= expectedBytes, expectedBytes > 0 {
            store.updateProgress(ratingKey: ratingKey, bytes: expectedBytes, progress: 1)
            store.setStatus(ratingKey: ratingKey, .complete)
            onChange?()
            return
        }

        var ranged = request
        if offset > 0 {
            ranged.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        let task = rangeURLSession.dataTask(with: ranged)
        task.taskDescription = ratingKey
        lock.lock()
        retryCounts[ratingKey] = 0
        lastProgressNotify[ratingKey] = nil
        loggedProgressMilestones[task.taskIdentifier] = []
        rangeInflight[task.taskIdentifier] = RangeTransfer(
            ratingKey: ratingKey,
            destination: destination,
            expectedBytes: expectedBytes,
            responseStatus: nil,
            responseMIME: nil,
            baseOffset: offset,
            bytesThisTask: 0,
            handle: nil)
        lock.unlock()
        if offset > 0, let expectedBytes, expectedBytes > 0 {
            store.updateProgress(ratingKey: ratingKey,
                                 bytes: offset,
                                 progress: min(1, Double(offset) / Double(expectedBytes)))
        }
        downloadLog.info("range-start ratingKey=\(ratingKey, privacy: .public) offset=\(offset, privacy: .public) path=\(ranged.url?.path ?? "nil", privacy: .public)")
        AppDiagnostics.record(.downloads, "downloads.range_start", fields: [
            "download_id": .identifier(ratingKey),
            "offset_bytes": .bytes(offset),
            "has_offset": .bool(offset > 0),
            "expected_bytes": .bytes(expectedBytes),
            "url_shape": .urlShape(ranged.url),
        ])
        task.resume()
    }

    /// Path + query of a request URL with token-bearing query values redacted and the host omitted —
    /// safe to log for diagnosing a transcode/download rejection without leaking credentials or the
    /// server hostname.
    static func sanitizedPathQuery(_ url: URL?) -> String {
        guard let url, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "nil"
        }
        let secretNames = ["X-Plex-Token", "api_key", "ApiKey", "apikey", "token", "access_token"]
        comps.queryItems = comps.queryItems?.map { item in
            secretNames.contains { $0.caseInsensitiveCompare(item.name) == .orderedSame }
                ? URLQueryItem(name: item.name, value: "REDACTED")
                : item
        }
        let query = comps.query.map { "?\($0)" } ?? ""
        return comps.path + query
    }

    /// #95: resume a `.paused` download from persisted URLSession resume data, continuing from
    /// the byte offset instead of restarting at 0. Mirrors `start(...)`'s bookkeeping but creates
    /// the task with `downloadTask(withResumeData:)`. Returns `false` if the resume data was
    /// rejected (the caller then falls back to a clean restart). The OS validates the blob lazily;
    /// a stale/invalid blob surfaces later via `didCompleteWithError` (200 full-restart / 416),
    /// which the caller's normal failure path handles.
    @discardableResult
    func resume(ratingKey: String, resumeData: Data, to destination: URL) -> Bool {
        guard !resumeData.isEmpty else { return false }
        let task = urlSession.downloadTask(withResumeData: resumeData)
        task.taskDescription = ratingKey
        lock.lock()
        retryCounts[ratingKey] = 0
        lastProgressNotify[ratingKey] = nil
        loggedProgressMilestones[task.taskIdentifier] = []
        inflight[task.taskIdentifier] = (ratingKey, destination)
        lock.unlock()
        downloadLog.info("resume ratingKey=\(ratingKey, privacy: .public) bytes=\(resumeData.count, privacy: .public)")
        AppDiagnostics.record(.downloads, "downloads.transfer_resume", fields: [
            "download_id": .identifier(ratingKey),
            "resume_blob_bytes": .bytes(resumeData.count),
        ])
        task.resume()
        return true
    }

    /// Pause any in-flight transfer for a ratingKey. Prefer URLSession resume data for static
    /// byte-range-safe lanes; for forward-only transcode/remux streams, this still becomes a safe
    /// user pause (no auto-retry until Resume), but Resume restarts cleanly.
    func pause(ratingKey: String) {
        AppDiagnostics.record(.downloads, "downloads.pause_requested", fields: [
            "download_id": .identifier(ratingKey),
        ])
        urlSession.getAllTasks { tasks in
            self.lock.lock()
            let ids = Set(self.inflight.filter { $0.value.ratingKey == ratingKey }.map(\.key))
            let rangeIds = Set(self.rangeInflight.filter { $0.value.ratingKey == ratingKey }.map(\.key))
            self.lock.unlock()

            var matched = false
            for task in tasks where ids.contains(task.taskIdentifier) || rangeIds.contains(task.taskIdentifier) {
                matched = true
                if rangeIds.contains(task.taskIdentifier) {
                    self.lock.lock()
                    let entry = self.rangeInflight.removeValue(forKey: task.taskIdentifier)
                    self.lock.unlock()
                    try? entry?.handle?.close()
                    task.cancel()
                    let bytes = (try? self.fileManager.attributesOfItem(atPath: entry?.destination.path ?? "")[.size] as? Int)
                        ?? entry?.totalBytes
                        ?? 0
                    AppDiagnostics.record(.downloads, "downloads.range_checkpoint_paused", fields: [
                        "download_id": .identifier(ratingKey),
                        "bytes": .bytes(bytes),
                    ])
                    self.store.setStatus(ratingKey: ratingKey, .paused)
                    self.onError?(ratingKey, .interruptedResumable)
                    self.onChange?()
                } else if let downloadTask = task as? URLSessionDownloadTask {
                    downloadTask.cancel { resumeData in
                        let resumeBytes = resumeData?.count ?? 0
                        let supportsResume = self.store.supportsPersistedResumeData(ratingKey: ratingKey)
                        AppDiagnostics.record(.downloads, "downloads.pause_resume_data", fields: [
                            "download_id": .identifier(ratingKey),
                            "resume_data_present": .bool(resumeBytes > 0),
                            "resume_blob_bytes": .bytes(resumeBytes),
                            "supports_resume": .bool(supportsResume),
                        ])
                        if let resumeData, !resumeData.isEmpty, supportsResume {
                            self.store.setResumeData(ratingKey: ratingKey, resumeData)
                        }
                        self.store.setStatus(ratingKey: ratingKey, .paused)
                        self.onError?(ratingKey, .interruptedResumable)
                        self.onChange?()
                    }
                } else {
                    task.cancel()
                    self.store.setStatus(ratingKey: ratingKey, .paused)
                    self.onError?(ratingKey, .interruptedResumable)
                    self.onChange?()
                }
            }

            if !matched {
                self.store.setStatus(ratingKey: ratingKey, .paused)
                self.onChange?()
            }
        }
        lock.lock()
        inflight = inflight.filter { $0.value.ratingKey != ratingKey }
        lock.unlock()
    }

    /// Cancel any in-flight transfer for a ratingKey.
    func cancel(ratingKey: String) {
        AppDiagnostics.record(.downloads, "downloads.cancel_requested", fields: [
            "download_id": .identifier(ratingKey),
        ])
        lock.lock()
        let ids = Set(inflight.filter { $0.value.ratingKey == ratingKey }.map(\.key))
        let rangeIds = Set(rangeInflight.filter { $0.value.ratingKey == ratingKey }.map(\.key))
        let removedRanges = rangeInflight.filter { $0.value.ratingKey == ratingKey }.map(\.value)
        inflight = inflight.filter { $0.value.ratingKey != ratingKey }
        rangeInflight = rangeInflight.filter { $0.value.ratingKey != ratingKey }
        lock.unlock()
        for range in removedRanges { try? range.handle?.close() }

        urlSession.getAllTasks { tasks in
            for task in tasks where ids.contains(task.taskIdentifier) {
                task.cancel()
            }
        }
        rangeURLSession.getAllTasks { tasks in
            for task in tasks where rangeIds.contains(task.taskIdentifier) {
                task.cancel()
            }
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        let entry = rangeInflight[dataTask.taskIdentifier]
        lock.unlock()
        guard var entry else {
            completionHandler(.allow)
            return
        }
        let http = response as? HTTPURLResponse
        entry.responseStatus = http?.statusCode
        entry.responseMIME = http?.mimeType

        if let status = http?.statusCode, entry.baseOffset > 0, status == 200 {
            // Server ignored Range. Restart honestly from 0 rather than appending a duplicate body.
            try? fileManager.removeItem(at: entry.destination)
            fileManager.createFile(atPath: entry.destination.path, contents: nil)
            entry.baseOffset = 0
            entry.bytesThisTask = 0
            store.updateProgress(ratingKey: entry.ratingKey, bytes: 0, progress: 0)
            AppDiagnostics.record(.downloads, "downloads.range_restart", fields: [
                "download_id": .identifier(entry.ratingKey),
                "reason": .label("server_ignored_range"),
            ])
        }

        guard let handle = try? FileHandle(forWritingTo: entry.destination) else {
            completionHandler(.cancel)
            return
        }
        _ = try? handle.seekToEnd()
        entry.handle = handle
        lock.lock()
        rangeInflight[dataTask.taskIdentifier] = entry
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        lock.lock()
        let entry = rangeInflight[dataTask.taskIdentifier]
        lock.unlock()
        guard var entry else { return }

        do {
            if entry.handle == nil {
                entry.handle = try FileHandle(forWritingTo: entry.destination)
                try entry.handle?.seekToEnd()
            }
            try entry.handle?.write(contentsOf: data)
        } catch {
            dataTask.cancel()
            store.setStatus(ratingKey: entry.ratingKey, .failed)
            onError?(entry.ratingKey, .transferFailed(String(describing: error)))
            onChange?()
            return
        }

        entry.bytesThisTask += data.count
        let total = entry.totalBytes
        let progress = (entry.expectedBytes ?? 0) > 0
            ? min(1, Double(total) / Double(entry.expectedBytes!))
            : 0
        lock.lock()
        rangeInflight[dataTask.taskIdentifier] = entry
        lock.unlock()
        store.updateProgress(ratingKey: entry.ratingKey, bytes: total, progress: progress)
        notifyProgressChangeIfNeeded(ratingKey: entry.ratingKey, progress: progress)
    }

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
            AppDiagnostics.record(.downloads, "downloads.progress_first", fields: [
                "download_id": .identifier(entry.ratingKey),
                "expected_bytes": .bytes(totalBytesExpectedToWrite > 0 ? Int(totalBytesExpectedToWrite) : nil),
                "has_expected_bytes": .bool(totalBytesExpectedToWrite > 0),
            ])
        }
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        if totalBytesExpectedToWrite > 0 {
            let percent = Int((progress * 100).rounded(.down))
            var reached: [Int] = []
            lock.lock()
            var logged = loggedProgressMilestones[downloadTask.taskIdentifier, default: []]
            for milestone in [25, 50, 75, 100] where percent >= milestone && !logged.contains(milestone) {
                logged.insert(milestone)
                reached.append(milestone)
            }
            loggedProgressMilestones[downloadTask.taskIdentifier] = logged
            lock.unlock()
            for milestone in reached {
                AppDiagnostics.record(.downloads, "downloads.progress_milestone", fields: [
                    "download_id": .identifier(entry.ratingKey),
                    "percent": .int(milestone),
                    "bytes_written": .bytes(Int(totalBytesWritten)),
                ])
            }
        }
        store.updateProgress(ratingKey: entry.ratingKey,
                             bytes: Int(totalBytesWritten),
                             progress: progress)
        notifyProgressChangeIfNeeded(ratingKey: entry.ratingKey, progress: progress)
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
            AppDiagnostics.record(.downloads, "downloads.validation_failed", fields: [
                "download_id": .identifier(entry.ratingKey),
                "reason": .text(reason),
            ])
            try? fileManager.removeItem(at: entry.destination)
            clearRetryCount(ratingKey: entry.ratingKey)
            store.setStatus(ratingKey: entry.ratingKey, .failed)
            onError?(entry.ratingKey, .invalidDownload(reason))
            onChange?()
        }

        let httpStatus = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
        let mime = (downloadTask.response as? HTTPURLResponse)?.mimeType ?? "nil"
        downloadLog.info("finished-transfer ratingKey=\(entry.ratingKey, privacy: .public) http=\(httpStatus, privacy: .public) mime=\(mime, privacy: .public)")
        AppDiagnostics.record(.downloads, "downloads.transfer_finished", fields: [
            "download_id": .identifier(entry.ratingKey),
            "http_status": .int(httpStatus),
            "http_status_class": .label(httpStatus > 0 ? "\(httpStatus / 100)xx" : "unknown"),
            "mime": .label(mime),
        ])

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
            AppDiagnostics.record(.downloads, "downloads.move_failed", fields: [
                "download_id": .identifier(entry.ratingKey),
                "error": .error(error),
            ])
            store.setStatus(ratingKey: entry.ratingKey, .failed)
            onError?(entry.ratingKey, .transferFailed(String(describing: error)))
            onChange?()
            return
        }

        // 3. Size observation — tiny bodies used to be rejected categorically here. That caught
        // error pages, but it also made valid short clips/trailers impossible to download. HTTP
        // status + MIME catches obvious server errors above; let the AVFoundation probe below be
        // the source of truth for small-but-valid media.
        let bytes = (try? fileManager.attributesOfItem(atPath: entry.destination.path)[.size] as? Int)
            .flatMap { $0 } ?? 0
        if bytes < 1_000_000 {
            AppDiagnostics.record(.downloads, "downloads.small_file_validation", fields: [
                "download_id": .identifier(entry.ratingKey),
                "bytes": .bytes(bytes),
            ])
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

        // #83/#127: HEVC tag fixup. A stream-copied HEVC MP4 can be `hev1`-tagged, which
        // AVFoundation black-screens. Rewrite it losslessly to `hvc1` on the moved file BEFORE the
        // playability probe (which is exactly what would otherwise fail on an `hev1` file and reject
        // a perfectly good download). Originally this was gated to the compatible-remux lane (#83),
        // but #127: a Plex `.original` / `.existingVersion` STATIC download of a server-original
        // MP4/MOV can be `hev1`-tagged just as easily, and those lanes were skipping the fixup and
        // black-screening on device. Gate on the CONTAINER instead of the lane — run for any
        // mp4-family download. `rewriteFile` no-ops (returns 0) on non-HEVC / non-`hev1` files, so
        // this is safe for every mp4/m4v/mov download; other containers (mkv, …) are skipped since
        // the ISO-BMFF FourCC rewrite doesn't apply to them.
        let mp4FamilyContainers: Set<String> = ["mp4", "m4v", "mov"]
        if mp4FamilyContainers.contains(destination.pathExtension.lowercased()) {
            do {
                let count = try HEVCTagFixup.rewriteFile(at: destination)
                if count > 0 {
                    AppDiagnostics.record(.downloads, "downloads.hevc_tag_fixup", fields: [
                        "download_id": .identifier(ratingKey),
                        "entries": .int(count),
                    ])
                }
            } catch {
                // A fixup failure is not fatal — let the probe decide. Never log the file path.
                AppDiagnostics.record(.downloads, "downloads.hevc_tag_fixup_failed", fields: [
                    "download_id": .identifier(ratingKey),
                    "error": .error(error),
                ])
            }
        }

        Task { [weak self] in
            guard let self else { return }
            // GH #98: the post-download playability probe is an INTERMITTENT false-negative — on a
            // device busy right after a heavy transcode+download, AVFoundation can transiently fail
            // to open/advance a COMPLETE file that a later attempt on the same bytes plays fine
            // (confirmed: a download that "did not start local playback" succeeded on a plain
            // re-download with no other change). Retry with progressively longer timeouts before
            // condemning the download.
            var validation = await Self.validateLocalPlayback(destination)
            if !validation.played {
                for extraTimeout in [15.0, 25.0] {
                    downloadLog.notice("playback-probe retry ratingKey=\(ratingKey, privacy: .public) reason=\(validation.reason, privacy: .public) nextTimeout=\(extraTimeout, privacy: .public)")
                    try? await Task.sleep(for: .seconds(2))
                    validation = await Self.validateLocalPlayback(destination, timeoutSecondsOverride: extraTimeout)
                    if validation.played { break }
                }
            }
            // Truncation guard: a transcode that aborts early (or a static download cut short by the
            // server while still returning HTTP 200) can open and play its first fraction of a second
            // and otherwise pass the probe. Compare the decoded duration to the EXPECTED media
            // duration — a file far shorter than the source is truncated, not complete. Only applied
            // when both durations are known; legitimate short clips compare against their own short
            // expected duration and pass. (Step 3 above no longer rejects on raw byte size.)
            let expectedDurationMs = self.store.records.first { $0.ratingKey == ratingKey }?.metadata?.duration
            if validation.played, let expectedDurationMs, expectedDurationMs > 0,
               let actualDurationMs = validation.durationMs,
               Double(actualDurationMs) < Double(expectedDurationMs) * 0.80 {
                downloadLog.error("truncated-download ratingKey=\(ratingKey, privacy: .public) expectedMs=\(expectedDurationMs, privacy: .public) actualMs=\(actualDurationMs, privacy: .public)")
                AppDiagnostics.record(.downloads, "downloads.validation_failed", fields: [
                    "download_id": .identifier(ratingKey),
                    "reason": .label("truncated_duration"),
                    "expected_duration_ms": .int(expectedDurationMs),
                    "actual_duration_ms": .int(actualDurationMs),
                ])
                try? self.fileManager.removeItem(at: destination)
                self.clearRetryCount(ratingKey: ratingKey)
                self.store.setStatus(ratingKey: ratingKey, .failed)
                self.onError?(ratingKey, .invalidDownload("Downloaded file is truncated (\(actualDurationMs / 1000)s of \(expectedDurationMs / 1000)s)."))
                self.onChange?()
                return
            }
            if validation.played {
                // Validated: mark explicitly complete (D2) so a relaunch trusts it.
                downloadLog.info("complete ratingKey=\(ratingKey, privacy: .public) bytes=\(bytes, privacy: .public)")
                AppDiagnostics.record(.downloads, "downloads.complete", fields: [
                    "download_id": .identifier(ratingKey),
                    "bytes": .bytes(bytes),
                    "validation": .label("local_playback"),
                ])
                self.clearRetryCount(ratingKey: ratingKey)
                self.store.setStatus(ratingKey: ratingKey, .complete)
            } else {
                downloadLog.error("invalid-download ratingKey=\(ratingKey, privacy: .public) reason=\(validation.reason, privacy: .public) detail=\(validation.detail ?? "nil", privacy: .public) bytes=\(bytes, privacy: .public) preserved=true")
                AppDiagnostics.record(.downloads, "downloads.validation_failed", fields: [
                    "download_id": .identifier(ratingKey),
                    "reason": .label(validation.reason),
                    "detail": .label(validation.detail ?? "none"),
                    "bytes": .bytes(bytes),
                    "preserved": .bool(true),
                ])
                // GH #98: do NOT delete or fail the file on a probe miss. The probe is an
                // intermittent false-negative on COMPLETE downloads; deleting/failing forces a
                // wasteful 0% re-download and discards good bytes. Keep the row playable but
                // explicitly unverified so the user can try the local file and the bytes remain
                // available for on-device ffprobe/root-cause work.
                self.clearRetryCount(ratingKey: ratingKey)
                self.store.setStatus(ratingKey: ratingKey, .unverified)
            }
            self.onChange?()
        }
    }


    /// - Parameter timeoutSecondsOverride: when set, overrides the policy's ready/play deadline.
    ///   Used by the GH #98 retry to give a busy device more time before condemning a complete file.
    /// - Returns: `detail` carries `AVPlayerItem.error` on an `item_failed` result, for diagnosis.
    private static func validateLocalPlayback(_ url: URL, timeoutSecondsOverride: Double? = nil)
        async -> (played: Bool, reason: String, durationMs: Int?, detail: String?) {
        let asset = AVURLAsset(url: url)
        let assetPlayable = (try? await asset.load(.isPlayable)) ?? false
        guard assetPlayable else { return (false, "asset_not_playable", nil, nil) }
        let durationMs: Int?
        if let duration = try? await asset.load(.duration),
           duration.seconds.isFinite, duration.seconds > 0 {
            durationMs = Int(duration.seconds * 1000)
        } else {
            durationMs = nil
        }
        let policy = OfflinePlaybackValidationPolicy.make(durationMs: durationMs)
        let timeoutSeconds = timeoutSecondsOverride ?? policy.timeoutSeconds

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

        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(timeoutSeconds * 1000)))
        var sawReady = false
        while ContinuousClock.now < deadline {
            switch item.status {
            case .failed:
                return (false, "item_failed", durationMs, item.error.map { String(describing: $0) })
            case .readyToPlay:
                sawReady = true
            case .unknown:
                break
            @unknown default:
                break
            }
            let seconds = player.currentTime().seconds
            if sawReady, seconds.isFinite, seconds >= policy.requiredPlaybackSeconds {
                return (true, "played", durationMs, nil)
            }
            try? await Task.sleep(for: .milliseconds(policy.pollIntervalMilliseconds))
        }
        return (false, sawReady ? "no_playback_progress" : "timeout_not_ready", durationMs, nil)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        lock.lock()
        let rangeEntry = rangeInflight.removeValue(forKey: task.taskIdentifier)
        let entry = inflight.removeValue(forKey: task.taskIdentifier)
        loggedExpectation.remove(task.taskIdentifier)
        loggedProgressMilestones.removeValue(forKey: task.taskIdentifier)
        lock.unlock()

        if let rangeEntry {
            try? rangeEntry.handle?.close()
            if let error {
                let nsError = error as NSError
                if nsError.code == NSURLErrorCancelled {
                    downloadLog.info("range-cancelled ratingKey=\(rangeEntry.ratingKey, privacy: .public) bytes=\(rangeEntry.totalBytes, privacy: .public)")
                    AppDiagnostics.record(.downloads, "downloads.range_cancelled", fields: [
                        "download_id": .identifier(rangeEntry.ratingKey),
                        "bytes": .bytes(rangeEntry.totalBytes),
                    ])
                } else {
                    downloadLog.error("range-paused ratingKey=\(rangeEntry.ratingKey, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) bytes=\(rangeEntry.totalBytes, privacy: .public)")
                    AppDiagnostics.record(.downloads, "downloads.range_paused", fields: [
                        "download_id": .identifier(rangeEntry.ratingKey),
                        "error": .error(error),
                        "bytes": .bytes(rangeEntry.totalBytes),
                    ])
                    store.setStatus(ratingKey: rangeEntry.ratingKey, .paused)
                    onError?(rangeEntry.ratingKey, .interruptedResumable)
                    onChange?()
                }
                return
            }

            let status = rangeEntry.responseStatus ?? -1
            guard (200...299).contains(status) else {
                AppDiagnostics.record(.downloads, "downloads.range_failed", fields: [
                    "download_id": .identifier(rangeEntry.ratingKey),
                    "status_code": .int(status),
                    "bytes": .bytes(rangeEntry.totalBytes),
                ])
                store.setStatus(ratingKey: rangeEntry.ratingKey, .failed)
                onError?(rangeEntry.ratingKey, .transferFailed("Server returned HTTP \(status)."))
                onChange?()
                return
            }

            if let expected = rangeEntry.expectedBytes, expected > 0, rangeEntry.totalBytes < expected {
                AppDiagnostics.record(.downloads, "downloads.range_incomplete", fields: [
                    "download_id": .identifier(rangeEntry.ratingKey),
                    "bytes": .bytes(rangeEntry.totalBytes),
                    "expected_bytes": .bytes(expected),
                ])
                store.setStatus(ratingKey: rangeEntry.ratingKey, .paused)
                onError?(rangeEntry.ratingKey, .interruptedResumable)
                onChange?()
                return
            }

            let bytes = (try? fileManager.attributesOfItem(atPath: rangeEntry.destination.path)[.size] as? Int)
                ?? rangeEntry.totalBytes
            Task {
                let validation = await Self.validateLocalPlayback(rangeEntry.destination)
                if validation.played {
                    downloadLog.info("range-complete ratingKey=\(rangeEntry.ratingKey, privacy: .public) bytes=\(bytes, privacy: .public)")
                    AppDiagnostics.record(.downloads, "downloads.complete", fields: [
                        "download_id": .identifier(rangeEntry.ratingKey),
                        "bytes": .bytes(bytes),
                        "validation": .label("range_checkpoint"),
                    ])
                    self.clearRetryCount(ratingKey: rangeEntry.ratingKey)
                    self.store.updateProgress(ratingKey: rangeEntry.ratingKey, bytes: bytes, progress: 1)
                    self.store.setStatus(ratingKey: rangeEntry.ratingKey, .complete)
                } else {
                    AppDiagnostics.record(.downloads, "downloads.validation_failed", fields: [
                        "download_id": .identifier(rangeEntry.ratingKey),
                        "reason": .label(validation.reason),
                        "detail": .label(validation.detail ?? "none"),
                        "bytes": .bytes(bytes),
                    ])
                    self.store.setStatus(ratingKey: rangeEntry.ratingKey, .failed)
                    self.onError?(rangeEntry.ratingKey, .invalidDownload(validation.reason))
                }
                self.onChange?()
            }
            return
        }

        guard let entry, let error else { return }
        let nsError = error as NSError
        // A cancel is not a failure. Any other error keeps a `.failed` row (D3) with a
        // surfaced reason, rather than silently erasing it so the UI can offer retry.
        if nsError.code != NSURLErrorCancelled {
            if retryTransientFailure(nsError, task: task, entry: entry) {
                return
            }
            // #95: a recoverable interruption (commonly a long headset-off, which can produce an
            // error OUTSIDE the narrow transient set yet still hand back resume data) should be
            // treated as PAUSED-and-resumable, not failed. Branch on the PRESENCE of resume data
            // rather than the error code, persist the blob so a manual Resume — even after a
            // relaunch — continues from the offset, and surface a non-red "will resume" state.
            // The partial bytes are retained (reconcile keeps a `.paused` row's file).
            if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
               !resumeData.isEmpty {
                guard store.supportsPersistedResumeData(ratingKey: entry.ratingKey) else {
                    downloadLog.error("transfer-nonresumable ratingKey=\(entry.ratingKey, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) bytesReceived=\(task.countOfBytesReceived, privacy: .public) resumeData=true")
                    AppDiagnostics.record(.downloads, "downloads.transfer_nonresumable", fields: [
                        "download_id": .identifier(entry.ratingKey),
                        "error": .error(error),
                        "bytes_received": .bytes(Int(task.countOfBytesReceived)),
                        "resume_data_present": .bool(true),
                    ])
                    clearRetryCount(ratingKey: entry.ratingKey)
                    store.setStatus(ratingKey: entry.ratingKey, .failed)
                    onError?(entry.ratingKey, .transferFailed("Download interrupted; this transcoded stream can’t resume from its byte offset. Retry will restart from the beginning."))
                    onChange?()
                    return
                }
                downloadLog.error("transfer-paused ratingKey=\(entry.ratingKey, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) bytesReceived=\(task.countOfBytesReceived, privacy: .public)")
                AppDiagnostics.record(.downloads, "downloads.transfer_paused", fields: [
                    "download_id": .identifier(entry.ratingKey),
                    "error": .error(error),
                    "bytes_received": .bytes(Int(task.countOfBytesReceived)),
                ])
                store.setResumeData(ratingKey: entry.ratingKey, resumeData)
                clearRetryCount(ratingKey: entry.ratingKey)
                store.setStatus(ratingKey: entry.ratingKey, .paused)
                onError?(entry.ratingKey, .interruptedResumable)
                onChange?()
                return
            }
            downloadLog.error("transfer-failed ratingKey=\(entry.ratingKey, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) desc=\(error.localizedDescription, privacy: .public) bytesReceived=\(task.countOfBytesReceived, privacy: .public)")
            AppDiagnostics.record(.downloads, "downloads.transfer_failed", fields: [
                "download_id": .identifier(entry.ratingKey),
                "error": .error(error),
                "bytes_received": .bytes(Int(task.countOfBytesReceived)),
            ])
            clearRetryCount(ratingKey: entry.ratingKey)
            store.setStatus(ratingKey: entry.ratingKey, .failed)
            onError?(entry.ratingKey, .transferFailed(error.localizedDescription))
        } else {
            clearRetryCount(ratingKey: entry.ratingKey)
            downloadLog.info("cancelled ratingKey=\(entry.ratingKey, privacy: .public)")
            AppDiagnostics.record(.downloads, "downloads.cancelled", fields: [
                "download_id": .identifier(entry.ratingKey),
            ])
        }
        onChange?()
    }

    private func notifyProgressChangeIfNeeded(ratingKey: String, progress: Double) {
        let now = Date()
        lock.lock()
        let last = lastProgressNotify[ratingKey]
        let shouldNotify = (last.map { now.timeIntervalSince($0) >= progressNotifyInterval } ?? true)
            || progress >= 1.0
        if shouldNotify { lastProgressNotify[ratingKey] = now }
        lock.unlock()
        if shouldNotify { onChange?() }
    }

    private func clearRetryCount(ratingKey: String) {
        lock.lock()
        retryCounts.removeValue(forKey: ratingKey)
        lastProgressNotify.removeValue(forKey: ratingKey)
        lock.unlock()
    }

    /// Resume transient transfer drops before surfacing a failed row. Plex/static-file
    /// downloads can start successfully and then lose the TCP stream mid-body (`-1005`);
    /// URLSession gives us resume data in that case, so failing immediately throws away
    /// exactly the recovery mechanism the OS provides.
    private func retryTransientFailure(_ error: NSError,
                                       task: URLSessionTask,
                                       entry: (ratingKey: String, destination: URL)) -> Bool {
        guard error.domain == NSURLErrorDomain,
              Self.transientDownloadErrorCodes.contains(error.code),
              let resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
              !resumeData.isEmpty else { return false }
        // #95: JF/Emby optimized downloads are live transcode streams; do not offset-resume them
        // even if URLSession hands back a blob. Let the caller surface a restart-required failure
        // instead of silently trying a 200-full-restart/416-prone resume.
        guard store.supportsPersistedResumeData(ratingKey: entry.ratingKey) else { return false }

        lock.lock()
        let nextAttempt = (retryCounts[entry.ratingKey] ?? 0) + 1
        guard nextAttempt <= maxTransientRetries else {
            lock.unlock()
            return false
        }
        retryCounts[entry.ratingKey] = nextAttempt
        lock.unlock()

        let retryTask = urlSession.downloadTask(withResumeData: resumeData)
        retryTask.taskDescription = entry.ratingKey
        lock.lock()
        inflight[retryTask.taskIdentifier] = entry
        loggedProgressMilestones[retryTask.taskIdentifier] = []
        lock.unlock()
        downloadLog.error("transfer-retry ratingKey=\(entry.ratingKey, privacy: .public) attempt=\(nextAttempt, privacy: .public) code=\(error.code, privacy: .public) bytesReceived=\(task.countOfBytesReceived, privacy: .public)")
        AppDiagnostics.record(.downloads, "downloads.transfer_retry", fields: [
            "download_id": .identifier(entry.ratingKey),
            "attempt": .int(nextAttempt),
            "error": .error(error),
            "bytes_received": .bytes(Int(task.countOfBytesReceived)),
        ])
        retryTask.resume()
        onChange?()
        return true
    }

    private static let transientDownloadErrorCodes: Set<Int> = [
        NSURLErrorNetworkConnectionLost,
        NSURLErrorTimedOut,
        NSURLErrorCannotConnectToHost,
        NSURLErrorCannotFindHost,
        NSURLErrorDNSLookupFailed
    ]

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
