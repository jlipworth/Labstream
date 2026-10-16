import Testing
@testable import PMSKit

@Suite("Download resolution labels")
struct DownloadResolutionLabelTests {
    @Test("Wide-aspect 1080p-class encodes use width, not just height")
    func wideAspect1080UsesWidthTier() {
        #expect(DownloadResolutionLabel.label(width: 1920, height: 800) == "1080p")
        #expect(DownloadResolutionLabel.label(forVideoResolution: "1920x800") == "1080p")
    }

    @Test("Wide-aspect 4K and 720p tiers also use near-rung width")
    func wideAspectTierWidths() {
        #expect(DownloadResolutionLabel.label(width: 3840, height: 1600) == "4K")
        #expect(DownloadResolutionLabel.label(width: 1280, height: 534) == "720p")
    }

    @Test("Small odd sizes still show exact dimensions")
    func smallOddSizeShowsExactDimensions() {
        #expect(DownloadResolutionLabel.label(width: 320, height: 180) == "320×180")
        #expect(DownloadResolutionLabel.label(width: nil, height: nil) == nil)
    }

    @Test func dimensionsParser() {
        #expect(DownloadResolutionLabel.dimensions(forVideoResolution: "1920x1080")?.width == 1920)
        #expect(DownloadResolutionLabel.dimensions(forVideoResolution: "1920x1080")?.height == 1080)
        // Defensive: capital-X also parses now (the old inline copy did not lowercase).
        #expect(DownloadResolutionLabel.dimensions(forVideoResolution: "1920X1080")?.height == 1080)
        #expect(DownloadResolutionLabel.dimensions(forVideoResolution: "garbage") == nil)
    }
}
