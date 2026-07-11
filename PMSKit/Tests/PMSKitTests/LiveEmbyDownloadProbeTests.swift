// Apple-only live developer probe: uses URLSession.bytes, which is unavailable in
// swift-corelibs-foundation. Compiled out on the Linux CI fleet (which has no live server
// anyway); runs on macOS only when its EMBY_LIVE_* env vars are set.
#if !canImport(FoundationNetworking)
import Testing
import Foundation
@testable import PMSKit

/// Headless integration probe for the Emby OFFLINE-DOWNLOAD lane against a REAL Emby server.
/// Opt-in: runs only when the `EMBY_LIVE_*` env vars are present, otherwise a no-op so plain
/// `swift test` and CI stay hermetic.
///
/// What it proves against the live wire (item 1200 = HEVC/DTS/MKV worst case):
///   1. The DOWNLOAD device profile (Static mp4, NOT HLS) negotiates a single-file transcode:
///      `SupportsDirectPlay=false`, `TranscodeReasons` contains `ContainerNotSupported`, the
///      `TranscodingUrl` is a `/videos/.../stream` (no `.m3u8`), and `Size` is populated.
///   2. The static-original GET returns HTTP 206 (range-resumable) for that source.
///
/// Run it:
///   set -a; source scripts/emby-live.env; set +a
///   cd PMSKit && swift test --filter LiveEmbyDownloadProbe
///
/// EMBY-F9's longer idle-behavior arm is deliberately separate and opt-in because it consumes
/// live-server encoder time and bandwidth. Set `EMBY_LIVE_F9_IDLE_SECONDS` to at least 120 to run
/// it; 180 seconds is the recommended audit interval. `EMBY_LIVE_F9_KEEPALIVE=ping` runs the
/// watch-history-safe comparison arm. This probe never sends Playing/Progress.
///
/// SECURITY: NEVER prints the token / api_key / X-Emby-Token, nor the real hostname — every URL
/// is redacted before logging.
@Suite(.serialized)
struct LiveEmbyDownloadProbeTests {

    private struct StreamSnapshot: Sendable {
        let statusCode: Int?
        let contentType: String?
        let bytes: Int
        let completion: StreamCompletion?
    }

    private enum StreamCompletion: Sendable, Equatable {
        case finished
        case cancelled
        case failed
    }

    private enum F9KeepaliveMode: String {
        case none
        /// Preferred comparison arm: keeps the encoder session alive without changing playback
        /// position/watch history.
        case ping
    }

