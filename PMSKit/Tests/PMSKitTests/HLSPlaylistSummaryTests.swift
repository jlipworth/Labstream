import Testing
@testable import PMSKit

@Test func hlsSummaryParsesSingleVariantMaster() {
    let body = """
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=8096000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2"
    index.m3u8
    """

    let summary = HLSPlaylistSummary.parse(body)

    #expect(summary.isMasterPlaylist)
    #expect(!summary.isAdaptive)
    #expect(summary.variants.count == 1)
    #expect(summary.variants[0].bandwidthBps == 8_096_000)
    #expect(summary.variants[0].resolution == "1920x1080")
    #expect(summary.variants[0].codecs == "avc1.640028,mp4a.40.2")
    #expect(summary.variants[0].uri == "index.m3u8")
}

@Test func hlsSummaryDetectsAdaptiveMaster() {
    let body = """
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720
    low/index.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=8000000,RESOLUTION=1920x1080
    high/index.m3u8
    """

    let summary = HLSPlaylistSummary.parse(body)

    #expect(summary.isAdaptive)
    #expect(summary.variants.map(\.bandwidthBps) == [2_500_000, 8_000_000])
    #expect(summary.variants.map(\.uri) == ["low/index.m3u8", "high/index.m3u8"])
}

@Test func hlsSummaryTreatsMediaPlaylistAsNonMaster() {
    let body = """
    #EXTM3U
    #EXT-X-TARGETDURATION:10
    #EXTINF:10.0,
    segment-0.ts
    """

    let summary = HLSPlaylistSummary.parse(body)

    #expect(!summary.isMasterPlaylist)
    #expect(!summary.isAdaptive)
    #expect(summary.variants.isEmpty)
}
