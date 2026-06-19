import Testing
import Foundation
@testable import PMSKit

/// Read-only live Plex download/optimizer status probe. OPT-IN via PLEX_LIVE_* env vars.
///
/// Use this while the headset is running a download to correlate app diagnostics with server
/// truth: source part count, conversion-queue attribution, background transcode progress, the
/// app-created type-42 queue backlog, and /activities correlation. It never creates, reorders,
/// deletes, or downloads a job.
struct LiveDownloadStatusProbeTests {

    private struct LiveConfig {
        let server: URL
        let token: String
        let metadataKey: String
        let ratingKey: String
        let mediaIndex: Int
        let partIndex: Int
        let polls: Int
        let intervalSeconds: Double
        let identity: ClientIdentity

        init?() {
            let env = ProcessInfo.processInfo.environment
            guard let serverString = env["PLEX_LIVE_SERVER"], let server = URL(string: serverString),
                  let token = env["PLEX_LIVE_TOKEN"], !token.isEmpty,
                  let metadataKey = env["PLEX_LIVE_METADATA_KEY"], !metadataKey.isEmpty
            else { return nil }
            self.server = server
            self.token = token
            self.metadataKey = metadataKey
            self.ratingKey = (metadataKey as NSString).lastPathComponent
            self.mediaIndex = env["PLEX_LIVE_MEDIA_INDEX"].flatMap(Int.init) ?? 0
            self.partIndex = env["PLEX_LIVE_PART_INDEX"].flatMap(Int.init) ?? 0
            self.polls = max(1, env["PLEX_LIVE_POLLS"].flatMap(Int.init) ?? 1)
            self.intervalSeconds = max(0.5, env["PLEX_LIVE_POLL_INTERVAL_SECONDS"].flatMap(Double.init) ?? 5)
            self.identity = ClientIdentity(
                clientIdentifier: env["PLEX_LIVE_CLIENT_ID"] ?? "visionplay-live-probe",
                product: "VisionPlay",
                version: "0.1.0",
                deviceName: "VisionPlay Live Status Probe")
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

    private func printMetadata(_ cfg: LiveConfig) async {
        do {
            let data = try await send(request(cfg, path: cfg.metadataKey))
            let response = try JSONDecoder().decode(MetadataResponse.self, from: data)
            guard let item = response.mediaContainer.metadata.first else {
                print(">>> DLSTAT metadata missing")
                return
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
        } catch {
            print(">>> DLSTAT metadata error=\(error)")
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
            print("""
            >>> DLSTAT type42 items=\(queue.items.count) visionplay_marked=\(queue.markedCount(marker: "[VisionPlay ")) \
            pending=\(queue.pendingCount)
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
            await printMetadata(cfg)
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
