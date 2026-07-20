import Foundation
import Testing
@testable import PMSKit

struct PlaybackExplanationTests {
    @Test func plexUsesStructuredStreamDecisionsInsteadOfBackendProse() {
        let decision = DecisionResponse(generalDecisionCode: 1001,
                                        generalDecisionText: "https://private.example/media?token=secret",
                                        mdeDecisionText: "Raw backend prose must not be displayed",
                                        partDecision: "transcode",
                                        videoDecision: "copy",
                                        audioDecision: "transcode")
        let explanation = PlaybackExplanation.plex(decision: decision,
                                                    maxVideoBitrateKbps: 0,
                                                    subtitleBurnRequested: false,
                                                    dolbyVisionGuardActive: false)

        #expect(explanation.lane == .audioOnlyTranscode)
        #expect(explanation.headline == "Video is copied; audio is converted")
        #expect(explanation.evidence.contains(.init(reason: .videoCopy, provenance: .serverReported)))
        #expect(explanation.evidence.contains(.init(reason: .audioTranscode, provenance: .serverReported)))
        #expect(!rendered(explanation).contains("private.example"))
        #expect(!rendered(explanation).contains("Raw backend prose"))
    }

    @Test func plexAppRequestCausesAreProvenancedAndPrioritized() {
        let decision = DecisionResponse(generalDecisionCode: 1001,
                                        generalDecisionText: nil,
                                        videoDecision: "transcode",
                                        audioDecision: "copy")
        let explanation = PlaybackExplanation.plex(decision: decision,
                                                    maxVideoBitrateKbps: 8_000,
                                                    subtitleBurnRequested: true,
                                                    dolbyVisionGuardActive: true)

        #expect(explanation.lane == .videoTranscode)
        #expect(explanation.conciseReasons.map(\.reason) == [.dolbyVisionGuard, .subtitleBurnIn])
        #expect(explanation.evidence.contains(.init(reason: .qualityCap(kbps: 8_000),
                                                    provenance: .labstreamRequested)))
        #expect(rendered(explanation).contains("Labstream"))
        #expect(!rendered(explanation).contains("VisionPlay"))
    }

    @Test func mediaBrowserNormalizesJellyfinAndEmbyReasonsSemantically() {
        let explanation = PlaybackExplanation.mediaBrowser(
            playMethod: .transcode,
            transcodeReasons: ["VideoCodecNotSupported", "AudioChannelsNotSupported",
                               "SubtitleContentOptionsEnabled", "VideoCodecNotSupported"],
            maxVideoBitrateKbps: 0,
            dolbyVisionGuardActive: false)

        #expect(explanation.lane == .videoTranscode)
        #expect(explanation.evidence.contains(.init(reason: .videoCodec, provenance: .serverReported)))
        #expect(explanation.evidence.contains(.init(reason: .audioChannels, provenance: .serverReported)))
        #expect(explanation.evidence.contains(.init(reason: .subtitleCompatibility,
                                                    provenance: .serverReported)))
        #expect(explanation.diagnosticTokens.filter { $0 == "server_reported:video_codec" }.count == 1)
    }

    @Test func mediaBrowserAudioOnlyAndDirectLanesRemainConcise() {
        let audio = PlaybackExplanation.mediaBrowser(playMethod: .transcode,
                                                     transcodeReasons: ["AudioCodecNotSupported"],
                                                     maxVideoBitrateKbps: 0,
                                                     dolbyVisionGuardActive: false)
        let direct = PlaybackExplanation.mediaBrowser(playMethod: .directPlay,
                                                      transcodeReasons: [],
                                                      maxVideoBitrateKbps: 0,
                                                      dolbyVisionGuardActive: false)

        #expect(audio.lane == .audioOnlyTranscode)
        #expect(direct.lane == .directPlay)
        #expect(direct.conciseReasons.count == 1)
    }

    @Test func missingPlexDecisionIsUnknownOnTheServerHLSPath() {
        let explanation = PlaybackExplanation.plex(decision: nil,
                                                    maxVideoBitrateKbps: 0,
                                                    subtitleBurnRequested: false,
                                                    dolbyVisionGuardActive: false,
                                                    decisionUnavailableMeansTranscode: true)
        #expect(explanation.lane == .unknownTranscode)
        #expect(explanation.evidence == [.init(reason: .unknownServerReason, provenance: .unknown)])
    }

    @Test func deterministicPrivacyBoundaryRejectsOpaqueBackendValues() {
        let secrets = [
            "token-secret-203",
            "private-host.example",
            "My Private Server",
            "Sensitive Movie Title",
            "/library/private/title.mkv",
            "media-source-id-203",
            "play-session-id-203",
            "client-id-203",
        ]
        let opaque = secrets.joined(separator: "-")
        let explanations = [
            PlaybackExplanation.mediaBrowser(playMethod: .transcode,
                                             transcodeReasons: [opaque, "VideoRangeNotSupported"],
                                             maxVideoBitrateKbps: 6_500,
                                             dolbyVisionGuardActive: false),
            PlaybackExplanation.plex(
                decision: DecisionResponse(generalDecisionCode: 1001,
                                           generalDecisionText: opaque,
                                           mdeDecisionText: opaque,
                                           videoDecision: "transcode"),
                maxVideoBitrateKbps: 0,
                subtitleBurnRequested: false,
                dolbyVisionGuardActive: false),
        ]

        for output in explanations.map(rendered) {
            for secret in secrets {
                #expect(!output.localizedCaseInsensitiveContains(secret))
            }
            #expect(!output.contains("http"))
            #expect(!output.contains("/library/"))
        }
    }

    private func rendered(_ explanation: PlaybackExplanation) -> String {
        ([explanation.headline]
            + explanation.evidence.map(\.conciseText)
            + explanation.diagnosticTokens).joined(separator: "\n")
    }
}
