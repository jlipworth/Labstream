import Foundation
import XCTest
@testable import PMSKit

final class BIFParserTests: XCTestCase {
    func testParsesSyntheticBIFAndFindsNearestFrame() throws {
        let data = makeBIF(intervalMs: 10_000,
                           frames: [
                               (timestamp: 0, payload: Data("frame-0".utf8)),
                               (timestamp: 1, payload: Data("frame-1".utf8)),
                               (timestamp: 2, payload: Data("frame-2".utf8)),
                           ])

        let index = try BIFParser.parse(data)

        XCTAssertEqual(index.version, 0)
        XCTAssertEqual(index.frameIntervalMs, 10_000)
        XCTAssertEqual(index.frameCount, 3)
        XCTAssertEqual(index.frameTimesMs, [0, 10_000, 20_000])
        XCTAssertEqual(String(data: try XCTUnwrap(index.frame(nearMs: 0)?.data), encoding: .utf8), "frame-0")
        XCTAssertEqual(String(data: try XCTUnwrap(index.frame(nearMs: 10_000)?.data), encoding: .utf8), "frame-1")
        XCTAssertEqual(String(data: try XCTUnwrap(index.frame(nearMs: 20_000)?.data), encoding: .utf8), "frame-2")
        XCTAssertEqual(index.frame(nearMs: 14_900)?.timeMs, 10_000)
        XCTAssertEqual(index.frame(nearMs: 15_100)?.timeMs, 20_000)
        XCTAssertEqual(index.frame(nearMs: -1)?.timeMs, 0)
        XCTAssertEqual(index.frame(nearMs: 99_000)?.timeMs, 20_000)
    }

    func testParsesPlexStyleZeroIntervalTimestampsAsSeconds() throws {
        let jpegA = Data([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0xff, 0xd9])
        let jpegB = Data([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x01, 0xff, 0xd9])
        let jpegC = Data([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x02, 0xff, 0xd9])
        let data = makeBIF(intervalMs: 0,
                           frames: [
                               (timestamp: 0, payload: jpegA),
                               (timestamp: 2, payload: jpegB),
                               (timestamp: 4, payload: jpegC),
                           ])

        let index = try BIFParser.parse(data)

        // Real Plex `index-sd.bif` files observed from PMS can store interval=0 while using
        // timestamp rows 0, 2, 4... for two-second frame spacing. Treat zero interval as the
        // BIF default 1000ms multiplier so timestamps remain seconds, not raw milliseconds.
        XCTAssertEqual(index.frameIntervalMs, 1_000)
        XCTAssertEqual(index.frameTimesMs, [0, 2_000, 4_000])
        XCTAssertEqual(index.frame(nearMs: 2_600)?.timeMs, 2_000)
        XCTAssertEqual(index.frame(nearMs: 3_600)?.timeMs, 4_000)
        XCTAssertEqual(index.frame(nearMs: 0)?.data.prefix(4), Data([0xff, 0xd8, 0xff, 0xe0]))
    }

    func testRetainsOneBackingPayloadAndMaterializesOnlySelectedFrame() throws {
        let frames = (0..<128).map { index in
            (timestamp: UInt32(index), payload: Data(repeating: UInt8(index), count: 4_096))
        }
        let data = makeBIF(intervalMs: 1_000, frames: frames)

        let index = try BIFParser.parse(data)

        XCTAssertEqual(index.backingByteCount, data.count)
        XCTAssertEqual(index.frameCount, frames.count)
        let selected = try XCTUnwrap(index.frame(nearMs: 64_000))
        XCTAssertEqual(selected.timeMs, 64_000)
        XCTAssertEqual(selected.data, frames[64].payload)
        XCTAssertEqual(selected.data.count, 4_096)
    }

    func testDescriptorIndexPreservesSortedTimeLookupWithoutReorderingBackingBytes() throws {
        let data = makeBIF(intervalMs: 1_000,
                           frames: [
                            (timestamp: 2, payload: Data("later".utf8)),
                            (timestamp: 0, payload: Data("first".utf8)),
                            (timestamp: 1, payload: Data("middle".utf8)),
                           ])

        let index = try BIFParser.parse(data)

        XCTAssertEqual(index.frameTimesMs, [0, 1_000, 2_000])
        XCTAssertEqual(index.frame(nearMs: 0)?.data, Data("first".utf8))
        XCTAssertEqual(index.frame(nearMs: 1_000)?.data, Data("middle".utf8))
        XCTAssertEqual(index.frame(nearMs: 2_000)?.data, Data("later".utf8))
    }

