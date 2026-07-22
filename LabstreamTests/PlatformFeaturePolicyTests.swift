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

    @Test("Season download action follows the platform product contract")
    func seasonDownloadActionMatchesProductScope() {
        let visible = ContainerBrowserFeaturePolicy.showsSeasonDownloadAction(
            supportsDownloads: PlatformFeaturePolicy.supportsDownloads,
            childrenAreEpisodes: true,
            hasLoadedChildren: true)
        #if os(tvOS)
        #expect(!visible)
        #else
        #expect(visible)
        #endif

        #expect(!ContainerBrowserFeaturePolicy.showsSeasonDownloadAction(
            supportsDownloads: true,
            childrenAreEpisodes: false,
            hasLoadedChildren: true))
        #expect(!ContainerBrowserFeaturePolicy.showsSeasonDownloadAction(
            supportsDownloads: true,
            childrenAreEpisodes: true,
            hasLoadedChildren: false))
    }
}
