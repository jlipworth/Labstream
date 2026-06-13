import XCTest
@testable import PMSKit

final class PlaylistRewriterTests: XCTestCase {
    let rewriter = PlaylistRewriter(
        upstreamBase: URL(string: "https://pms.example:32400")!,
        loopbackBase: URL(string: "http://127.0.0.1:51234")!)

    func testRewritesAbsoluteUpstreamURLsToLoopback() {
        let body = "#EXTM3U\nhttps://pms.example:32400/video/seg0.ts\n"
        let out = rewriter.rewrite(Data(body.utf8), contentType: "application/vnd.apple.mpegurl")
        XCTAssertEqual(String(decoding: out, as: UTF8.self),
                       "#EXTM3U\nhttp://127.0.0.1:51234/video/seg0.ts\n")
    }

    func testLeavesRelativeURIsUntouched() {
        let body = "#EXTM3U\nindex.m3u8\nseg0.ts\n"
        let out = rewriter.rewrite(Data(body.utf8), contentType: "application/vnd.apple.mpegurl")
        XCTAssertEqual(String(decoding: out, as: UTF8.self), body)
    }

    func testDoesNotRewriteNonPlaylistBodies() {
        // A segment body that happens to contain the upstream bytes must NOT be mangled.
        let body = "https://pms.example:32400/x"
        let out = rewriter.rewrite(Data(body.utf8), contentType: "video/mp2t")
        XCTAssertEqual(String(decoding: out, as: UTF8.self), body)
    }
}