    func testSemanticEqualityIgnoresBackingLayoutWithoutMaterializingStoredFrames() throws {
        let frames = [
            BIFIndex.Frame(timeMs: 0, data: Data("first".utf8)),
            BIFIndex.Frame(timeMs: 1_000, data: Data("second".utf8)),
        ]
        let parsed = try BIFParser.parse(makeBIF(intervalMs: 1_000, frames: [
            (timestamp: 0, payload: frames[0].data),
            (timestamp: 1, payload: frames[1].data),
        ]))
        let constructed = BIFIndex(version: 0, frameIntervalMs: 1_000, frames: frames)

        XCTAssertEqual(parsed, constructed)
        XCTAssertNotEqual(parsed, BIFIndex(version: 0, frameIntervalMs: 1_000, frames: [
            frames[0],
            BIFIndex.Frame(timeMs: 1_000, data: Data("different".utf8)),
        ]))
        XCTAssertEqual(constructed.frames, frames)
    }

    func testPublicInitializerPreservesEmptyFramePayloadAndRetrievalCount() throws {
        let index = BIFIndex(version: 0, frameIntervalMs: 1_000, frames: [
            BIFIndex.Frame(timeMs: 0, data: Data()),
            BIFIndex.Frame(timeMs: 1_000, data: Data("next".utf8)),
        ])

        XCTAssertEqual(index.frameCount, 2)
        XCTAssertEqual(index.frames.count, 2)
        XCTAssertEqual(index.frame(nearMs: 0), BIFIndex.Frame(timeMs: 0, data: Data()))
        XCTAssertEqual(index.frame(nearMs: 1_000)?.data, Data("next".utf8))
    }

    func testParsesMemoryMappedOfflineBIF() throws {
        let data = makeBIF(intervalMs: 1_000,
                           frames: [(timestamp: 0, payload: Data("mapped-frame".utf8))])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).bif")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let index = try BIFParser.parse(contentsOf: url)

