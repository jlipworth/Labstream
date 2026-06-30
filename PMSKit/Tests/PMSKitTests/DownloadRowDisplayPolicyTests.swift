import Foundation
import Testing
@testable import PMSKit

@Suite("Download row display policy")
struct DownloadRowDisplayPolicyTests {
    @Test("Active heads preserve backend and lane nuance")
    func activeHeads() {
        #expect(DownloadRowDisplayPolicy.activeHead(lane: .original,
                                                    backend: .plex,
                                                    isServerPreparedVersion: false,
                                                    isCheckpointPausing: false) == "Downloading original")
        #expect(DownloadRowDisplayPolicy.activeHead(lane: .original,
                                                    backend: .emby,
                                                    isServerPreparedVersion: true,
                                                    isCheckpointPausing: false) == "Downloading transcode")
        #expect(DownloadRowDisplayPolicy.activeHead(lane: .compatibleRemux,
                                                    backend: .jellyfin,
                                                    isServerPreparedVersion: false,
                                                    isCheckpointPausing: false) == "Remuxing + downloading")
        #expect(DownloadRowDisplayPolicy.activeHead(lane: .optimize,
                                                    backend: .plex,
                                                    isServerPreparedVersion: false,
                                                    isCheckpointPausing: false) == "Downloading transcode")
        #expect(DownloadRowDisplayPolicy.activeHead(lane: .optimize,
                                                    backend: .emby,
                                                    isServerPreparedVersion: false,
                                                    isCheckpointPausing: false) == "Transcoding + downloading")
        #expect(DownloadRowDisplayPolicy.activeHead(lane: .original,
                                                    backend: .plex,
                                                    isServerPreparedVersion: false,
                                                    isCheckpointPausing: true) == "Pausing at checkpoint")
    }

    @Test("Percent text marks estimated fractions")
    func percentText() {
        #expect(DownloadRowDisplayPolicy.percentText(.init(value: 0.42, isEstimated: false)) == "42%")
        #expect(DownloadRowDisplayPolicy.percentText(.init(value: 0.42, isEstimated: true)) == "~42%")
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
                                                               resolutionLabel: "1080p")
        #expect(caption.hasPrefix("Downloaded — playback not verified • "))
        #expect(caption.contains("MB"))
        #expect(caption.hasSuffix(" • 1080p"))
    }
}
