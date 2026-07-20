import Foundation
import Testing
@testable import PMSKit

@Suite("MediaBrowser watched state mapping")
struct MediaBrowserWatchedStateMappingTests {
    @Test(arguments: [
        (#"{"Id":"one","Name":"One","Type":"Episode","UserData":{"Played":true}}"#, Optional(1)),
        (#"{"Id":"two","Name":"Two","Type":"Episode","UserData":{"Played":false}}"#, Optional(0)),
        (#"{"Id":"three","Name":"Three","Type":"Episode","UserData":{}}"#, Optional<Int>.none),
        (#"{"Id":"four","Name":"Four","Type":"Episode"}"#, Optional<Int>.none),
    ])
    func jellyfinPlayedRemainsTriState(json: String, expected: Int?) throws {
        let dto = try JSONDecoder().decode(JellyfinBaseItemDto.self, from: Data(json.utf8))
        let item = try #require(dto.toMediaItem())
        #expect(item.viewCount == expected)
    }
}
