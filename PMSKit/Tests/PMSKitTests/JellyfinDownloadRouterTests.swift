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

    @Test("Intents route with the expected transfer semantics", arguments: [
        // Original and existing-version intents stay static/range-resumable.
        (.original, "hevc", "truehd", "mkv", .staticOriginal, false, true),
        // Explicit transcode preset is live-forward.
        (.transcode, "h264", "aac", "mp4", .transcode, true, false),
        // Compatible intent uses remux when source video can be copied.
        (.compatible, "hevc", "aac", "mkv", .compatibleRemux, true, false),
        // Compatible intent falls back to transcode when video cannot be copied.
        (.compatible, "mpeg2video", "aac", "mpeg", .transcode, true, false),
    ] as [(JellyfinDownloadRouter.Intent, String, String, String,
           JellyfinDownloadRouter.Route, Bool, Bool)])
    func routeSemantics(intent: JellyfinDownloadRouter.Intent,
                        videoCodec: String,
                        audioCodec: String,
                        container: String,
                        expectedRoute: JellyfinDownloadRouter.Route,
                        isLiveForwardOnly: Bool,
                        usesByteRangeCheckpoint: Bool) {
        let route = JellyfinDownloadRouter.route(intent: intent,
                                                 videoCodec: videoCodec,
                                                 audioCodec: audioCodec,
                                                 container: container)
        #expect(route == expectedRoute)
        #expect(route.isLiveForwardOnly == isLiveForwardOnly)
        #expect(route.usesByteRangeCheckpoint == usesByteRangeCheckpoint)
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
