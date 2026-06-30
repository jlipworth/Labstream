import Testing
@testable import PMSKit

@Suite("Jellyfin download router")
struct JellyfinDownloadRouterTests {
    @Test("Download choices map to Jellyfin intents")
    func choiceIntentMapping() {
        #expect(JellyfinDownloadRouter.intent(for: .original) == .original)
        #expect(JellyfinDownloadRouter.intent(for: .existingVersion) == .original)
        #expect(JellyfinDownloadRouter.intent(for: .optimize(targetName: "720p 4 Mbps")) == .transcode)
        #expect(JellyfinDownloadRouter.intent(for: .optimizeCompatible) == .compatible)
    }

    @Test("Original and existing-version intents stay static/range-resumable")
    func originalIntentIsStatic() {
        let route = JellyfinDownloadRouter.route(intent: .original,
                                                 videoCodec: "hevc",
                                                 audioCodec: "truehd",
                                                 container: "mkv")
        #expect(route == .staticOriginal)
        #expect(!route.isLiveForwardOnly)
        #expect(route.usesByteRangeCheckpoint)
    }

    @Test("Explicit transcode preset is live-forward")
    func transcodeIntentIsLiveForwardOnly() {
        let route = JellyfinDownloadRouter.route(intent: .transcode,
                                                 videoCodec: "h264",
                                                 audioCodec: "aac",
                                                 container: "mp4")
        #expect(route == .transcode)
        #expect(route.isLiveForwardOnly)
        #expect(!route.usesByteRangeCheckpoint)
    }

    @Test("Compatible intent uses remux when source video can be copied")
    func compatibleIntentCanRemux() {
        let route = JellyfinDownloadRouter.route(intent: .compatible,
                                                 videoCodec: "hevc",
                                                 audioCodec: "aac",
                                                 container: "mkv")
        #expect(route == .compatibleRemux)
        #expect(route.isLiveForwardOnly)
        #expect(!route.usesByteRangeCheckpoint)
    }

    @Test("Compatible intent falls back to transcode when video cannot be copied")
    func compatibleIntentFallsBackToTranscode() {
        let route = JellyfinDownloadRouter.route(intent: .compatible,
                                                 videoCodec: "mpeg2video",
                                                 audioCodec: "aac",
                                                 container: "mpeg")
        #expect(route == .transcode)
        #expect(route.isLiveForwardOnly)
        #expect(!route.usesByteRangeCheckpoint)
    }

    @Test("Routes expose stable diagnostic labels")
    func diagnosticLabels() {
        #expect(JellyfinDownloadRouter.Route.staticOriginal.diagnosticLabel == "static_original")
        #expect(JellyfinDownloadRouter.Route.compatibleRemux.diagnosticLabel == "compatible_remux")
        #expect(JellyfinDownloadRouter.Route.transcode.diagnosticLabel == "transcode")
    }

    @Test("Compatible decision carries stream-copy eligibility for request building")
    func compatibleDecisionCarriesEligibility() {
        let decision = JellyfinDownloadRouter.compatibleDecision(videoCodec: "h265",
                                                                 audioCodec: "truehd",
                                                                 container: "mkv")
        #expect(decision.route == .compatibleRemux)
        #expect(decision.isRemux)
        #expect(decision.eligibility.videoCodec == "hevc")
        #expect(decision.eligibility.copiesVideo)
        #expect(!decision.eligibility.copiesAudio)
    }
}
