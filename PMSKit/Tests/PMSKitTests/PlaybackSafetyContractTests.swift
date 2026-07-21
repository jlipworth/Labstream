import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PMSKit

@Suite("Playback safety contracts")
struct PlaybackSafetyContractTests {
    @Test func itemlessReopenCloseKeepsHeldTerminalProgress() {
        let terminal = PlaybackTerminalPositionPolicy.position(
            liveClockMs: 0,
            liveClockIsTrustworthy: false,
            heldTargetMs: 127_000,
            lastTrustworthyMs: 126_500,
            savedOffsetMs: 45_000)

        #expect(terminal == 127_000)
    }

    @Test func terminalProgressFallsBackWithoutRegressingToDetachedZero() {
        let terminal = PlaybackTerminalPositionPolicy.position(
            liveClockMs: 0,
            liveClockIsTrustworthy: false,
            heldTargetMs: nil,
            lastTrustworthyMs: 126_500,
            savedOffsetMs: 45_000)

        #expect(terminal == 126_500)
    }

    @Test func explicitTrustworthySeekToStartRemainsAuthoritative() {
        let terminal = PlaybackTerminalPositionPolicy.position(
            liveClockMs: 0,
            liveClockIsTrustworthy: true,
            heldTargetMs: 127_000,
            lastTrustworthyMs: 126_500,
            savedOffsetMs: 45_000)

        #expect(terminal == 0)
    }

    @Test func mediaBrowserPlayingIsCommittedOnlyAfterAccepted2xx() async throws {
        var authority = MediaBrowserPlaybackStartAuthority()
        let request = URLRequest(url: URL(string: "https://media.example.test/Sessions/Playing")!)

        let firstAttempt = authority.event(for: .playing, sessionKey: "session-a")
        #expect(firstAttempt == .playing)

        let rejected = MediaBrowserRequestExecutor { _ in
            (Data(), Self.httpResponse(status: 500))
        }
        do {
            _ = try await rejected.send(request)
            authority.recordAccepted(event: firstAttempt, sessionKey: "session-a")
            Issue.record("Expected the rejected Playing request to throw")
        } catch let error as MediaBrowserRequestError {
            #expect(error == .httpStatus(500))
        }

        // A rejected send cannot reach recordAccepted, so the next coalesced heartbeat remains
        // the required Playing handshake instead of skipping ahead to Progress.
        let retryAfterFailure = authority.event(for: .buffering, sessionKey: "session-a")
        #expect(retryAfterFailure == .playing)

        let accepted = MediaBrowserRequestExecutor { _ in
            (Data(), Self.httpResponse(status: 204))
        }
        _ = try await accepted.send(request)
        authority.recordAccepted(event: retryAfterFailure, sessionKey: "session-a")
        #expect(authority.event(for: .playing, sessionKey: "session-a") == .progress)
    }

    @Test func staleAcceptedPlayingCannotStartReplacementSession() {
        var authority = MediaBrowserPlaybackStartAuthority()
        #expect(authority.event(for: .playing, sessionKey: "session-a") == .playing)
        #expect(authority.event(for: .playing, sessionKey: "session-b") == .playing)

        authority.recordAccepted(event: .playing, sessionKey: "session-a")

        #expect(authority.event(for: .playing, sessionKey: "session-b") == .playing)
    }

    private static func httpResponse(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://media.example.test/Sessions/Playing")!,
                        statusCode: status,
                        httpVersion: "HTTP/1.1",
                        headerFields: nil)!
    }
}
