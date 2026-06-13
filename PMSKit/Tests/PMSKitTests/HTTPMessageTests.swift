import XCTest
@testable import PMSKit

final class HTTPMessageTests: XCTestCase {
    func testParsesRequestLineAndHeaders() {
        let raw = "GET /video/index.m3u8?session=abc HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=0-99\r\n\r\n"
        let parsed = HTTPRequestHead.parse(Data(raw.utf8))
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.head.method, "GET")
        XCTAssertEqual(parsed?.head.target, "/video/index.m3u8?session=abc")
        XCTAssertEqual(parsed?.head.value(for: "range"), "bytes=0-99") // case-insensitive
        XCTAssertEqual(parsed?.head.value(for: "Host"), "127.0.0.1")
    }

    func testReturnsNilWhenHeadIncomplete() {
        let raw = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n" // no terminating blank line
        XCTAssertNil(HTTPRequestHead.parse(Data(raw.utf8)))
    }

    func testReportsHeadByteCountSoBodyCanBeSplitOff() {
        // headByteCount is a Data byte offset (so trailing bytes can be split off), NOT a
        // grapheme count — Swift collapses "\r\n" to one Character, so compare in bytes.
        let raw = "GET / HTTP/1.1\r\n\r\nLEFTOVER"
        let parsed = HTTPRequestHead.parse(Data(raw.utf8))
        XCTAssertEqual(parsed?.headByteCount, Data(raw.utf8).count - Data("LEFTOVER".utf8).count)
    }

    func testSerializesResponseWithConnectionClose() {
        let resp = HTTPResponse(status: 200,
                                reason: "OK",
                                headers: [("Content-Type", "application/vnd.apple.mpegurl")],
                                body: Data("#EXTM3U".utf8))
        let bytes = resp.serialized()
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Type: application/vnd.apple.mpegurl\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 7\r\n"))
        XCTAssertTrue(text.contains("Connection: close\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n#EXTM3U"))
    }
}
