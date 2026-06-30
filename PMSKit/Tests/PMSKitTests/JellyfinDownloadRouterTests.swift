import Testing
@testable import PMSKit

@Suite("Jellyfin download router")
struct JellyfinDownloadRouterTests {

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
}
