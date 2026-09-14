import PMSKit
import Testing
@testable import Labstream

@MainActor
struct PlaybackExplanationPresentationTests {
    @Test func displayEligibilityUpdatesAfterConclusiveStreamProbeWithoutChangingStreamFacts() {
        let diagnostics = PlaybackDiagnostics()
        diagnostics.applyRuntimeHDRProbe(.init(containsHDRVideo: true, transferFunction: "PQ",
            eligibleForHDRPlayback: true, sawVideoFormatDescriptions: true, videoCodecFourCC: "hvc1"))
        diagnostics.applyHDRDisplayEligibility(false)
        #expect(diagnostics.runtimeEligibleForHDR == false)
        diagnostics.applyRuntimeHDRProbe(.init(containsHDRVideo: true, transferFunction: "PQ",
            eligibleForHDRPlayback: true, sawVideoFormatDescriptions: true, videoCodecFourCC: "hvc1"))
        #expect(diagnostics.runtimeEligibleForHDR == false) // Older async sample cannot overwrite it.
        #expect(diagnostics.runtimeContainsHDR == true)
        #expect(diagnostics.runtimeTransferFunction == "PQ")
        #expect(diagnostics.displayCapabilityLabel.contains("AVPlayer HDR unavailable"))
        diagnostics.applyHDRDisplayEligibility(true)
        #expect(diagnostics.runtimeEligibleForHDR == true)
        #expect(diagnostics.runtimeVideoCodecFourCC == "hvc1")
    }

    @Test func displayUpdatesDoNotInventStreamMetadata() {
        let diagnostics = PlaybackDiagnostics()
        diagnostics.applyHDRDisplayEligibility(true)
        #expect(diagnostics.runtimeContainsHDR == nil)
        #expect(diagnostics.runtimeTransferFunction == nil)
    }

    #if os(macOS)
    @Test func playerScreenCapabilityIsDistinctFromGlobalEligibilityAndCurrentHeadroom() {
        let diagnostics = PlaybackDiagnostics()
        diagnostics.applyHDRDisplayEligibility(true)
        diagnostics.applyHDRDisplayScreen(potentialEDR: 2, currentEDR: 1)
        #expect(diagnostics.displayCapabilityLabel.contains("HDR-capable player display"))
        #expect(diagnostics.playerDisplayHDREligible)
        #expect(diagnostics.displayCurrentEDR == 1) // Low current headroom does not mean SDR-only.
        diagnostics.applyHDRDisplayScreen(potentialEDR: 1, currentEDR: 1)
        #expect(diagnostics.displayCapabilityLabel.contains("SDR player display"))
        #expect(!diagnostics.playerDisplayHDREligible)
        diagnostics.applyHDRDisplayScreen(potentialEDR: nil, currentEDR: nil)
        #expect(diagnostics.displayCapabilityLabel.contains("Player display unknown"))
        diagnostics.applyHDRDisplayScreen(potentialEDR: .nan, currentEDR: .infinity)
        #expect(diagnostics.displayPotentialEDR == nil)
        #expect(diagnostics.displayCurrentEDR == nil)
    }

    @Test func playerDisplayObservationTeardownClearsScreen() async {
        let diagnostics = PlaybackDiagnostics()
        let host = PlayerLayerHostView(frame: .zero)
        host.displayDiagnostics = diagnostics
        diagnostics.applyHDRDisplayScreen(potentialEDR: 2, currentEDR: 1.5)
        host.stopDisplayObservation()
        await Task.yield()
        #expect(diagnostics.displayPotentialEDR == nil)
        #expect(diagnostics.displayCurrentEDR == nil)
        #expect(host.displayDiagnostics == nil)
    }
    #endif

    @Test func statsExplanationKeepsHeadlineAndAtMostTwoUsefulReasons() {
        let diagnostics = PlaybackDiagnostics()
        diagnostics.applyStatic(item: MediaItem(ratingKey: "item", title: "Private title", type: "movie"),
                                decision: nil,
                                server: nil,
                                targetBitrateKbps: 8_000)
        diagnostics.applyMediaBrowserSource(
            MediaBrowserPlaybackSourceMetadata(container: "mkv",
                                               videoCodec: "hevc",
                                               audioCodec: "truehd"),
            playMethod: .transcode,
            transcodeReasons: ["VideoCodecNotSupported", "AudioCodecNotSupported",
                               "SubtitleCodecNotSupported"])

        #expect(diagnostics.playbackExplanation.headline == "The server is re-encoding video")
        #expect(diagnostics.playbackExplanation.conciseReasons.count == 2)
        #expect(diagnostics.playbackExplanation.conciseReasons[0] ==
                .init(reason: .qualityCap(kbps: 8_000), provenance: .labstreamRequested))
        #expect(diagnostics.playbackExplanation.conciseReasons[1] ==
                .init(reason: .videoCodec, provenance: .serverReported))
    }

    @Test func runtimeCodecAgreementRefinesLaneWithoutInventingAServerCause() {
        let diagnostics = PlaybackDiagnostics()
        diagnostics.applyStatic(item: MediaItem(ratingKey: "item", title: "Test", type: "movie"),
                                decision: nil,
                                server: nil,
                                targetBitrateKbps: 0)
        diagnostics.applyMediaBrowserSource(
            MediaBrowserPlaybackSourceMetadata(container: "mkv", videoCodec: "hevc"),
            playMethod: .transcode,
            transcodeReasons: [])
        diagnostics.applyRuntimeHDRProbe(
            PlaybackHDRProbeResult(containsHDRVideo: false,
                                   transferFunction: nil,
                                   eligibleForHDRPlayback: true,
                                   sawVideoFormatDescriptions: true,
                                   videoCodecFourCC: "hvc1"))

        #expect(diagnostics.playbackExplanation.lane == .directStream)
        #expect(diagnostics.playbackExplanation.evidence.contains(
            .init(reason: .videoCopy, provenance: .inferred)))
        #expect(!diagnostics.playbackExplanation.evidence.contains {
            $0.reason == .audioTranscode
        })
        #expect(diagnostics.modeText == "Likely Direct Stream")
        #expect(diagnostics.playbackExplanation.headline.contains("likely"))
        #expect(diagnostics.playbackExplanation.evidence.last?.conciseText.contains("likely") == true)
    }

    @Test func plexDVAndSubtitleWordingUsesLabstreamAndPreservesProvenance() {
        let diagnostics = PlaybackDiagnostics()
        diagnostics.applyStatic(
            item: MediaItem(ratingKey: "item", title: "Test", type: "movie"),
            decision: DecisionResponse(generalDecisionCode: 1001,
                                       generalDecisionText: "raw prose",
                                       videoDecision: "transcode",
                                       audioDecision: "copy"),
            server: nil,
            targetBitrateKbps: 0,
            subtitleBurnRequested: true,
            dolbyVisionGuardActive: true)

        let text = diagnostics.playbackExplanation.conciseReasons
            .map(\.conciseText).joined(separator: " ")
        #expect(text.contains("Labstream"))
        #expect(!text.contains("VisionPlay"))
        #expect(diagnostics.playbackExplanation.conciseReasons.allSatisfy {
            $0.provenance == .labstreamRequested
        })
    }
}
