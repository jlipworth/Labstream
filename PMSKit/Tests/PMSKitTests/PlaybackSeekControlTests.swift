import Testing
@testable import PMSKit

@Suite("Playback seek controls")
struct PlaybackSeekControlTests {
    @Test func clampsTargetsIntoKnownDuration() {
        #expect(PlaybackSeekControl.clamp(targetMs: -1_000, durationMs: 7_200_000) == 0)
        #expect(PlaybackSeekControl.clamp(targetMs: 2_929_000, durationMs: 7_200_000) == 2_929_000)
        #expect(PlaybackSeekControl.clamp(targetMs: 7_300_000, durationMs: 7_200_000) == 7_200_000)
    }

    @Test func leavesPositiveTargetsAloneWhenDurationIsUnknown() {
        #expect(PlaybackSeekControl.clamp(targetMs: 2_929_000, durationMs: nil) == 2_929_000)
    }

    @Test func formatsMillisecondsForJumpControl() {
        #expect(PlaybackSeekControl.timecode(ms: 65_000) == "1:05")
        #expect(PlaybackSeekControl.timecode(ms: 2_929_000) == "48:49")
        #expect(PlaybackSeekControl.timecode(ms: 3_665_000) == "1:01:05")
    }
}
