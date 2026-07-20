import Testing
@testable import Labstream

@Suite("Platform feature policy")
struct PlatformFeaturePolicyTests {
    @Test("Downloads are absent only from tvOS")
    func downloadsPolicyMatchesProductScope() {
        #if os(tvOS)
        #expect(!PlatformFeaturePolicy.supportsDownloads)
        #else
        #expect(PlatformFeaturePolicy.supportsDownloads)
        #endif
    }
}
