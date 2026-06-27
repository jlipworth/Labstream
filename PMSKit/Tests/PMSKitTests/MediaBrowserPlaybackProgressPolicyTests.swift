import Testing
@testable import PMSKit

@Suite("MediaBrowser playback progress policy")
struct MediaBrowserPlaybackProgressPolicyTests {
    @Test func convertsMillisecondsToServerTicks() {
        #expect(MediaBrowserPlaybackProgressPolicy.positionTicks(milliseconds: 0) == 0)
        #expect(MediaBrowserPlaybackProgressPolicy.positionTicks(milliseconds: 1) == 10_000)
        #expect(MediaBrowserPlaybackProgressPolicy.positionTicks(milliseconds: 12_345) == 123_450_000)
        #expect(MediaBrowserPlaybackProgressPolicy.positionTicks(milliseconds: -500) == 0)
    }

    @Test func firstNonStoppedReportStartsTheSession() {
        #expect(MediaBrowserPlaybackProgressPolicy.event(for: .playing,
                                                         hasStartedSession: false) == .playing)
        #expect(MediaBrowserPlaybackProgressPolicy.event(for: .paused,
                                                         hasStartedSession: false) == .playing)
        #expect(MediaBrowserPlaybackProgressPolicy.event(for: .buffering,
                                                         hasStartedSession: false) == .playing)
    }

    @Test func subsequentNonStoppedReportsAreProgressHeartbeats() {
        #expect(MediaBrowserPlaybackProgressPolicy.event(for: .playing,
                                                         hasStartedSession: true) == .progress)
        #expect(MediaBrowserPlaybackProgressPolicy.event(for: .paused,
                                                         hasStartedSession: true) == .progress)
        #expect(MediaBrowserPlaybackProgressPolicy.event(for: .buffering,
                                                         hasStartedSession: true) == .progress)
    }

    @Test func stoppedAlwaysBuildsAStoppedEvent() {
        #expect(MediaBrowserPlaybackProgressPolicy.event(for: .stopped,
                                                         hasStartedSession: false) == .stopped)
        #expect(MediaBrowserPlaybackProgressPolicy.event(for: .stopped,
                                                         hasStartedSession: true) == .stopped)
    }
}
