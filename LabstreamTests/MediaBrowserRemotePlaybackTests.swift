import Foundation
import PMSKit
import Testing
@testable import Labstream

@MainActor
struct MediaBrowserRemotePlaybackTests {
    @Test func backendTaggedRemotePreservesEveryNeutralPlaybackFact() throws {
        let url = try #require(URL(string: "https://media.example.test/video/master.m3u8"))
        let source = MediaBrowserPlaybackSourceMetadata(container: "mkv",
                                                        width: 3840,
                                                        height: 2160,
                                                        bitrate: 40_000,
                                                        videoCodec: "hevc",
                                                        audioCodec: "truehd")
        let result = MediaBrowserPlaybackOpenResult(url: url,
                                                    playSessionId: "play-1",
                                                    mediaSourceId: "source-1",
                                                    playMethod: .transcode,
                                                    requiredHTTPHeaders: ["X-Required": "yes"],
                                                    sourceMetadata: source,
                                                    usesServerEncoding: true,
                                                    transcodeReasons: ["AudioCodecNotSupported"])
        let context = try playbackContext(backend: .emby)
        let remote = MediaBrowserRemotePlayback(context: context, result: result, mediaIndex: 2)

        #expect(remote.backend == .emby)
        #expect(remote.context == context)
        #expect(remote.url == url)
        #expect(remote.headers == ["X-Required": "yes"])
        #expect(remote.playSessionId == "play-1")
        #expect(remote.mediaSourceId == "source-1")
        #expect(remote.mediaIndex == 2)
        #expect(remote.playMethod == .transcode)
        #expect(remote.sourceMetadata == source)
        #expect(remote.usesServerEncoding)
        #expect(remote.transcodeReasons == ["AudioCodecNotSupported"])
    }

    @Test func cleanupPolicyPreservesBackendSpecificBehavior() throws {
        let url = try #require(URL(string: "https://media.example.test/video.mp4"))
        let direct = MediaBrowserPlaybackOpenResult(url: url,
                                                    playSessionId: "play-direct",
                                                    mediaSourceId: "source-direct",
                                                    playMethod: .directPlay,
                                                    usesServerEncoding: false)

        #expect(MediaBrowserRemotePlayback(
            context: try playbackContext(backend: .jellyfin), result: direct
        ).requiresActiveEncodingStop)
        #expect(!MediaBrowserRemotePlayback(
            context: try playbackContext(backend: .emby), result: direct
        ).requiresActiveEncodingStop)
    }

    @Test func heldOpenAuthSwitchRejectsStaleSuccessAndCleansExactRemote() async throws {
        let appModel = configuredAppModel(token: "token-A")
        let captured = try DetailPlaybackLauncher.context(backend: .jellyfin, appModel: appModel)
        let held = HeldOpen()
        let task = Task { try await held.value() }
        await Task.yield()

        appModel.jellyfinAccessToken = "token-B"
        appModel.jellyfinAccessToken = "token-A"
        let opened = DetailRemotePlaybackOpen(
            playback: MediaBrowserRemotePlayback(
                context: captured,
                result: try openResult(playSessionID: "stale-session")),
            playMethod: MediaBrowserPlayMethod.transcode.rawValue)
        held.resume(.success(opened))

        let completed = try await task.value
        var cleaned: MediaBrowserRemotePlayback?
        let accepted = await DetailPlaybackLauncher.acceptInitialOpen(
            completed, requestStillCurrent: true, appModel: appModel,
            cleanup: { cleaned = $0 })

        #expect(!accepted)
        #expect(cleaned == completed.playback)
        #expect(cleaned?.context.session.token == "token-A")
        #expect(!captured.isCurrent(in: appModel))
    }

    @Test func heldOpenStaleFailureDoesNotSurfaceOnCurrentDetail() async throws {
        let appModel = configuredAppModel(token: "token-A")
        let captured = try DetailPlaybackLauncher.context(backend: .jellyfin, appModel: appModel)
        let held = HeldOpen()
        let task = Task { try await held.value() }
        await Task.yield()

        appModel.jellyfinAccessToken = "token-B"
        appModel.jellyfinAccessToken = "token-A"
        held.resume(.failure(HeldFailure.expected))
        do {
            _ = try await task.value
            Issue.record("Expected held open failure")
        } catch {
            #expect(!DetailPlaybackLauncher.shouldSurfaceOpenFailure(
                requestStillCurrent: true, context: captured, appModel: appModel))
        }
    }

    @Test func heldMetadataAuthSwitchAndViewInvalidationRejectBeforeOpen() async throws {
        let appModel = configuredAppModel(token: "token-A")
        let captured = try DetailPlaybackLauncher.context(backend: .jellyfin, appModel: appModel)
        let held = HeldMetadata()
        let task = Task { await held.value() }
        await Task.yield()

        // Return to byte-for-byte equal credentials to prove the auth revision, not merely token
        // comparison, invalidates metadata minted by the abandoned generation.
        appModel.jellyfinAccessToken = "token-B"
        appModel.jellyfinAccessToken = "token-A"
        held.resume(MediaItem(ratingKey: "item-1", title: "Held metadata", type: "movie"))
        _ = await task.value

        #expect(!DetailPlaybackLauncher.shouldContinueAfterMetadata(
            requestStillCurrent: true, context: captured, appModel: appModel))
        let current = try DetailPlaybackLauncher.context(backend: .jellyfin, appModel: appModel)
        #expect(!DetailPlaybackLauncher.shouldContinueAfterMetadata(
            requestStillCurrent: false, context: current, appModel: appModel))
    }

    private func configuredAppModel(token: String) -> AppModel {
        let model = AppModel(identity: identity(), activeBackend: .jellyfin)
        model.jellyfinServerBaseURL = URL(string: "https://jellyfin.example.test")!
        model.jellyfinAccessToken = token
        model.jellyfinUserID = "user-1"
        model.jellyfinServerID = "server-1"
        return model
    }

    private func playbackContext(backend: MediaBackendKind) throws -> MediaBrowserPlaybackContext {
        let baseURL = try #require(URL(string: "https://media.example.test"))
        return MediaBrowserPlaybackContext(
            backend: backend,
            session: BackendSession(kind: backend.downloadBackendKind,
                                    baseURL: baseURL,
                                    token: "token-A",
                                    userID: "user-1",
                                    serverID: "server-1"),
            authRevision: 7,
            identity: identity())
    }

    private func identity() -> ClientIdentity {
        ClientIdentity(clientIdentifier: "device-1", product: "Labstream", version: "1",
                       deviceName: "Test Device")
    }

    private func openResult(playSessionID: String) throws -> MediaBrowserPlaybackOpenResult {
        MediaBrowserPlaybackOpenResult(
            url: try #require(URL(string: "https://media.example.test/master.m3u8")),
            playSessionId: playSessionID,
            mediaSourceId: "source-1",
            playMethod: .transcode,
            usesServerEncoding: true)
    }
}

@MainActor
private final class HeldOpen {
    private var continuation: CheckedContinuation<DetailRemotePlaybackOpen, Error>?

    func value() async throws -> DetailRemotePlaybackOpen {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func resume(_ result: Result<DetailRemotePlaybackOpen, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

@MainActor
private final class HeldMetadata {
    private var continuation: CheckedContinuation<MediaItem, Never>?

    func value() async -> MediaItem {
        await withCheckedContinuation { continuation = $0 }
    }

    func resume(_ value: MediaItem) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

private enum HeldFailure: Error {
    case expected
}
