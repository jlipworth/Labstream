import Testing
@testable import PMSKit

@Suite("Emby download source identity policy")
struct EmbyDownloadSourceIdentityPolicyTests {
    @Test("Explicit source overrides require an exact PlaybackInfo decision match")
    func explicitOverride() {
        #expect(EmbyDownloadSourceIdentityPolicy.accepts(
            explicitOverride: "converted-v2", decidedMediaSourceID: "converted-v2"))
        #expect(!EmbyDownloadSourceIdentityPolicy.accepts(
            explicitOverride: "converted-v2", decidedMediaSourceID: "original"))
        #expect(!EmbyDownloadSourceIdentityPolicy.accepts(
            explicitOverride: "converted-v2", decidedMediaSourceID: ""))
    }

    @Test("Ordinary negotiation may use the server-selected source")
    func ordinaryNegotiation() {
        #expect(EmbyDownloadSourceIdentityPolicy.accepts(
            explicitOverride: nil, decidedMediaSourceID: "server-choice"))
        #expect(EmbyDownloadSourceIdentityPolicy.accepts(
            explicitOverride: "", decidedMediaSourceID: "server-choice"))
    }
}
