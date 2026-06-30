import Foundation
import Testing
@testable import PMSKit

@Suite("Background download task identity")
struct BackgroundDownloadTaskIdentityTests {

    @Test("Task description wins when it matches a known row key")
    func taskDescriptionWins() {
        let resolved = BackgroundDownloadTaskIdentity.ratingKey(
            taskDescription: "plex:movie",
            requestURL: URL(string: "https://example.test/Items/jellyfin-movie/Download"),
            knownKeys: ["plex:movie", "jellyfin:jellyfin-movie"]
        )

        #expect(resolved == "plex:movie")
    }

    @Test("Plex path query resolves the metadata key")
    func plexPathQueryResolvesBareKey() {
        let resolved = BackgroundDownloadTaskIdentity.ratingKey(
            taskDescription: nil,
            requestURL: URL(string: "https://plex.example/video/:/transcode/universal/start.m3u8?path=%2Flibrary%2Fmetadata%2F1234"),
            knownKeys: ["1234"]
        )

        #expect(resolved == "1234")
    }

    @Test("Plex path query can resolve legacy Jellyfin-prefixed rows")
    func pathQueryResolvesJellyfinPrefixedKey() {
        let resolved = BackgroundDownloadTaskIdentity.ratingKey(
            taskDescription: nil,
            requestURL: URL(string: "https://media.example/download?path=%2FItems%2Fabcd"),
            knownKeys: ["jellyfin:abcd"]
        )

        #expect(resolved == "jellyfin:abcd")
    }

    @Test("Jellyfin Items path resolves bare and prefixed known keys")
    func jellyfinItemsPathResolves() {
        let bare = BackgroundDownloadTaskIdentity.ratingKey(
            taskDescription: nil,
            requestURL: URL(string: "https://jellyfin.example/Items/item-1/Download"),
            knownKeys: ["item-1"]
        )
        let prefixed = BackgroundDownloadTaskIdentity.ratingKey(
            taskDescription: nil,
            requestURL: URL(string: "https://jellyfin.example/Items/item-2/Download"),
            knownKeys: ["jellyfin:item-2"]
        )

        #expect(bare == "item-1")
        #expect(prefixed == "jellyfin:item-2")
    }

    @Test("Jellyfin Videos path resolves the video id")
    func jellyfinVideosPathResolves() {
        let resolved = BackgroundDownloadTaskIdentity.ratingKey(
            taskDescription: nil,
            requestURL: URL(string: "https://jellyfin.example/Videos/video-1/stream.mp4"),
            knownKeys: ["video-1"]
        )

        #expect(resolved == "video-1")
    }

    @Test("Plex part URLs require task description because source key is absent")
    func plexPartURLDoesNotInferKey() {
        let withoutDescription = BackgroundDownloadTaskIdentity.ratingKey(
            taskDescription: nil,
            requestURL: URL(string: "https://plex.example/library/parts/9876/file.mp4"),
            knownKeys: ["movie-123"]
        )
        let withDescription = BackgroundDownloadTaskIdentity.ratingKey(
            taskDescription: "movie-123",
            requestURL: URL(string: "https://plex.example/library/parts/9876/file.mp4"),
            knownKeys: ["movie-123"]
        )

        #expect(withoutDescription == nil)
        #expect(withDescription == "movie-123")
    }
}
