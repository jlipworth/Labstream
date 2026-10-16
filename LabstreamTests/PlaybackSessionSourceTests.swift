import Foundation
import PMSKit
import Testing
@testable import Labstream

@MainActor
struct PlaybackSessionSourceTests {
    @Test func sourceKindsExposeOnlyTheirShippedCapabilities() throws {
        let server = try #require(URL(string: "https://media.example.test"))
        let file = URL(fileURLWithPath: "/tmp/offline-video.mkv")
        let stream = try #require(URL(string: "https://media.example.test/master.m3u8"))
        let mediaBrowser = MediaBrowserPlaybackSession(
            streamURL: stream,
            backendLabel: "Jellyfin",
            httpHeaders: [:],
            playSessionID: "play-1",
            sourceMetadata: .empty,
            playMethod: .transcode,
            transcodeReasons: [],
            progressSession: nil,
            onStop: {},
            reopener: { _ in RemoteStreamOpenResult(url: stream, headers: [:]) })

        let plex = PlaybackSessionSource.plex(PlexPlaybackSession(server: server, token: "token"))
        let remote = PlaybackSessionSource.mediaBrowser(mediaBrowser)
        let offline = PlaybackSessionSource.offline(OfflinePlaybackSession(fileURL: file))

        #expect(plex.kind == .plex)
        #expect(plex.pathMode == "plex_stream")
        #expect(plex.supportsStreamReopen)
        #expect(remote.kind == .mediaBrowser)
        #expect(remote.pathMode == "remote_stream")
        #expect(remote.supportsStreamReopen)
        #expect(offline.kind == .offline)
        #expect(offline.pathMode == "local_file")
        #expect(!offline.supportsStreamReopen)
    }

    @Test func controllerCapabilitiesComeFromTypedSourceRatherThanNilCombinations() throws {
        let server = try #require(URL(string: "https://media.example.test"))
        let identity = ClientIdentity(clientIdentifier: "device-1",
                                      product: "Labstream",
                                      version: "1",
                                      deviceName: "Test Device")
        let client = PlexClient(identity: identity)
        let item = MediaItem(ratingKey: "item-1", title: "Test", type: "movie")

        let plex = PlaybackController(
            item: item,
            sessionSource: .plex(PlexPlaybackSession(server: server, token: "token")),
            identity: identity,
            client: client)
        let offline = PlaybackController(
            item: item,
            sessionSource: .offline(OfflinePlaybackSession(
                fileURL: URL(fileURLWithPath: "/tmp/offline-video.mkv"))),
            identity: identity,
            client: client)

        #expect(plex.isStreaming)
        #expect(plex.supportsQualityReload)
        #expect(plex.supportsMetadataAudioSelection)
        #expect(!offline.isStreaming)
        #expect(!offline.supportsQualityReload)
        #expect(!offline.supportsMetadataAudioSelection)
        #expect(!offline.supportsMetadataSubtitleSelection)
    }
}
