import Foundation
import XCTest
@testable import PMSKit

final class P7HDR10PlaylistTests: XCTestCase {
    private let base = URL(string: "https://plex.example.internal/session/media.m3u8")!
    private let media = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:10\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:10,\n0.m4s\n#EXTINF:10,\n1.m4s\n"

    func testMultipleSegmentsAndSlidingUpdatesResolveAgainstMediaPlaylist() throws {
        let parsed = try P7HDR10Playlist.parse(Data(media.utf8), at: base)
        XCTAssertEqual(parsed.initialization.path, "/session/init.mp4")
        XCTAssertEqual(parsed.segments.map(\.path), ["/session/0.m4s", "/session/1.m4s"])
        let update = media.replacingOccurrences(of: "0.m4s", with: "2.m4s")
        XCTAssertEqual(try P7HDR10Playlist.parse(Data(update.utf8), at: base).segments.first?.path, "/session/2.m4s")
    }

    func testLegacyPlexCacheAdvisoryDoesNotChangeResourceAuthority() throws {
        let expected = try P7HDR10Playlist.parse(Data(media.utf8), at: base)
        for value in ["YES", "NO"] {
            let tagged = media.replacingOccurrences(of: "#EXT-X-VERSION:7", with: "#EXT-X-VERSION:7\n#EXT-X-ALLOW-CACHE:\(value)")
            XCTAssertEqual(try P7HDR10Playlist.parse(Data(tagged.utf8), at: base), expected)
        }
        XCTAssertThrowsError(try P7HDR10Playlist.parse(Data((media + "#EXT-X-ALLOW-CACHE:MAYBE\n").utf8), at: base))
    }

    func testUnsafeOrUnknownPackagingIsRejected() {
        for tag in ["#EXT-X-KEY:METHOD=AES-128,URI=\"key\"", "#EXT-X-BYTERANGE:10@0",
                    "#EXT-X-DISCONTINUITY", "#EXT-X-STREAM-INF:BANDWIDTH=100",
                    "#EXT-X-MEDIA:TYPE=AUDIO", "#EXT-X-PART:URI=\"part\"", "#EXT-X-GAP"] {
            XCTAssertThrowsError(try P7HDR10Playlist.parse(Data((media + tag + "\n").utf8), at: base))
        }
        for uri in ["https://other.example/init.mp4", "//other.example/init.mp4", "init.mp4#fragment",
                    "init.mp4\",BYTERANGE=\"10@0", "https://user@plex.example.internal/init.mp4"] {
            let invalid = media.replacingOccurrences(of: "init.mp4", with: uri)
            XCTAssertThrowsError(try P7HDR10Playlist.parse(Data(invalid.utf8), at: base))
        }
        XCTAssertThrowsError(try P7HDR10Playlist.parse(Data((media + "#EXT-X-MAP:URI=\"new.mp4\"\n").utf8), at: base))
    }

    func testRangesPreserveNormalizedRepresentationOffsets() throws {
        for (header, expected) in [("bytes=0-3", 0..<4), ("bytes=5-", 5..<10),
                                   ("bytes=-3", 7..<10), ("bytes=8-100", 8..<10),
                                   ("bytes=-100", 0..<10)] {
            XCTAssertEqual(try P7HDR10Playlist.range(header, length: 10), expected)
        }
        XCTAssertEqual(try P7HDR10Playlist.range(nil, length: 10), 0..<10)
        for header in ["bytes=10-", "bytes=3-2", "bytes=-0", "bytes=0-1,3-4", "bytes=+1-2",
                       "bytes=0-99999999999999999999999999", "bytes=-", "items=0-2"] {
            XCTAssertThrowsError(try P7HDR10Playlist.range(header, length: 10))
        }
    }
}

final class P7HDR10SessionTests: XCTestCase {
    func testResourcesRequireAdmissionAndInitCannotChangeOnUpdate() async throws {
        let root = URL(string: "https://plex.example.internal/media.m3u8")!
        let session = P7HDR10Session(playlist: root)
        let initURL = URL(string: "https://plex.example.internal/init.mp4")!
        do { _ = try await session.resource(initURL); XCTFail("unadmitted initialization") } catch {}
        let playlist = Data("#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:10,\n0.m4s\n".utf8)
        try await session.admit(playlist)
        let resource = try await session.resource(initURL)
        XCTAssertEqual(resource, .initialization)
        for changed in ["new.mp4", "0.m4s", "media.m3u8"] {
            let invalid = String(decoding: playlist, as: UTF8.self).replacingOccurrences(of: "init.mp4", with: changed)
            do { try await session.admit(Data(invalid.utf8)); XCTFail("changed init accepted") } catch {}
        }
        let retained = try await session.resource(initURL)
        XCTAssertEqual(retained, .initialization)
        // A fresh open has no authority inherited from the previous handle/session.
        let reopened = P7HDR10Session(playlist: root)
        do { _ = try await reopened.resource(initURL); XCTFail("stale admission inherited") } catch {}
    }
}
