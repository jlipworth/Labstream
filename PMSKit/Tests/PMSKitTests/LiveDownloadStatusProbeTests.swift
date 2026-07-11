import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PMSKit

/// Read-only live Plex download/optimizer status probe. OPT-IN via PLEX_LIVE_* env vars.
///
/// Use this while the headset is running a download to correlate app diagnostics with server
/// truth: source part count, conversion-queue attribution, background transcode progress, the
/// app-created type-42 queue backlog, and /activities correlation. It never creates, reorders,
/// deletes, or downloads a job.
struct LiveDownloadStatusProbeTests {

    private struct LiveConfig {
        let base: LiveProbeConfig
        let metadataKey: String
        let ratingKey: String
        let mediaIndex: Int
        let partIndex: Int
        let polls: Int
        let intervalSeconds: Double
        var server: URL { base.server }
        var token: String { base.token }
        var identity: ClientIdentity { base.identity }

        init?() {
            let env = ProcessInfo.processInfo.environment
            guard let base = LiveProbeConfig(env, deviceName: "Labstream Live Status Probe"),
                  let metadataKey = env["PLEX_LIVE_METADATA_KEY"], !metadataKey.isEmpty
            else { return nil }
            self.base = base
            self.metadataKey = metadataKey
            self.ratingKey = (metadataKey as NSString).lastPathComponent
            self.mediaIndex = env["PLEX_LIVE_MEDIA_INDEX"].flatMap(Int.init) ?? 0
            self.partIndex = env["PLEX_LIVE_PART_INDEX"].flatMap(Int.init) ?? 0
            self.polls = max(1, env["PLEX_LIVE_POLLS"].flatMap(Int.init) ?? 1)
            self.intervalSeconds = max(0.5, env["PLEX_LIVE_POLL_INTERVAL_SECONDS"].flatMap(Double.init) ?? 5)
        }
    }

    private func request(_ cfg: LiveConfig, path: String, method: String = "GET",
                         query: [URLQueryItem] = []) -> PlexRequest {
        PlexRequest(url: cfg.server.appendingPathComponent(path),
                    method: method,
                    queryItems: query,
                    headers: PlexHeaders.standard(identity: cfg.identity, token: cfg.token))
    }

