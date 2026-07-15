import Foundation
import Testing
@testable import PMSKit

@Suite("Download row display policy")
struct DownloadRowDisplayPolicyTests {
    @Test("Route badge follows artifact provenance across server-prep handoff and terminal states")
    func routeBadgeTransition() {
        #expect(DownloadRowDisplayPolicy.routeBadge(
            lane: .optimize, isServerPreparedVersion: false) == .transcode)
        #expect(DownloadRowDisplayPolicy.routeBadge(
            lane: .original, isServerPreparedVersion: true) == .optimized)
        #expect(DownloadRowDisplayPolicy.routeBadge(
            lane: .original, isServerPreparedVersion: false) == .original)
        #expect(DownloadRowDisplayPolicy.routeBadge(
            lane: .compatibleRemux, isServerPreparedVersion: false) == .remux)

        // Jellyfin's optimized download remains a live-forward encoder stream; completion changes
        // durable status, not the route that produced the artifact.
        for status in [DownloadStatus.queued, .downloading, .paused, .complete, .unverified, .failed] {
            #expect(DownloadRowDisplayPolicy.routeBadge(for: routeRecord(
                status: status, lane: .optimize, serverPrepared: false)) == .transcode)
        }
        // A handed-off Plex/Emby static artifact remains Optimized across the same lifecycle.
        for status in [DownloadStatus.queued, .downloading, .paused, .complete, .unverified, .failed] {
            #expect(DownloadRowDisplayPolicy.routeBadge(for: routeRecord(
                status: status, lane: .original, serverPrepared: true)) == .optimized)
        }
    }

    @Test("Active heads preserve backend and lane nuance")
    func activeHeads() {
        #expect(DownloadRowDisplayPolicy.activeHead(lane: .original,
                                                    backend: .plex,
                                                    isServerPreparedVersion: false) == "Downloading original")
        // B4: a server-prepared version rides the STATIC `.original` byte-range lane — it must read as
        // "optimized", never "transcode" (which is reserved for the live encoder-gated lanes).
        #expect(DownloadRowDisplayPolicy.activeHead(lane: .original,
                                                    backend: .emby,
                                                    isServerPreparedVersion: true) == "Downloading optimized")
        #expect(DownloadRowDisplayPolicy.activeHead(lane: .compatibleRemux,
                                                    backend: .jellyfin,
                                                    isServerPreparedVersion: false) == "Remuxing + downloading")
        #expect(DownloadRowDisplayPolicy.activeHead(lane: .optimize,
                                                    backend: .plex,
                                                    isServerPreparedVersion: false) == "Downloading transcode")
        #expect(DownloadRowDisplayPolicy.activeHead(lane: .optimize,
                                                    backend: .emby,
                                                    isServerPreparedVersion: false) == "Transcoding + downloading")
    }

    @Test("Percent text marks estimated fractions")
    func percentText() {
        #expect(DownloadRowDisplayPolicy.percentText(.init(value: 0.42, isEstimated: false)) == "42%")
        #expect(DownloadRowDisplayPolicy.percentText(.init(value: 0.42, isEstimated: true)) == "~42%")
    }

    @Test("Display progress shows server prep for static handoff rows before bytes")
    func displayProgressUsesServerPrepForPreByteHandoffRows() {
        let preparing = record(bytes: 0,
                               progress: 0,
                               metadata: metadata(resumeMode: .serverPrepThenStatic))
        #expect(DownloadRowDisplayPolicy.displayProgress(for: preparing,
                                                         fraction: nil,
                                                         serverPrepProgress: 0.5) == 0.5)
        #expect(DownloadRowDisplayPolicy.displayProgress(for: preparing,
                                                         fraction: nil,
                                                         serverPrepProgress: 1.2) == 0.999)
        #expect(DownloadRowDisplayPolicy.displayProgress(for: preparing,
                                                         fraction: nil,
                                                         serverPrepProgress: -0.2) == 0)
    }

    @Test("Display progress falls back to transfer fraction once bytes exist or lane is not server prep")
    func displayProgressFallsBackToTransferFraction() {
        let serverPrepWithBytes = record(bytes: 10,
                                         progress: 0,
                                         metadata: metadata(resumeMode: .serverPrepThenStatic))
        let liveForward = record(bytes: 0,
                                 progress: 0,
                                 metadata: metadata(resumeMode: .liveForwardOnly))
        let fraction = DownloadProgressDisplay.Fraction(value: 0.25, isEstimated: false)

        #expect(DownloadRowDisplayPolicy.displayProgress(for: serverPrepWithBytes,
                                                         fraction: fraction,
                                                         serverPrepProgress: 0.75) == 0.25)
        #expect(DownloadRowDisplayPolicy.displayProgress(for: liveForward,
                                                         fraction: fraction,
                                                         serverPrepProgress: 0.75) == 0.25)
    }

    @Test("ETA text preserves short, minute, hour, and day buckets")
    func timeLeftBuckets() {
        #expect(DownloadRowDisplayPolicy.timeLeftString(10) == "under a min")
        #expect(DownloadRowDisplayPolicy.timeLeftString(90) == "2 min")
        #expect(DownloadRowDisplayPolicy.timeLeftString(3_600) == "1h")
        #expect(DownloadRowDisplayPolicy.timeLeftString(5_400) == "1h 30m")
        #expect(DownloadRowDisplayPolicy.timeLeftString(172_800) == "2d")
        #expect(DownloadRowDisplayPolicy.timeLeftString(.nan) == nil)
    }

    @Test("Paused caption combines resume hint, progress, and bytes")
    func pausedCaption() {
        let caption = DownloadRowDisplayPolicy.pausedCaption(
            fraction: .init(value: 0.5, isEstimated: true),
            bytes: 1_000_000)
        #expect(caption.hasPrefix("Paused — tap to resume • ~50% • "))
        #expect(caption.contains("MB"))
    }

    @Test("Complete caption preserves unverified warning and resolution")
    func completeCaption() {
        let caption = DownloadRowDisplayPolicy.completeCaption(isUnverified: true,
                                                               bytes: 1_000_000,
                                                               sideAssetBytes: 25_000,
                                                               resolutionLabel: "1080p")
        #expect(caption.hasPrefix("Downloaded — playback not verified • 1 MB media • "))
        #expect(caption.contains("25 KB extras"))
        #expect(caption.hasSuffix(" • 1080p"))
    }

    @Test("Requested profile text trims empty labels")
    func requestedProfileText() {
        #expect(DownloadRowDisplayPolicy.requestedProfileText(" 4K 40 Mbps ") == "Requested: 4K 40 Mbps")
        #expect(DownloadRowDisplayPolicy.requestedProfileText(" ") == nil)
        #expect(DownloadRowDisplayPolicy.requestedProfileText(nil) == nil)
    }

    @Test("Requested profile text is hidden after terminal successful downloads")
    func requestedProfileTextStatusGate() {
        #expect(DownloadRowDisplayPolicy.requestedProfileText("Existing server version",
                                                              status: .downloading) == "Requested: Existing server version")
        #expect(DownloadRowDisplayPolicy.requestedProfileText("Existing server version",
                                                              status: .paused) == "Requested: Existing server version")
        #expect(DownloadRowDisplayPolicy.requestedProfileText("Existing server version",
                                                              status: .failed) == "Requested: Existing server version")
        #expect(DownloadRowDisplayPolicy.requestedProfileText("Existing server version",
                                                              status: .complete) == nil)
        #expect(DownloadRowDisplayPolicy.requestedProfileText("Existing server version",
                                                              status: .unverified) == nil)
    }

    @Test("Active quality text shows requested intent instead of ambiguous backend bitrate")
    func activeQualityTextShowsRequestedIntent() {
        let metadata = OfflineMetadata(ratingKey: "emby:item",
                                       title: "Title",
                                       type: "movie",
                                       duration: 3_019_584,
                                       requestedProfileLabel: "1080p 8 Mbps",
                                       downloadBitrateKbps: 33_309)
        let active = DownloadRecord(ratingKey: "emby:item",
                                    title: "Title",
                                    localURL: URL(fileURLWithPath: "/tmp/title.mp4"),
                                    bytes: 1_000_000,
                                    progress: 0.1,
                                    status: .downloading,
                                    metadata: metadata)

        #expect(DownloadRowDisplayPolicy.downloadQualityText(for: active)
                == "Requested: 1080p 8 Mbps")
    }

    @Test("Completed quality text derives average from local media bytes and runtime")
    func completedQualityTextUsesLocalArtifactAverage() {
        let metadata = OfflineMetadata(ratingKey: "plex:item",
                                       title: "Title",
                                       type: "movie",
                                       duration: 8_891_008,
                                       requestedProfileLabel: "1080p 8 Mbps",
                                       downloadBitrateKbps: 8_000)
        let complete = DownloadRecord(ratingKey: "plex:item",
                                      title: "Title",
                                      localURL: URL(fileURLWithPath: "/tmp/title.mp4"),
                                      bytes: 2_985_243_717,
                                      progress: 1,
                                      status: .complete,
                                      metadata: metadata)

        #expect(DownloadRowDisplayPolicy.averageDownloadedBitrateKbps(
            bytes: complete.bytes, durationMs: metadata.duration) == 2_686)
        #expect(DownloadRowDisplayPolicy.downloadQualityText(for: complete)
                == "Downloaded: 2.7 Mbps avg")
    }

    @Test("Completed quality text ignores stale converted-source bitrate")
    func completedQualityTextIgnoresStaleBackendBitrate() {
        let metadata = OfflineMetadata(ratingKey: "emby:item",
                                       title: "Title",
                                       type: "episode",
                                       duration: 3_019_584,
                                       requestedProfileLabel: "1080p 12 Mbps",
                                       downloadBitrateKbps: 33_309)
        let complete = DownloadRecord(ratingKey: "emby:item",
                                      title: "Title",
                                      localURL: URL(fileURLWithPath: "/tmp/title.mp4"),
                                      bytes: 2_164_047_744,
                                      progress: 1,
                                      status: .complete,
                                      metadata: metadata)

        #expect(DownloadRowDisplayPolicy.downloadQualityText(for: complete)
                == "Downloaded: 5.7 Mbps avg")
    }

    private func record(bytes: Int,
                        progress: Double,
                        metadata: OfflineMetadata?) -> DownloadRecord {
        DownloadRecord(ratingKey: "rk",
                       title: "Title",
                       localURL: URL(fileURLWithPath: "/tmp/title.mp4"),
                       bytes: bytes,
                       progress: progress,
                       status: .downloading,
                       metadata: metadata)
    }

    private func metadata(resumeMode: DownloadResumeMode) -> OfflineMetadata {
        OfflineMetadata(ratingKey: "rk",
                        title: "Title",
                        type: "movie",
                        resumeMode: resumeMode)
    }

    private func routeRecord(status: DownloadStatus,
                             lane: DownloadLane,
                             serverPrepared: Bool) -> DownloadRecord {
        DownloadRecord(ratingKey: "route",
                       title: "Route",
                       localURL: URL(fileURLWithPath: "/tmp/route.mp4"),
                       status: status,
                       metadata: OfflineMetadata(ratingKey: "route",
                                                 title: "Route",
                                                 type: "movie",
                                                 downloadLane: lane,
                                                 serverPreparedVersion: serverPrepared ? true : nil))
    }
}
