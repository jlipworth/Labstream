import PMSKit
import Testing
@testable import Labstream

@MainActor
struct PlaybackExplanationPresentationTests {
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
