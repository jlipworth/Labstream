import Foundation
import Testing
@testable import PMSKit

@Suite("Download preset policy")
struct DownloadPresetPolicyTests {
    @Test("Preset catalog preserves picker names and visibility filtering")
    func presetCatalog() throws {
        #expect(DownloadPresetPolicy.customDownloadProfileNames.first == "Original video quality")
        #expect(DownloadPresetPolicy.customDownloadProfile(named: "720P 4 MBPS")?.settings.maxVideoBitrateKbps == 4_000)
        #expect(DownloadPresetPolicy.isPlexOriginalQualityTarget(" Original video quality "))
        #expect(DownloadPresetPolicy.isPlexOriginalQualityTarget("Original Quality"))
        #expect(DownloadPresetPolicy.isExplicitDownloadPresetName("1080p 8 Mbps"))
        #expect(!DownloadPresetPolicy.isVisibleDownloadPresetName("Optimized for TV"))
        #expect(DownloadPresetPolicy.isVisibleDownloadPresetName("Original video quality"))
    }

    @Test("Display resolution uses target label only for downscaling optimize choices")
    func displayResolutionLabel() {
        let source = Media(id: 1, width: 3840, height: 2160, part: [])
        #expect(DownloadPresetPolicy.displayResolutionLabel(choice: .original, chosenMedia: source) == "4K")
        #expect(DownloadPresetPolicy.displayResolutionLabel(choice: .optimize(targetName: "720p 4 Mbps"),
                                                           chosenMedia: source) == "720p")
        #expect(DownloadPresetPolicy.displayResolutionLabel(choice: .optimize(targetName: "Original video quality"),
                                                           chosenMedia: source) == "4K")
        #expect(DownloadPresetPolicy.displayResolutionLabel(choice: .optimize(targetName: "Optimized for TV"),
                                                           chosenMedia: source) == "1080p")
    }

    @Test("Storage estimate source preserves source-sized and bitrate-sized semantics")
    func storageEstimateSource() {
        #expect(DownloadPresetPolicy.storageEstimateMediaSource(for: .original) == .sourceFile)
        #expect(DownloadPresetPolicy.storageEstimateMediaSource(for: .existingVersion) == .sourceFile)
        #expect(DownloadPresetPolicy.storageEstimateMediaSource(for: .optimizeCompatible) == .sourceFile)
        #expect(DownloadPresetPolicy.storageEstimateMediaSource(for: .optimize(targetName: "Original video quality")) == .sourceFile)
        #expect(DownloadPresetPolicy.storageEstimateMediaSource(for: .optimize(targetName: "720p 4 Mbps")) == .transcode(videoBitrateBps: 4_000_000))
        #expect(DownloadPresetPolicy.storageEstimateMediaSource(for: .optimize(targetName: "Optimized for Mobile")) == .transcode(videoBitrateBps: 2_000_000))
    }

    @Test("Jellyfin profile maps global original-quality labels to the explicit default ladder")
    func jellyfinProfileFallback() {
        let originalQuality = DownloadPresetPolicy.jellyfinTranscodeProfile(named: "Original video quality")
        #expect(originalQuality.videoBitrateBps == 8_000_000)
        #expect(originalQuality.maxWidth == 1920)
        #expect(originalQuality.maxHeight == 1080)

        let profile720 = DownloadPresetPolicy.jellyfinTranscodeProfile(named: "720p 3 Mbps")
        #expect(profile720.videoBitrateBps == 3_000_000)
        #expect(profile720.maxWidth == 1280)
        #expect(profile720.maxHeight == 720)
    }

    @Test("Transcode byte estimates preserve compatible-remux source size and bitrate estimates")
    func estimatedTranscodeBytes() {
        let compatible = record(metadata: OfflineMetadata(ratingKey: "jellyfin:item",
                                                          title: "Title",
                                                          type: "movie",
                                                          duration: 120_000,
                                                          sourcePartSize: 5_000,
                                                          backendKind: .jellyfin,
                                                          downloadLane: .compatibleRemux,
                                                          resumeMode: .liveForwardOnly))
        #expect(DownloadPresetPolicy.estimatedTranscodeBytes(for: compatible) == 5_000)

        let transcode = record(metadata: OfflineMetadata(ratingKey: "jellyfin:item",
                                                         title: "Title",
                                                         type: "movie",
                                                         duration: 10_000,
                                                         optimizeTargetName: "720p 4 Mbps",
                                                         backendKind: .jellyfin,
                                                         downloadLane: .optimize,
                                                         resumeMode: .liveForwardOnly))
        #expect(DownloadPresetPolicy.estimatedTranscodeBytes(for: transcode)
            == TranscodeSizeEstimator.bytes(durationMs: 10_000, videoBitrateBps: 4_000_000))
    }

    @Test("Plex fallback tags and media settings preserve original-quality no-cap semantics")
    func plexFallbacks() {
        #expect(DownloadPresetPolicy.conventionalPlexTagID(forName: "Optimized for Mobile") == 1)
        #expect(DownloadPresetPolicy.conventionalPlexTagID(forName: "Original video quality") == 3)
        #expect(DownloadPresetPolicy.conventionalPlexTagID(forName: "anything else") == 2)
        #expect(DownloadPresetPolicy.mediaSettings(forTargetName: "Original Quality").maxVideoBitrateKbps == nil)
        #expect(DownloadPresetPolicy.mediaSettings(forTargetName: "Optimized for TV").videoResolution == "1920x1080")
    }

    private func record(metadata: OfflineMetadata) -> DownloadRecord {
        DownloadRecord(ratingKey: metadata.ratingKey,
                       title: metadata.title,
                       localURL: URL(fileURLWithPath: "/tmp/visionplay-preset-policy.mp4"),
                       bytes: 0,
                       progress: 0,
                       status: .downloading,
                       metadata: metadata)
    }
}
