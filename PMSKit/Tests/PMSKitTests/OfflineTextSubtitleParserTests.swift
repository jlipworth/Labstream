import XCTest
@testable import PMSKit

final class OfflineTextSubtitleParserTests: XCTestCase {
    func testParsesSRTAndWebVTTCuesHeadlessly() {
        let srt = """
        1
        00:00:01,500 --> 00:00:03,000
        Hello <i>there</i>

        2
        00:00:04.000 --> 00:00:05.250
        General Kenobi
        """
        let cues = OfflineTextSubtitleParser.parse(srt)
        XCTAssertEqual(cues, [
            OfflineTextSubtitleCue(startMs: 1500, endMs: 3000, text: "Hello there"),
            OfflineTextSubtitleCue(startMs: 4000, endMs: 5250, text: "General Kenobi"),
        ])
        XCTAssertTrue(cues[0].contains(2_000))
        XCTAssertFalse(cues[0].contains(3_000))
    }

    func testOfflineSubtitleTrackRoundTripsWithoutURLs() throws {
        let track = OfflineTextSubtitleTrack(id: 7, displayName: "English (SRT)", language: "eng", codec: "srt", relativePath: "item.sub.7.srt")
        let data = try JSONEncoder().encode(track)
        let decoded = try JSONDecoder().decode(OfflineTextSubtitleTrack.self, from: data)
        XCTAssertEqual(decoded, track)
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("http"))
    }
}
