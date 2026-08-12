import Foundation
import PMSKit
import Testing
@testable import Labstream

@MainActor
struct PlaybackSessionSourceTests {
    @Test func sourceKindsExposeOnlyTheirShippedCapabilities() throws {
        let server = try #require(URL(string: "https://media.example.test"))
        let file = URL(fileURLWithPath: "/tmp/offline-video.mkv")
        let identity = ClientIdentity(clientIdentifier: "device-1",
                                      product: "Labstream",
                                      version: "1",
                                      deviceName: "Test Device")
        let progress = MediaBrowserPlaybackProgressSession(
            backend: .jellyfin,
            server: server,
            token: "token",
            userID: "user-1",
            identity: identity,
            itemID: "item-1",
            mediaSourceID: "source-1",
            playSessionID: "play-1",
            playMethod: .transcode)
        let mediaBrowser = MediaBrowserPlaybackSession(
            streamURL: try #require(URL(string: "https://media.example.test/master.m3u8")),
            backend: .jellyfin,
            backendLabel: "Jellyfin",
            httpHeaders: ["X-MediaBrowser-Token": "token"],
            playSessionID: "play-1",
            sourceMetadata: .empty,
            playMethod: .transcode,
            transcodeReasons: [],
            progressSession: progress,
            onStop: {},
            reopener: { _ in
                RemoteStreamOpenResult(
                    url: try #require(URL(string: "https://media.example.test/reopened.m3u8")),
                    headers: [:])
            })

        let plex = PlaybackSessionSource.plex(PlexPlaybackSession(server: server, token: "token"))
        let remote = PlaybackSessionSource.mediaBrowser(mediaBrowser)
        let offline = PlaybackSessionSource.offline(OfflinePlaybackSession(fileURL: file))

        #expect(plex.kind == .plex)
        #expect(plex.pathMode == "plex_stream")
        #expect(plex.supportsStreamReopen)
        #expect(remote.kind == .mediaBrowser)
        #expect(mediaBrowser.backend == .jellyfin)
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

    @Test func mediaBrowserCarrierKeepsReopenProgressAndCleanupAuthorityTogether() async throws {
        let server = try #require(URL(string: "https://media.example.test"))
        let stream = try #require(URL(string: "https://media.example.test/master.m3u8"))
        let identity = ClientIdentity(clientIdentifier: "device-1",
                                      product: "Labstream",
                                      version: "1",
                                      deviceName: "Test Device")
        let progress = MediaBrowserPlaybackProgressSession(
            backend: .emby,
            server: server,
            token: "token",
            userID: "user-1",
            identity: identity,
            itemID: "item-1",
            mediaSourceID: "source-1",
            playSessionID: "play-1",
            playMethod: .directStream)
        var stopped = false
        let session = MediaBrowserPlaybackSession(
            streamURL: stream,
            backend: .emby,
            backendLabel: "Emby",
            httpHeaders: ["X-Emby-Token": "token"],
            playSessionID: "play-1",
            sourceMetadata: .empty,
            playMethod: .directStream,
            transcodeReasons: ["ContainerBitrateExceedsLimit"],
            progressSession: progress,
            onStop: { stopped = true },
            reopener: { request in
                #expect(request.offsetMs == 42_000)
                return RemoteStreamOpenResult(url: stream, headers: [:])
            })

        #expect(session.initialStreamURL == stream)
        #expect(session.backend == .emby)
        #expect(session.progressSession == progress)
        #expect(session.playSessionID == "play-1")
        _ = try await session.reopener(RemoteStreamReopenRequest(offsetMs: 42_000,
                                                                 bitrateKbps: 8_000))
        session.onStop?()
        #expect(stopped)
    }
}