    private func send(_ req: PlexRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: req.urlRequest())
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw ProbeError.http(status)
        }
        return data
    }

    enum ProbeError: Error { case http(Int) }

    /// Returns true when the metadata endpoint was reachable + authorized (HTTP 2xx). `send`
    /// throws on non-2xx, so a thrown error here means the server is unreachable or the token is
    /// bad — the caller asserts on this so the probe fails loudly instead of printing and passing.
    @discardableResult
    private func printMetadata(_ cfg: LiveConfig) async -> Bool {
        do {
            let data = try await send(request(cfg, path: cfg.metadataKey))
            let response = try JSONDecoder().decode(MetadataResponse.self, from: data)
            guard let item = response.mediaContainer.metadata.first else {
                print(">>> DLSTAT metadata missing")
                return true
            }
            let media = item.media.flatMap { $0.indices.contains(cfg.mediaIndex) ? $0[cfg.mediaIndex] : nil }
            let part = media.flatMap { $0.part.indices.contains(cfg.partIndex) ? $0.part[cfg.partIndex] : nil }
            let allParts = (item.media ?? []).flatMap(\.part)
            let optimizedLike = allParts.filter { !["mkv", "unknown"].contains(OfflineDownloadDecision.containerLabel(part: $0)) }
            let partIDs = allParts.map { "\($0.id):\(OfflineDownloadDecision.containerLabel(part: $0))" }
                .joined(separator: ",")
            print("""
            >>> DLSTAT metadata parts=\(allParts.count) optimized_like_parts=\(optimizedLike.count) \
            selected_container=\(OfflineDownloadDecision.containerLabel(part: part)) \
            selected_size=\(part?.size.map(String.init) ?? "nil") part_ids=\(partIDs)
            """)
            return true
        } catch {
            print(">>> DLSTAT metadata error=\(error)")
            return false
        }
    }

    private func printConversionQueue(_ cfg: LiveConfig) async {
        do {
            let data = try await send(BackgroundQueueRequest.conversionQueueRequest(
                server: cfg.server, token: cfg.token, identity: cfg.identity))
            let queue = try JSONDecoder().decode(ConversionQueue.self, from: data)
            let activeRatingKey = queue.activeItem?.ratingKey
            let inQueue = queue.items.contains { $0.ratingKey == cfg.ratingKey }
            let attribution: String
            if activeRatingKey == cfg.ratingKey {
                attribution = "active"
            } else if inQueue {
                attribution = "queued"
            } else {
                attribution = "none"
            }
            print("""
            >>> DLSTAT conversion count=\(queue.count) active_present=\(queue.hasActiveConversion) \
            active_match=\(activeRatingKey == cfg.ratingKey) attribution=\(attribution)
            """)
        } catch {
            print(">>> DLSTAT conversion error=\(error)")
        }
    }

    private func printBackgroundJobs(_ cfg: LiveConfig) async {
        do {
            let data = try await send(BackgroundQueueRequest.transcodeJobsRequest(
                server: cfg.server, token: cfg.token, identity: cfg.identity))
            let jobs = try JSONDecoder().decode(BackgroundTranscodeJobs.self, from: data)
            let progress = jobs.firstProgress.map(String.init) ?? "nil"
            let speed = jobs.firstSpeed.map { String($0) } ?? "nil"
            let state = jobs.firstState ?? "nil"
            print("""
            >>> DLSTAT background jobs=\(jobs.jobs.count) \
            progress=\(progress) \
            speed=\(speed) \
            state=\(state)
            """)
        } catch {
            print(">>> DLSTAT background error=\(error)")
        }
    }

    private func printActivities(_ cfg: LiveConfig) async {
        do {
            let data = try await send(ActivitiesRequest.list(server: cfg.server,
                                                             token: cfg.token,
                                                             identity: cfg.identity))
            let activities = try JSONDecoder().decode(Activities.self, from: data)
            let shape = activities.probeShape(ratingKey: cfg.ratingKey, title: nil,
                                              allowSoleFallback: false)
            print("""
            >>> DLSTAT activities count=\(shape["activity_count"] ?? "0") \
            optimize_count=\(shape["optimize_count"] ?? "0") \
            matched=\(shape["matched"] ?? "none") \
            types=\(shape["types"] ?? "")
            """)
        } catch {
            print(">>> DLSTAT activities error=\(error)")
        }
    }

    private func printType42Queue(_ cfg: LiveConfig) async {
        do {
            let playlistData = try await send(OptimizeRequest.backgroundProcessingRequest(
                server: cfg.server, token: cfg.token, identity: cfg.identity))
            let playlist = try JSONDecoder().decode(BackgroundProcessingPlaylist.self, from: playlistData)
            guard let key = playlist.key else {
                print(">>> DLSTAT type42 key=nil")
                return
            }
            let data = try await send(request(cfg, path: key))
            let queue = try JSONDecoder().decode(BackgroundProcessingItems.self, from: data)
            let rawRoot = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let rawContainer = rawRoot?["MediaContainer"] as? [String: Any]
            let rawItems = rawContainer?["Item"] as? [[String: Any]] ?? []
            let itemKeys = Set(rawItems.flatMap { $0.keys })
            let statusKeys = Set(rawItems.compactMap { $0["Status"] as? [String: Any] }
                .flatMap { $0.keys })
            let nestedKeySummary = ["Device", "Location", "MediaSettings", "Policy", "target"]
                .map { name -> String in
                    let keys = Set(rawItems.compactMap { $0[name] as? [String: Any] }
                        .flatMap { $0.keys })
                    return "\(name)=\(keys.sorted().joined(separator: "+"))"
                }.joined(separator: ";")
            let sourceMatches = rawItems.filter { raw in
                let location = raw["Location"] as? [String: Any]
                let uri = location?["uri"] as? String
                return uri?.contains("/metadata/\(cfg.ratingKey)") == true
                    || uri?.contains("%2Fmetadata%2F\(cfg.ratingKey)") == true
            }
            let sourceMatchMarked = sourceMatches.filter {
                ($0["title"] as? String)?.contains("[Labstream ") == true
            }.count
            let sourceMatchCompleted = sourceMatches.filter {
                let state = (($0["Status"] as? [String: Any])?["state"] as? String)?.lowercased()
                return state.map(BackgroundProcessingItems.completedStates.contains) == true
            }.count
            let states = Dictionary(grouping: queue.items) { item in
                item.state?.lowercased() ?? "missing"
            }.mapValues { $0.count }
            let stateSummary = states.keys.sorted().map { "\($0):\(states[$0]!)" }.joined(separator: ",")
            let markedStates = Dictionary(grouping: queue.items.filter {
                $0.title?.contains("[Labstream ") == true
            }) { item in item.state?.lowercased() ?? "missing" }.mapValues { $0.count }
            let markedStateSummary = markedStates.keys.sorted()
                .map { "\($0):\(markedStates[$0]!)" }.joined(separator: ",")
            print("""
            >>> DLSTAT type42 items=\(queue.items.count) labstream_marked=\(queue.markedCount(marker: "[Labstream ")) \
            pending=\(queue.pendingCount) states=\(stateSummary) marked_states=\(markedStateSummary) \
            item_keys=\(itemKeys.sorted().joined(separator: ",")) \
            status_keys=\(statusKeys.sorted().joined(separator: ",")) \
            nested_keys=\(nestedKeySummary) source_matches=\(sourceMatches.count) \
            source_match_marked=\(sourceMatchMarked) source_match_completed=\(sourceMatchCompleted)
            """)
        } catch {
            print(">>> DLSTAT type42 error=\(error)")
        }
    }

    @Test func liveDownloadStatusProbe() async throws {
        guard let cfg = LiveConfig() else {
            print(">>> DLSTAT skipped: set PLEX_LIVE_SERVER / PLEX_LIVE_TOKEN / PLEX_LIVE_METADATA_KEY to run.")
            return
        }

        for i in 0..<cfg.polls {
            print(">>> DLSTAT poll=\(i + 1)/\(cfg.polls) ratingKey=\(cfg.ratingKey)")
            let metadataOK = await printMetadata(cfg)
            // Fail loudly if the server is unreachable / the token is bad, instead of printing
            // per-section errors and reporting the whole probe green.
            if i == 0 {
                #expect(metadataOK, "DLSTAT first metadata fetch should succeed (server reachable + authorized)")
            }
            await printConversionQueue(cfg)
            await printBackgroundJobs(cfg)
            await printActivities(cfg)
            await printType42Queue(cfg)
            if i + 1 < cfg.polls {
                try? await Task.sleep(nanoseconds: UInt64(cfg.intervalSeconds * 1_000_000_000))
            }
        }
    }
}
