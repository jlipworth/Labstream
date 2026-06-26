import XCTest
@testable import PMSKit

final class LiveProbeConfigTests: XCTestCase {
    func testRedactRemovesServerTokenAndCredentialQueryValues() throws {
        let server = try XCTUnwrap(URL(string: "https://private.example.com:8920/emby"))
        let raw = "GET https://private.example.com:8920/emby/Videos/1/master.m3u8?api_key=embysecret&X-Plex-Token=plexsecret Authorization=Bearer embysecret"

        let redacted = LiveProbeConfig.redact(raw, token: "embysecret", server: server)

        XCTAssertFalse(redacted.contains("private.example.com"))
        XCTAssertFalse(redacted.contains("embysecret"))
        XCTAssertFalse(redacted.contains("plexsecret"))
        XCTAssertTrue(redacted.contains("api_key=<redacted>"))
        XCTAssertTrue(redacted.contains("X-Plex-Token=<redacted>"))
    }

    func testRedactRemovesPlaybackIdentifiersFromURLs() throws {
        let server = try XCTUnwrap(URL(string: "https://private.example.com:8920/emby"))
        let raw = "GET https://private.example.com:8920/emby/videos/88544/master.m3u8?DeviceId=device-raw&MediaSourceId=mediasource_88544&PlaySessionId=session-raw&api_key=embysecret"

        let redacted = LiveProbeConfig.redact(raw, token: "embysecret", server: server)

        XCTAssertFalse(redacted.contains("88544"))
        XCTAssertFalse(redacted.contains("device-raw"))
        XCTAssertFalse(redacted.contains("mediasource_88544"))
        XCTAssertFalse(redacted.contains("session-raw"))
        XCTAssertTrue(redacted.contains("/videos/<id>/master.m3u8"))
        XCTAssertTrue(redacted.contains("DeviceId=<redacted>"))
        XCTAssertTrue(redacted.contains("MediaSourceId=<redacted>"))
        XCTAssertTrue(redacted.contains("PlaySessionId=<redacted>"))
    }

    func testServerNameSummaryNeverIncludesRawName() {
        let raw = "John's Family Emby Server"
        let summary = LiveProbeLogger.serverNameSummary(raw)

        XCTAssertFalse(summary.contains(raw))
        XCTAssertTrue(summary.hasPrefix("set(sig="))
        XCTAssertEqual(LiveProbeLogger.serverNameSummary(nil), "nil")
        XCTAssertEqual(LiveProbeLogger.serverNameSummary(""), "nil")
    }
}