        XCTAssertEqual(index.backingByteCount, data.count)
        XCTAssertEqual(index.frameCount, 1)
        XCTAssertEqual(index.frame(nearMs: 0)?.data, Data("mapped-frame".utf8))
    }

    func testRejectsTruncatedIndexTable() {
        let data = Data([0x89, 0x42, 0x49, 0x46, 0x0D, 0x0A, 0x1A, 0x0A])
            + littleEndian(0)
            + littleEndian(2)
            + littleEndian(1_000)
            + Data(repeating: 0, count: 64 - 20)
            + littleEndian(0)

        XCTAssertThrowsError(try BIFParser.parse(data)) { error in
            XCTAssertEqual(error as? BIFParserError, .truncatedIndexTable)
        }
    }

    func testRejectsInvalidFrameOffsets() {
        var data = makeBIF(intervalMs: 1_000,
                           frames: [
                               (timestamp: 0, payload: Data("first".utf8)),
                               (timestamp: 1, payload: Data("second".utf8)),
                           ])
        // Corrupt frame 1's start offset so it points into the index table.
        data.replaceSubrange(64 + 8 + 4..<64 + 8 + 8, with: littleEndian(12))

        XCTAssertThrowsError(try BIFParser.parse(data)) { error in
            XCTAssertEqual(error as? BIFParserError, .invalidFrameOffsets)
        }
    }

    func testRejectsBIFTimestampMultiplicationOverflow() {
        let data = makeBIF(intervalMs: UInt32.max,
                           frames: [
                               (timestamp: UInt32.max - 1, payload: Data("frame".utf8)),
                           ])

        XCTAssertThrowsError(try BIFParser.parse(data)) { error in
            XCTAssertEqual(error as? BIFParserError, .timestampOverflow)
        }
    }

    func testRejectsBIFSentinelFallbackMultiplicationOverflow() {
        XCTAssertThrowsError(try BIFParser.timestampMilliseconds(timestamp: UInt32.max,
                                                                 frameIndex: 2,
                                                                 intervalMs: Int.max)) { error in
            XCTAssertEqual(error as? BIFParserError, .timestampOverflow)
        }
    }

    func testPlexBIFRequestUsesPartIndexesEndpointWithoutTokenHeader() {
        let identity = ClientIdentity(clientIdentifier: "client-id",
                                      product: "Labstream",
                                      version: "1.0",
                                      deviceName: "Vision Pro")
        let request = TrickPlayRequest.plexBIFIndex(server: URL(string: "https://example.test")!,
                                                    token: "secret-token",
                                                    identity: identity,
                                                    partID: 123,
                                                    quality: "sd")
        let urlRequest = request.urlRequest()

        XCTAssertEqual(urlRequest.url?.path, "/library/parts/123/indexes/sd")
        XCTAssertEqual(URLComponents(url: urlRequest.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "X-Plex-Token" })?.value, "secret-token")
        XCTAssertNil(urlRequest.value(forHTTPHeaderField: "X-Plex-Token"))
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "X-Plex-Product"), "Labstream")
    }

    func testPartIndexesAdvertiseStandardDefinitionBIF() throws {
        let json = #"{"id":7,"key":"/library/parts/7/file.mkv","indexes":"sd,foo"}"#.data(using: .utf8)!
        let part = try JSONDecoder().decode(Part.self, from: json)
        XCTAssertTrue(part.hasStandardDefinitionBIFIndex)
    }
    func testJellyfinOfflinePlannerSanitizesTokenBearingTileURLs() throws {
        let playlist = """
        #EXTM3U
        #EXTINF:1000,
        #EXT-X-TILES:RESOLUTION=320x180,LAYOUT=10x10,DURATION=10
        tile0.jpg?ApiKey=secret&MediaSourceId=abc
        #EXTINF:1000,
        #EXT-X-TILES:RESOLUTION=320x180,LAYOUT=10x10,DURATION=10
        https://server.test/Videos/i/Trickplay/320/tile1.jpg?ApiKey=secret
        """
        let sanitized = JellyfinTrickPlayOfflineCachePlanner.sanitizedPlaylist(playlist, tileFilenamesByURI: [
            "tile0.jpg?ApiKey=secret&MediaSourceId=abc": "download.jf-trickplay-0.jpg",
            "https://server.test/Videos/i/Trickplay/320/tile1.jpg?ApiKey=secret": "download.jf-trickplay-1.jpg",
        ])

        XCTAssertFalse(sanitized.localizedCaseInsensitiveContains("apikey"))
        XCTAssertFalse(sanitized.contains("server.test"))
        XCTAssertTrue(sanitized.contains("download.jf-trickplay-0.jpg"))
        XCTAssertTrue(sanitized.contains("download.jf-trickplay-1.jpg"))
        let parsed = try JellyfinTrickPlayPlaylistParser.parse(sanitized)
        XCTAssertEqual(parsed.tiles.map(\.uri), ["download.jf-trickplay-0.jpg", "download.jf-trickplay-1.jpg"])
        XCTAssertEqual(parsed.frame(nearMs: 1_500_000)?.tile.uri, "download.jf-trickplay-1.jpg")
    }

    func testJellyfinOfflinePlannerDropsTokenFromUncachedTileAndKeepsCachedOnes() throws {
        // Tile 0 cached, tile 1 failed to download (absent from the map). The failed tile must NOT
        // leak its ApiKey/host into the persisted playlist, and the cached tile must still survive —
        // one flaky tile cannot void the whole playlist.
        let playlist = """
        #EXTM3U
        #EXTINF:1000,
        #EXT-X-TILES:RESOLUTION=320x180,LAYOUT=10x10,DURATION=10
        tile0.jpg?ApiKey=secret
        #EXTINF:1000,
        #EXT-X-TILES:RESOLUTION=320x180,LAYOUT=10x10,DURATION=10
        https://server.test/Videos/i/Trickplay/320/tile1.jpg?ApiKey=secret
        """
        let sanitized = JellyfinTrickPlayOfflineCachePlanner.sanitizedPlaylist(playlist, tileFilenamesByURI: [
            "tile0.jpg?ApiKey=secret": "download.jf-trickplay-0.jpg",
        ])

        XCTAssertFalse(sanitized.localizedCaseInsensitiveContains("apikey"))
        XCTAssertFalse(sanitized.contains("server.test"))
        XCTAssertTrue(sanitized.contains("download.jf-trickplay-0.jpg"))
        let parsed = try JellyfinTrickPlayPlaylistParser.parse(sanitized)
        XCTAssertEqual(parsed.tiles.first?.uri, "download.jf-trickplay-0.jpg")
    }

    func testJellyfinOfflinePlannerEstimatesTileStorageByDuration() {
        XCTAssertEqual(JellyfinTrickPlayOfflineCachePlanner.estimatedTileBytes(durationMs: nil), 0)
        XCTAssertEqual(JellyfinTrickPlayOfflineCachePlanner.estimatedTileBytes(durationMs: 500_000), 300_000)
        XCTAssertEqual(JellyfinTrickPlayOfflineCachePlanner.estimatedTileBytes(durationMs: 1_500_000), 600_000)
    }

    func testJellyfinPlaylistRejectsNonfiniteNegativeAndAbsurdDurations() {
        for duration in ["nan", "inf", "-1", "1000000000"] {
            let playlist = """
            #EXTM3U
            #EXTINF:\(duration),
            #EXT-X-TILES:RESOLUTION=320x180,LAYOUT=10x10,DURATION=10
            tile.jpg
            """
            XCTAssertThrowsError(try JellyfinTrickPlayPlaylistParser.parse(playlist)) { error in
                XCTAssertEqual(error as? JellyfinTrickPlayPlaylistParserError, .invalidMetadata)
            }
        }

        for tileDuration in ["nan", "inf", "-1", "1000000000"] {
            let invalidTileDuration = """
            #EXTM3U
            #EXTINF:1000,
            #EXT-X-TILES:RESOLUTION=320x180,LAYOUT=10x10,DURATION=\(tileDuration)
            tile.jpg
            """
            XCTAssertThrowsError(try JellyfinTrickPlayPlaylistParser.parse(invalidTileDuration)) { error in
                XCTAssertEqual(error as? JellyfinTrickPlayPlaylistParserError, .invalidMetadata)
            }
        }
    }

    func testJellyfinPlaylistRejectsInvalidResolutionAndLayout() {
        let invalidMetadata = [
            "#EXT-X-TILES:RESOLUTION=-1x180,LAYOUT=10x10,DURATION=10",
            "#EXT-X-TILES:RESOLUTION=999999x180,LAYOUT=10x10,DURATION=10",
            "#EXT-X-TILES:RESOLUTION=320xBADx180,LAYOUT=10x10,DURATION=10",
            "#EXT-X-TILES:RESOLUTION=320x180,LAYOUT=-1x10,DURATION=10",
            "#EXT-X-TILES:RESOLUTION=320x180,LAYOUT=1000x1000,DURATION=10",
            "#EXT-X-TILES:RESOLUTION=320x180,LAYOUT=10xBADx10,DURATION=10",
        ]
        for tileMetadata in invalidMetadata {
            let playlist = """
            #EXTM3U
            #EXTINF:1000,
            \(tileMetadata)
            tile.jpg
            """
            XCTAssertThrowsError(try JellyfinTrickPlayPlaylistParser.parse(playlist)) { error in
                XCTAssertEqual(error as? JellyfinTrickPlayPlaylistParserError, .invalidMetadata)
            }
        }
    }

    func testJellyfinPlaylistRejectsMetadataMultiplicationOverflow() {
        let playlist = """
        #EXTM3U
        #EXTINF:1000,
        #EXT-X-TILES:RESOLUTION=320x180,LAYOUT=\(Int.max)x2,DURATION=10
        tile.jpg
        """

        XCTAssertThrowsError(try JellyfinTrickPlayPlaylistParser.parse(playlist)) { error in
            XCTAssertEqual(error as? JellyfinTrickPlayPlaylistParserError, .arithmeticOverflow)
        }
    }

    func testJellyfinPlaylistRejectsAbsurdCumulativeTimeline() {
        let segment = """
        #EXTINF:604800,
        #EXT-X-TILES:RESOLUTION=320x180,LAYOUT=10x10,DURATION=10
        """
        let playlist = "#EXTM3U\n" + (0..<5).map { "\(segment)tile-\($0).jpg\n" }.joined()

        XCTAssertThrowsError(try JellyfinTrickPlayPlaylistParser.parse(playlist)) { error in
            XCTAssertEqual(error as? JellyfinTrickPlayPlaylistParserError, .invalidMetadata)
        }
    }

    func testJellyfinTileModelMathDoesNotTrapOnExtremeInputs() {
        let tile = JellyfinTrickPlayTile(uri: "tile.jpg",
                                        startMs: Int.max,
                                        durationMs: Int.max,
                                        tileDurationMs: Int.max,
                                        tileWidth: Int.max,
                                        tileHeight: Int.max,
                                        columns: Int.max,
                                        rows: Int.max)

        XCTAssertLessThanOrEqual(tile.frameCapacity, 100_000)
        XCTAssertEqual(tile.frameIndex(nearMs: Int.min), 0)
        XCTAssertLessThanOrEqual(tile.frameTimeMs(frameIndex: Int.max), tile.startMs + tile.durationMs - 1)
    }

}

private func makeBIF(intervalMs: UInt32,
                     frames: [(timestamp: UInt32, payload: Data)]) -> Data {
    precondition(!frames.isEmpty)
    var data = Data()
    data.append(contentsOf: [0x89, 0x42, 0x49, 0x46, 0x0D, 0x0A, 0x1A, 0x0A])
    data.append(littleEndian(0))
    data.append(littleEndian(UInt32(frames.count)))
    data.append(littleEndian(intervalMs))
    data.append(Data(repeating: 0, count: 64 - data.count))

    let tableLength = (frames.count + 1) * 8
    var offset = UInt32(64 + tableLength)
    for frame in frames {
        data.append(littleEndian(frame.timestamp))
        data.append(littleEndian(offset))
        offset += UInt32(frame.payload.count)
    }
    data.append(littleEndian(UInt32.max))
    data.append(littleEndian(offset))

    for frame in frames {
        data.append(frame.payload)
    }
    return data
}

private func littleEndian(_ value: UInt32) -> Data {
    Data([
        UInt8(value & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 24) & 0xff),
    ])
}
