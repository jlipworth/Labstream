import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PMSKit

@Suite("MediaBrowser playback progress request plan")
struct MediaBrowserPlaybackProgressRequestPlanTests {
    private enum Backend: String {
        case jellyfin
        case emby
    }

    private struct GoldenCase {
        let backend: Backend
        let event: MediaBrowserPlaybackProgressRequestEvent
        let expectedPath: String
        let expectedBody: String
    }

    @Test func backendWrappersPreserveGoldenWireShapeForEveryEvent() throws {
        let cases = [Backend.jellyfin, .emby].flatMap { backend in
            [
                GoldenCase(backend: backend,
                           event: .playing,
                           expectedPath: "/Sessions/Playing",
                           expectedBody: Self.body(backend: backend, isPaused: false)),
                GoldenCase(backend: backend,
                           event: .progress,
                           expectedPath: "/Sessions/Playing/Progress",
                           expectedBody: Self.body(backend: backend, isPaused: false)),
                GoldenCase(backend: backend,
                           event: .paused,
                           expectedPath: "/Sessions/Playing/Progress",
                           expectedBody: Self.body(backend: backend, isPaused: true)),
                GoldenCase(backend: backend,
                           event: .stopped,
                           expectedPath: "/Sessions/Playing/Stopped",
                           expectedBody: Self.body(backend: backend, isPaused: false)),
            ]
        }

        for golden in cases {
            let request = try wrapperRequest(backend: golden.backend, event: golden.event)
            let url = request.url!

            #expect(request.httpMethod == "POST",
                    Comment(rawValue: "\(golden.backend.rawValue) \(golden.event) method"))
            #expect(url.scheme == "https")
            #expect(url.host == "\(golden.backend.rawValue).example.test")
            #expect(url.path == "/base\(golden.expectedPath)",
                    Comment(rawValue: "\(golden.backend.rawValue) \(golden.event) base-path endpoint"))
            #expect(url.query == nil)
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Authorization") == expectedAuthorization(golden.backend))
            let expectedEmbyToken: String? = golden.backend == Backend.emby ? #"tok"en"# : nil
            #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == expectedEmbyToken)
            #expect(request.httpBody == Data(golden.expectedBody.utf8),
                    Comment(rawValue: "\(golden.backend.rawValue) \(golden.event) body bytes"))

            // Access tokens belong only in the backend auth headers, never the URL or payload.
            #expect(!url.absoluteString.contains(#"tok"en"#))
            #expect(!golden.expectedBody.contains(#"tok"en"#))
        }
    }

    @Test func requestPlanDescriptionCannotLeakTokenOrMediaIdentifiers() throws {
        let plan = MediaBrowserPlaybackProgressRequestPlan(
            url: URL(string: "https://private.example.test/base/Sessions/Playing")!,
            authDialect: .jellyfin(identity),
            event: .playing,
            payload: payload
        )
        _ = try plan.request(token: #"secret"token"#)

        let description = String(describing: plan)
        #expect(description == "MediaBrowserPlaybackProgressRequestPlan(event: playing, auth: jellyfin)")
        #expect(!description.contains("private.example.test"))
        #expect(!description.contains("movie/one"))
        #expect(!description.contains(#"secret"token"#))
    }

    @Test func emptyOptionalAuthValuesRemainOmitted() throws {
        let emptyUserPayload = MediaBrowserPlaybackProgressPayload(
            userId: "",
            itemId: "item",
            mediaSourceId: "source",
            playSessionId: "session",
            playMethod: .directPlay,
            positionTicks: 0
        )
        for dialect in [MediaBrowserPlaybackProgressAuthDialect.jellyfin(identity), .emby(identity)] {
            let request = try MediaBrowserPlaybackProgressRequestPlan(
                url: URL(string: "https://example.test/Sessions/Playing")!,
                authDialect: dialect,
                event: .playing,
                payload: emptyUserPayload
            ).request(token: "")

            #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=") == false)
            #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("UserId=") == false)
            #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == nil)
            let body = request.httpBody!
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            if case .jellyfin = dialect {
                #expect(object["UserId"] as? String == "")
            } else {
                #expect(object["UserId"] == nil)
            }
        }
    }

    private func wrapperRequest(backend: Backend,
                                event: MediaBrowserPlaybackProgressRequestEvent) throws -> URLRequest {
        switch backend {
        case .jellyfin:
            switch event {
            case .playing:
                return try JellyfinPlayback.playingRequest(
                    server: server(backend), token: #"tok"en"#, identity: identity,
                    userId: payload.userId, itemId: payload.itemId,
                    mediaSourceId: payload.mediaSourceId, playSessionId: payload.playSessionId,
                    playMethod: .directStream, positionTicks: payload.positionTicks)
            case .progress, .paused:
                return try JellyfinPlayback.progressRequest(
                    server: server(backend), token: #"tok"en"#, identity: identity,
                    userId: payload.userId, itemId: payload.itemId,
                    mediaSourceId: payload.mediaSourceId, playSessionId: payload.playSessionId,
                    playMethod: .directStream, positionTicks: payload.positionTicks,
                    isPaused: event == .paused)
            case .stopped:
                return try JellyfinPlayback.stoppedRequest(
                    server: server(backend), token: #"tok"en"#, identity: identity,
                    userId: payload.userId, itemId: payload.itemId,
                    mediaSourceId: payload.mediaSourceId, playSessionId: payload.playSessionId,
                    playMethod: .directStream, positionTicks: payload.positionTicks)
            }
        case .emby:
            switch event {
            case .playing:
                return try EmbyPlayback.playingRequest(
                    server: server(backend), token: #"tok"en"#, identity: identity,
                    userId: payload.userId, itemId: payload.itemId,
                    mediaSourceId: payload.mediaSourceId, playSessionId: payload.playSessionId,
                    playMethod: .directStream, positionTicks: payload.positionTicks)
            case .progress, .paused:
                return try EmbyPlayback.progressRequest(
                    server: server(backend), token: #"tok"en"#, identity: identity,
                    userId: payload.userId, itemId: payload.itemId,
                    mediaSourceId: payload.mediaSourceId, playSessionId: payload.playSessionId,
                    playMethod: .directStream, positionTicks: payload.positionTicks,
                    isPaused: event == .paused)
            case .stopped:
                return try EmbyPlayback.stoppedRequest(
                    server: server(backend), token: #"tok"en"#, identity: identity,
                    userId: payload.userId, itemId: payload.itemId,
                    mediaSourceId: payload.mediaSourceId, playSessionId: payload.playSessionId,
                    playMethod: .directStream, positionTicks: payload.positionTicks)
            }
        }
    }

    private static func body(backend: Backend, isPaused: Bool) -> String {
        let user = backend == .jellyfin ? ",\"UserId\":\"user & one\"" : ""
        return #"{"IsPaused":\#(isPaused),"ItemId":"movie\/one","MediaSourceId":"source+one","PlayMethod":"DirectStream","PlaySessionId":"play\"one","PositionTicks":123450000\#(user)}"#
    }

    private func expectedAuthorization(_ backend: Backend) -> String {
        switch backend {
        case .jellyfin:
            return #"MediaBrowser Client="Lab stream", Device="Vision/Pro", DeviceId="device+1", Version="1.2.3", Token="tok\"en""#
        case .emby:
            return #"Emby UserId="user & one", Client="Lab stream", Device="Vision/Pro", DeviceId="device+1", Version="1.2.3", Token="tok\"en""#
        }
    }

    private var identity: MediaBrowserClientIdentity {
        MediaBrowserClientIdentity(client: "Lab stream",
                                   device: "Vision/Pro",
                                   deviceId: "device+1",
                                   version: "1.2.3")
    }

    private var payload: MediaBrowserPlaybackProgressPayload {
        MediaBrowserPlaybackProgressPayload(userId: "user & one",
                                            itemId: "movie/one",
                                            mediaSourceId: "source+one",
                                            playSessionId: #"play"one"#,
                                            playMethod: .directStream,
                                            positionTicks: 123_450_000)
    }

    private func server(_ backend: Backend) -> URL {
        URL(string: "https://\(backend.rawValue).example.test/base")!
    }
}
