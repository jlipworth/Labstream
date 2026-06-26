import Testing
import Foundation
@testable import PMSKit

// GH #135 Stage 1b/1c: characterization of the two pure display/estimation leaves extracted from
// DownloadManager — the live-transcoder classifier (#123 "/s" suppression) and the transcode
// size estimate (storage preflight for Content-Length-less live transcodes).

@Suite("Download display classifier")
struct DownloadDisplayClassifierTests {

    private func record(lane: DownloadLane, ratingKey: String, progress: Double) -> DownloadRecord {
        DownloadRecord(ratingKey: ratingKey, title: "t",
                       localURL: URL(fileURLWithPath: "/tmp/x.mp4"),
                       progress: progress, status: .downloading,
                       metadata: OfflineMetadata(ratingKey: ratingKey, title: "t", type: "movie",
                                                 downloadLane: lane))
    }

    @Test func originalIsAlwaysWireSpeed() {
        for prefix in ["plex:1", "emby:1", "jellyfin:1"] {
            #expect(!DownloadDisplayClassifier.isLiveTranscoderSourced(
                record(lane: .original, ratingKey: prefix, progress: 0)))
            #expect(!DownloadDisplayClassifier.isLiveTranscoderSourced(
                record(lane: .original, ratingKey: prefix, progress: 0.5)))
        }
    }

    @Test func plexOptimizeIsGatedOnlyBeforeRenderedPartExists() {
        // Plex optimize: transcoder-gated until the rendered Part appears (progress <= 0),
        // then it's a static network-bound download.
        #expect(DownloadDisplayClassifier.isLiveTranscoderSourced(
            record(lane: .optimize, ratingKey: "plex:1", progress: 0)))
        #expect(!DownloadDisplayClassifier.isLiveTranscoderSourced(
            record(lane: .optimize, ratingKey: "plex:1", progress: 0.2)))
    }

    @Test func embyJellyfinOptimizeIsLiveForWholeTransfer() {
        for prefix in ["emby:1", "jellyfin:1"] {
            #expect(DownloadDisplayClassifier.isLiveTranscoderSourced(
                record(lane: .optimize, ratingKey: prefix, progress: 0)))
            #expect(DownloadDisplayClassifier.isLiveTranscoderSourced(
                record(lane: .optimize, ratingKey: prefix, progress: 0.9)))
        }
    }

    @Test func compatibleRemuxGatedUntilServerReportsSize() {
        #expect(DownloadDisplayClassifier.isLiveTranscoderSourced(
            record(lane: .compatibleRemux, ratingKey: "emby:1", progress: 0)))
        #expect(!DownloadDisplayClassifier.isLiveTranscoderSourced(
            record(lane: .compatibleRemux, ratingKey: "emby:1", progress: 0.3)))
    }
}

@Suite("Transcode size estimator")
struct TranscodeSizeEstimatorTests {

    @Test func nilForUnknownOrZeroDuration() {
        #expect(TranscodeSizeEstimator.bytes(durationMs: nil, videoBitrateBps: 8_000_000) == nil)
        #expect(TranscodeSizeEstimator.bytes(durationMs: 0, videoBitrateBps: 8_000_000) == nil)
    }

    @Test func estimateIncludesAudioContainerAllowance() {
        // 10s at 8 Mbps video + 256 kbps allowance = (10) * (8_256_000) / 8 = 10_320_000 bytes.
        #expect(TranscodeSizeEstimator.bytes(durationMs: 10_000, videoBitrateBps: 8_000_000) == 10_320_000)
        // 1s at 1 Mbps: (1) * (1_256_000)/8 = 157_000.
        #expect(TranscodeSizeEstimator.bytes(durationMs: 1_000, videoBitrateBps: 1_000_000) == 157_000)
    }
}