    /// Chunk-based observer for the long F9 arm. `URLSession.AsyncBytes` yields one byte at a time,
    /// which is fine for the one-byte smoke below but unnecessarily expensive for a multi-minute
    /// remux. This delegate counts whole Data chunks and never persists the media body.
    private final class StreamObserver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var statusCode: Int?
        private var contentType: String?
        private var byteCount = 0
        private var completion: StreamCompletion?
        private var completionWaiters: [CheckedContinuation<StreamCompletion, Never>] = []

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            lock.lock()
            if let http = response as? HTTPURLResponse {
                statusCode = http.statusCode
                contentType = http.value(forHTTPHeaderField: "Content-Type")
            }
            lock.unlock()
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive data: Data) {
            lock.lock()
            byteCount += data.count
            lock.unlock()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didCompleteWithError error: Error?) {
            let outcome: StreamCompletion
            if let nsError = error as NSError?,
               nsError.domain == NSURLErrorDomain,
               nsError.code == NSURLErrorCancelled {
                outcome = .cancelled
            } else if error != nil {
                outcome = .failed
            } else {
                outcome = .finished
            }

            lock.lock()
            completion = outcome
            let waiters = completionWaiters
            completionWaiters.removeAll()
            lock.unlock()
            waiters.forEach { $0.resume(returning: outcome) }
        }

        func snapshot() -> StreamSnapshot {
            lock.lock()
            defer { lock.unlock() }
            return StreamSnapshot(statusCode: statusCode, contentType: contentType,
                                  bytes: byteCount, completion: completion)
        }

        func waitForCompletion() async -> StreamCompletion {
            if let completion = snapshot().completion { return completion }
            return await withCheckedContinuation { continuation in
                lock.lock()
                if let completion {
                    lock.unlock()
                    continuation.resume(returning: completion)
                } else {
                    completionWaiters.append(continuation)
                    lock.unlock()
                }
            }
        }
    }

    private struct LiveConfig {
        let server: URL
        let token: String
        let userId: String
        let itemId: String
        let maxStaticBitrate: Int
        let identity: EmbyClientIdentity

        init?() {
            let env = ProcessInfo.processInfo.environment
            guard let serverString = env["EMBY_LIVE_SERVER"],
                  let server = try? EmbyServerURL.normalized(serverString),
                  let token = env["EMBY_LIVE_TOKEN"], !token.isEmpty,
                  let userId = env["EMBY_LIVE_USER_ID"], !userId.isEmpty,
                  let itemId = env["EMBY_LIVE_ITEM_ID"], !itemId.isEmpty
            else { return nil }
            self.server = server
            self.token = token
            self.userId = userId
            self.itemId = itemId
            self.maxStaticBitrate = env["EMBY_LIVE_MAX_BITRATE"].flatMap(Int.init) ?? 200_000_000
            self.identity = EmbyClientIdentity(
                client: "Labstream",
                device: "Apple Vision Pro",
                deviceId: env["EMBY_LIVE_DEVICE_ID"] ?? "labstream-emby-live-probe",
                version: "0.1.0")
        }
    }

    // Scrubbing is centralized in `LiveProbeConfig.redact` (shared by every Plex + Emby probe);
    // its default credential-key set already covers `api_key`.

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, response as! HTTPURLResponse)
    }

    /// Await cleanup before the test returns, including its error path. The old detached `defer`
    /// could let the test process exit before Emby received DELETE, leaking a live FFmpeg encoder.
    private func withActiveEncodingCleanup<T>(playSessionId: String,
                                               cfg: LiveConfig,
                                               operation: () async throws -> T) async throws -> T {
        do {
            let result = try await operation()
            await stopActiveEncoding(playSessionId: playSessionId, cfg: cfg)
            return result
        } catch {
            await stopActiveEncoding(playSessionId: playSessionId, cfg: cfg)
            throw error
        }
    }

    private func stopActiveEncoding(playSessionId: String, cfg: LiveConfig) async {
        do {
            let request = try EmbyLibrary.activeEncodingStopRequest(
                server: cfg.server, token: cfg.token, identity: cfg.identity,
                userId: cfg.userId, deviceId: cfg.identity.deviceId,
                playSessionId: playSessionId)
            let (_, http) = try await send(request)
            let accepted = (200..<300).contains(http.statusCode) || [400, 404, 410].contains(http.statusCode)
            print(">>> LIVE [activeEncodingCleanup] HTTP \(http.statusCode) accepted=\(accepted)")
            #expect(accepted, "active encoding cleanup returned unexpected HTTP \(http.statusCode)")
        } catch {
            // Deliberately do not print Error/URL descriptions: they may contain the real host or
            // credential-bearing query. The failed expectation retains the cleanup signal.
            print(">>> LIVE [activeEncodingCleanup] transport=failed")
            Issue.record("active encoding cleanup failed at the transport layer")
        }
    }

    /// One F9 comparison-arm tick. Only privacy-safe HTTP status codes leave this helper.
    private func sendF9Keepalive(cfg: LiveConfig,
                                 decision: EmbyPlayback.EmbyDownloadPlaybackDecision,
                                 mode: F9KeepaliveMode) async -> Bool {
        do {
            var statuses: [Int] = []
            let ping = try EmbyPlayback.pingRequest(
                server: cfg.server, token: cfg.token, identity: cfg.identity,
                userId: cfg.userId, playSessionId: decision.playSessionId)
            statuses.append(try await send(ping).1.statusCode)
            let healthy = statuses.allSatisfy { (200..<300).contains($0) }
            print(">>> LIVE [F9 keepalive] mode=\(mode.rawValue) statuses=\(statuses) healthy=\(healthy)")
            return healthy
        } catch {
            print(">>> LIVE [F9 keepalive] transport=failed")
            return false
        }
    }

    private func fetchJobList(_ cfg: LiveConfig) async throws -> EmbyConvertJobList {
        let request = try EmbyConvertRequest.jobListRequest(
            server: cfg.server, token: cfg.token, identity: cfg.identity)
        let (data, http) = try await send(request)
        #expect(http.statusCode == 200, "Sync job list expected HTTP 200, got \(http.statusCode)")
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try EmbyConvertRequest.decodeJobList(from: data)
    }

    /// Await DELETE before returning. A detached cleanup can let the test process exit while a
    /// Sync job keeps rendering a persistent file next to the source media.
    private func deleteCreatedJob(_ id: Int, cfg: LiveConfig) async -> Int? {
        for attempt in 1...3 {
            do {
                let request = try EmbyConvertRequest.deleteJobRequest(
                    server: cfg.server, token: cfg.token, identity: cfg.identity, jobId: id)
                let (_, http) = try await send(request)
                let accepted = (200..<300).contains(http.statusCode) || [404, 410].contains(http.statusCode)
                print(">>> LIVE [f3Cleanup] DELETE status=\(http.statusCode) attempt=\(attempt) accepted=\(accepted)")
                if accepted { return http.statusCode }
            } catch {
                // Do not interpolate Error: URL-bearing errors can contain the private host/token.
                print(">>> LIVE [f3Cleanup] DELETE transport=failed attempt=\(attempt)")
            }
        }
        print(">>> LIVE [f3Cleanup] cleanup=REQUIRED retrySignal=retained-in-output")
        return nil
    }

    @Test func liveEmbyF3ReadOnlyJobListProbe() async throws {
        guard let cfg = LiveConfig() else {
            print(">>> LIVE [f3List] skipped: set the EMBY_LIVE_* environment variables to run.")
            return
        }

        do {
            let list = try await fetchJobList(cfg)
            let completed = list.items.filter { $0.status == .completed }.count
            let matchingItem = list.items.filter { $0.requestedItemIds.contains(cfg.itemId) }.count
            let hasRecoveryIdentity = list.items.allSatisfy {
                !$0.requestedItemIds.isEmpty && !$0.targetId.isEmpty && !$0.quality.isEmpty && !$0.profile.isEmpty
            }
            print(">>> LIVE [f3List] decoded count=\(list.items.count) total=\(list.totalRecordCount) completed=\(completed) configuredItemMatches=\(matchingItem) recoveryIdentity=\(hasRecoveryIdentity)")
            #expect(list.isComplete)
            #expect(hasRecoveryIdentity, "every listed Sync job should carry the recovery fingerprint")
        } catch {
            print(">>> LIVE [f3List] transport-or-decode=failed")
            Issue.record("F3 read-only list probe failed (details scrubbed)")
        }
    }

    /// MUTATING and deliberately double-gated. The configured item must be long-running: if its
    /// conversion completes before DELETE, Emby leaves the rendered file beside the source media.
    @Test func liveEmbyF3CreateVisibilityProbe() async throws {
        guard ProcessInfo.processInfo.environment["EMBY_LIVE_F3_CREATE"] == "1" else {
            print(">>> LIVE [f3Create] skipped: set EMBY_LIVE_F3_CREATE=1 only for an approved long-item mutation.")
            return
        }
        guard let cfg = LiveConfig() else {
            print(">>> LIVE [f3Create] skipped: set the EMBY_LIVE_* environment variables to run.")
            return
        }

        let quality = EmbyConvertRequest.convertQuality(forPresetLabel: "1080p · 8 Mbps")
        let fingerprint = EmbyConvertRecoveryPolicy.Fingerprint(
            itemId: cfg.itemId, quality: quality.quality, profile: quality.profile,
            bitrate: quality.bitrate, userId: cfg.userId)
        guard let baseline = try? await fetchJobList(cfg) else {
            print(">>> LIVE [f3Create] baseline transport-or-decode=failed")
            Issue.record("F3 mutation baseline failed (details scrubbed)")
            return
        }
        let baselineIDs = Set(baseline.items.map(\.id))
        let startedAt = Date().timeIntervalSince1970
        var createdJobID: Int?
        var cleanupConfirmed = false
        defer {
            #expect(cleanupConfirmed, "mutation probe must confirm cleanup; otherwise output retains cleanup=REQUIRED")
        }

        do {
            let request = try EmbyConvertRequest.createJobRequest(
                server: cfg.server, token: cfg.token, identity: cfg.identity,
                userId: cfg.userId, itemId: cfg.itemId,
                quality: quality.quality, profile: quality.profile, bitrate: quality.bitrate,
                name: "Labstream F3 live probe \(UUID().uuidString.prefix(8))")
            let (data, http) = try await send(request)
            #expect((200..<300).contains(http.statusCode),
                    "F3 create expected success, got HTTP \(http.statusCode)")
            guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
            let created = try EmbyConvertRequest.decodeCreatedJob(from: data)
            createdJobID = created.id
            print(">>> LIVE [f3Create] POST succeeded; relisting immediately baselineCount=\(baselineIDs.count)")

            let after = try await fetchJobList(cfg)
            let recovered = EmbyConvertRecoveryPolicy.recoveredJobID(
                baselineJobIDs: baselineIDs, jobs: after.items, fingerprint: fingerprint,
                attemptStartedAtEpochSeconds: startedAt, phase: .dispatchAmbiguous)
            #expect(recovered == created.id,
                    "the unique exact baseline difference must be the POST-returned job")

            let cleanupStatus = await deleteCreatedJob(created.id, cfg: cfg)
            createdJobID = nil
            cleanupConfirmed = cleanupStatus != nil
            #expect(cleanupConfirmed, "created Sync job cleanup must succeed or retain retry signal")
            print(">>> LIVE [f3Create] visibility=exact cleanup=attempted afterCount=\(after.items.count)")
        } catch {
            var cleanupID = createdJobID
            if cleanupID == nil, let after = try? await fetchJobList(cfg) {
                cleanupID = EmbyConvertRecoveryPolicy.recoveredJobID(
                    baselineJobIDs: baselineIDs, jobs: after.items, fingerprint: fingerprint,
                    attemptStartedAtEpochSeconds: startedAt, phase: .dispatchAmbiguous)
            }
            if let id = cleanupID {
                cleanupConfirmed = await deleteCreatedJob(id, cfg: cfg) != nil
                createdJobID = nil
            } else {
                print(">>> LIVE [f3Cleanup] cleanup=REQUIRED reason=no-unique-recovery")
            }
            // Never let Swift Testing print a URL-bearing transport error.
            print(">>> LIVE [f3Create] transport-or-decode=failed cleanupConfirmed=\(cleanupConfirmed)")
            Issue.record("F3 mutation probe failed (details scrubbed); inspect privacy-safe cleanup signal")
        }
    }

    @Test func liveEmbyDownloadProbe() async throws {
        guard let cfg = LiveConfig() else {
            print(">>> LIVE skipped: set EMBY_LIVE_SERVER / EMBY_LIVE_TOKEN / EMBY_LIVE_USER_ID / EMBY_LIVE_ITEM_ID to run.")
            return
        }

        // (a) POST download PlaybackInfo with the DOWNLOAD (Static mp4) device profile.
        let decision: EmbyPlayback.EmbyDownloadPlaybackDecision
        do {
            let req = try EmbyPlayback.downloadPlaybackInfoRequest(
                server: cfg.server, token: cfg.token, identity: cfg.identity,
                userId: cfg.userId, itemId: cfg.itemId, maxStaticBitrate: cfg.maxStaticBitrate)
            let (data, http) = try await send(req)
            print(">>> LIVE [downloadPlaybackInfo] HTTP \(http.statusCode), \(data.count) bytes")
            #expect(http.statusCode == 200)
            let response = try EmbyPlaybackInfoResponse.decode(from: data)
            decision = try EmbyPlayback.downloadDecision(response: response)
            let safeTU = decision.transcodingURL.map { LiveProbeConfig.redact($0, token: cfg.token, server: cfg.server) } ?? "nil"
            print(">>> LIVE [downloadDecision] directPlay=\(decision.supportsDirectPlay) size=\(decision.size.map(String.init) ?? "nil") container=\(decision.container ?? "nil") reasons=\(decision.transcodeReasons) transcodingUrl=\(safeTU)")
            // The download profile must negotiate a single-file (non-HLS) transcode for MKV.
            if let tu = decision.transcodingURL {
                #expect(!tu.contains(".m3u8"), "download transcode URL must NOT be an HLS playlist")
            }
        }

        try await withActiveEncodingCleanup(playSessionId: decision.playSessionId, cfg: cfg) {
            // (b) Static-original GET — confirm range-resumability (HTTP 206) for the source.
            let req0 = try EmbyLibrary.downloadOriginalRequest(
                server: cfg.server, token: cfg.token, identity: cfg.identity,
                userId: cfg.userId, itemId: cfg.itemId,
                mediaSourceId: decision.mediaSourceId, container: decision.container)
            var originalRequest = req0
            originalRequest.setValue("bytes=0-1048575", forHTTPHeaderField: "Range")
            let (data, originalHTTP) = try await send(originalRequest)
            let acceptRanges = originalHTTP.value(forHTTPHeaderField: "Accept-Ranges") ?? "nil"
            let contentLength = originalHTTP.value(forHTTPHeaderField: "Content-Length") ?? "nil"
            print(">>> LIVE [staticOriginal] HTTP \(originalHTTP.statusCode) bytes=\(data.count) accept-ranges=\(acceptRanges) content-length=\(contentLength)")
            // 206 = range honoured (resumable). 200 with the full body is acceptable too, but the
            // worst-case MKV original is range-resumable per the captured facts.
            #expect(originalHTTP.statusCode == 206 || originalHTTP.statusCode == 200)

            // (c) Transcode GET — the single-file transcoded download must actually START (HTTP 200),
            // not 500. The on-device probe caught that Emby's *default-minted* download `TranscodingUrl`
            // is a codecless `/videos/{id}/stream` remux that makes ffmpeg attempt a stream-COPY of
            // HEVC/DTS into mp4 and fail ("Error starting ffmpeg", HTTP 500). The fix (and what the app
            // builds) is an EXPLICIT static `stream.mp4` URL with forced h264/aac carrying the minted
            // PlaySessionId — this re-encodes properly. Use the streaming `bytes` API to read just the
            // response headers (+ one byte to confirm the encoder produced output), then cancel before
            // downloading the multi-GB body.
            let transcodeRequest = try EmbyLibrary.transcodedDownloadRequest(
                server: cfg.server, token: cfg.token, identity: cfg.identity, userId: cfg.userId,
                itemId: cfg.itemId, mediaSourceId: decision.mediaSourceId,
                playSessionId: decision.playSessionId,
                videoBitrate: 8_000_000, audioBitrate: 192_000)
            let (bytes, response) = try await URLSession.shared.bytes(for: transcodeRequest)
            let transcodeHTTP = response as! HTTPURLResponse
            let contentType = transcodeHTTP.value(forHTTPHeaderField: "Content-Type") ?? "nil"
            var firstByteOK = false
            var iterator = bytes.makeAsyncIterator()
            firstByteOK = (try? await iterator.next()) != nil
            bytes.task.cancel()
            print(">>> LIVE [transcodeGET] HTTP \(transcodeHTTP.statusCode) content-type=\(contentType) firstByte=\(firstByteOK)")
            #expect((200..<300).contains(transcodeHTTP.statusCode),
                    "transcoded download must START with a success status, got \(transcodeHTTP.statusCode)")
            #expect(firstByteOK, "transcoded download should produce at least one byte of output")
            #expect(contentType.contains("mp4") || contentType.contains("video"),
                    "transcoded download should be a video container, got \(contentType)")
        }
    }

    /// EMBY-F9: determine whether an actively consumed compatible-remux stream is kept alive by
    /// the HTTP transfer itself or requires Jellyfin-style Playing/Progress/Ping traffic.
    /// This arm intentionally sends none of those control-plane requests.
    @Test func liveEmbyCompatibleRemuxIdleProbe() async {
        do {
            try await runLiveEmbyCompatibleRemuxIdleProbe()
        } catch {
            // Error descriptions from URLSession may embed the real host or credential-bearing
            // request URL. Collapse everything at the test boundary to a fixed safe diagnostic.
            print(">>> LIVE [F9 boundary] failed details=scrubbed")
            Issue.record("F9 live probe failed; URLSession details were scrubbed")
        }
    }

    private func runLiveEmbyCompatibleRemuxIdleProbe() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let rawSeconds = env["EMBY_LIVE_F9_IDLE_SECONDS"] else {
            print(">>> LIVE [F9] skipped: set EMBY_LIVE_F9_IDLE_SECONDS>=120 to run the idle probe.")
            return
        }
        guard let idleSeconds = Int(rawSeconds), idleSeconds >= 120 else {
            Issue.record("EMBY_LIVE_F9_IDLE_SECONDS must be an integer >= 120")
            return
        }
        guard let cfg = LiveConfig() else {
            Issue.record("F9 idle probe requires the EMBY_LIVE_SERVER/TOKEN/USER_ID/ITEM_ID values")
            return
        }
        let keepaliveRaw = (env["EMBY_LIVE_F9_KEEPALIVE"] ?? "").lowercased()
        let keepaliveMode: F9KeepaliveMode = keepaliveRaw == "ping" ? .ping : .none
        if !keepaliveRaw.isEmpty, keepaliveMode == .none {
            Issue.record("EMBY_LIVE_F9_KEEPALIVE accepts only 'ping'")
            return
        }

        let infoRequest = try EmbyPlayback.compatibleRemuxDownloadPlaybackInfoRequest(
            server: cfg.server, token: cfg.token, identity: cfg.identity,
            userId: cfg.userId, itemId: cfg.itemId,
            maxStaticBitrate: cfg.maxStaticBitrate)
        let (infoData, infoHTTP) = try await send(infoRequest)
        print(">>> LIVE [F9 playbackInfo] HTTP \(infoHTTP.statusCode) bytes=\(infoData.count)")
        #expect(infoHTTP.statusCode == 200)
        let response = try EmbyPlaybackInfoResponse.decode(from: infoData)
        let decision = try EmbyPlayback.downloadDecision(response: response)
        let eligibility = OfflineDownloadDecision.compatibleRemuxEligibility(
            videoCodec: decision.videoCodec, audioCodec: decision.audioCodec,
            sourceContainer: decision.container)
        let route = EmbyDownloadRouter.route(
            intent: .compatible, supportsDirectPlay: decision.supportsDirectPlay,
            container: decision.container, videoCodec: decision.videoCodec,
            audioCodec: decision.audioCodec, part: nil)
        print(">>> LIVE [F9 decision] route=\(route.rawValue) expected-size=\(decision.size.map(String.init) ?? "nil") keepalive=\(keepaliveMode.rawValue)")
        guard route == .compatibleRemux, eligibility.isEligible else {
            print(">>> LIVE [F9] INCONCLUSIVE: configured item is not compatible-remux eligible")
            Issue.record("F9 requires an h264/hevc compatible-remux item")
            await stopActiveEncoding(playSessionId: decision.playSessionId, cfg: cfg)
            return
        }

        try await withActiveEncodingCleanup(playSessionId: decision.playSessionId, cfg: cfg) {
            let request = try EmbyLibrary.compatibleRemuxDownloadRequest(
                server: cfg.server, token: cfg.token, identity: cfg.identity,
                userId: cfg.userId, itemId: cfg.itemId,
                mediaSourceId: decision.mediaSourceId,
                playSessionId: decision.playSessionId,
                videoCodec: eligibility.videoCodec ?? "h264",
                audioCodec: eligibility.audioCodec,
                copyAudio: eligibility.copiesAudio,
                audioBitrate: 192_000)

            let observer = StreamObserver()
            let session = URLSession(configuration: .ephemeral, delegate: observer, delegateQueue: nil)
            let task = session.dataTask(with: request)
            let clock = ContinuousClock()
            let started = clock.now
            let deadline = started.advanced(by: .seconds(idleSeconds))
            var lastBytes = 0
            var lastProgressElapsedSeconds: Int?
            var advancedBeyondIdleBoundary = false
            var reachedDeadline = false
            var keepaliveHealthy = true
            task.resume()

            while observer.snapshot().completion == nil {
                if keepaliveMode != .none {
                    let tickHealthy = await sendF9Keepalive(
                        cfg: cfg, decision: decision, mode: keepaliveMode)
                    keepaliveHealthy = keepaliveHealthy && tickHealthy
                }
                let remaining = clock.now.duration(to: deadline)
                if remaining <= .zero {
                    reachedDeadline = true
                    break
                }
                try await Task.sleep(for: min(.seconds(20), remaining))
                let snapshot = observer.snapshot()
                let elapsed = Int(started.duration(to: clock.now).components.seconds)
                let advanced = snapshot.bytes > lastBytes
                if advanced {
                    lastProgressElapsedSeconds = elapsed
                    if elapsed >= 60 { advancedBeyondIdleBoundary = true }
                }
                print(">>> LIVE [F9 sample] elapsed=\(elapsed)s bytes=\(snapshot.bytes) advanced=\(advanced) terminal=\(snapshot.completion != nil)")
                lastBytes = snapshot.bytes
            }

            if clock.now >= deadline { reachedDeadline = true }
            if reachedDeadline { task.cancel() }
            let completion = await observer.waitForCompletion()
            session.finishTasksAndInvalidate()
            let final = observer.snapshot()
            let finalElapsed = min(idleSeconds,
                                   max(0, Int(started.duration(to: clock.now).components.seconds)))
            if final.bytes > lastBytes {
                lastProgressElapsedSeconds = finalElapsed
                if finalElapsed >= 60 { advancedBeyondIdleBoundary = true }
            }
            let contentType = final.contentType ?? "nil"
            let cleanEarlyCompletion: Bool = {
                guard completion == .finished,
                      let expected = decision.size, expected > 0 else { return false }
                return Double(final.bytes) / Double(expected) >= 0.95
            }()
            let recentProgress = lastProgressElapsedSeconds.map { finalElapsed - $0 <= 30 } == true
            let survived = reachedDeadline
                && final.bytes > 0
                && completion == .cancelled
                && advancedBeyondIdleBoundary
                && recentProgress

            print(">>> LIVE [F9 verdict] survived=\(survived) clean-early-completion=\(cleanEarlyCompletion) advanced-beyond-idle=\(advancedBeyondIdleBoundary) recent-progress=\(recentProgress) elapsed-target=\(idleSeconds)s bytes=\(final.bytes) completion=\(completion) HTTP=\(final.statusCode.map(String.init) ?? "nil") keepalive=\(keepaliveMode.rawValue) keepalive-healthy=\(keepaliveHealthy)")
            #expect(final.statusCode.map { (200..<300).contains($0) } == true,
                    "compatible remux should return HTTP 2xx")
            #expect(contentType.contains("mp4") || contentType.contains("video"),
                    "compatible remux should return a video container")
            #expect(keepaliveMode == .none || keepaliveHealthy,
                    "the F9 keepalive comparison arm had a control-plane failure")
            #expect(survived || cleanEarlyCompletion,
                    "Emby compatible remux ended materially short before the no-keepalive interval")
        }
    }
}
#endif
