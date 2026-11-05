import Foundation
import Testing
@testable import PMSKit

/// B56 (P5): MediaBrowser items carry their MediaSource `Size`, so storage gates see the real size
/// of a Jellyfin/Emby original instead of an unknown one.
@Suite("MediaBrowser source size (B56)")
struct MediaBrowserSourceSizeTests {
    private func part(_ sizeJSON: String) throws -> Part? {
        let dto = try JSONDecoder().decode(JellyfinBaseItemDto.self, from: Data("""
        {
          "Id": "movie-1", "Name": "Fixture", "Type": "Movie",
          "MediaSources": [ { "Id": "source-1", "Container": "mkv"\(sizeJSON),
                              "MediaStreams": [ {"Type":"Video","Codec":"hevc"} ] } ]
        }
        """.utf8))
        return dto.toMediaItem()?.media?.first?.part.first
    }

    @Test func sizeIsDecodedIncludingLargeFiles() throws {
        #expect(try part(#", "Size": 421415383"#)?.size == 421_415_383)
        #expect(try part(#", "Size": 64424509440"#)?.size == 64_424_509_440)
    }

    @Test func missingNullOrZeroSizeStaysUnknown() throws {
        #expect(try part("")?.size == nil)
        #expect(try part(#", "Size": null"#)?.size == nil)
        #expect(try part(#", "Size": 0"#)?.size == nil)
    }

    @Test func embyFlavorDecodesTheSameField() throws {
        let dto = try JSONDecoder().decode(EmbyBaseItemDto.self, from: Data("""
        { "Id": "movie-2", "Name": "Fixture", "Type": "Movie",
          "MediaSources": [ { "Id": "s", "Container": "mp4", "Size": 1288179275, "MediaStreams": [] } ] }
        """.utf8))
        #expect(dto.toMediaItem()?.media?.first?.part.first?.size == 1_288_179_275)
    }
}
