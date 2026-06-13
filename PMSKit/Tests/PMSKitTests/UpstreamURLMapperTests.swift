import XCTest
@testable import PMSKit

final class UpstreamURLMapperTests: XCTestCase {
    let mapper = UpstreamURLMapper(upstreamBase: URL(string: "https://pms.example:32400")!)

    func testMapsTargetOntoUpstreamSchemeHostPort() {
        let url = mapper.upstreamURL(forTarget: "/video/:/transcode/universal/index.m3u8?session=abc")
        XCTAssertEqual(url?.absoluteString,
                       "https://pms.example:32400/video/:/transcode/universal/index.m3u8?session=abc")
    }

    func testPreservesPercentEncodingInTarget() {
        let url = mapper.upstreamURL(forTarget: "/a%20b/seg.ts?x=%3D")
        XCTAssertEqual(url?.absoluteString, "https://pms.example:32400/a%20b/seg.ts?x=%3D")
    }

    func testRejectsTargetWithoutLeadingSlash() {
        XCTAssertNil(mapper.upstreamURL(forTarget: "video/index.m3u8"))
    }
}
