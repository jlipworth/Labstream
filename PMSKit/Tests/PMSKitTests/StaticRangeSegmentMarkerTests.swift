import Testing
@testable import PMSKit

@Suite("Static range segment marker")
struct StaticRangeSegmentMarkerTests {
    @Test("Current marker round-trips offset and exact attempt")
    func currentRoundTrips() {
        let attemptID = DownloadAttemptID(rawValue: "attempt-A")!
        let marker = StaticRangeSegmentMarker.value(offset: 512, attemptID: attemptID)
        #expect(marker == "lbs-segment:v3:512:attempt-A")
        #expect(StaticRangeSegmentMarker.parse(marker) == 512)
        #expect(StaticRangeSegmentMarker.attemptIdentity(marker) == attemptID)
        #expect(StaticRangeSegmentMarker.version(marker) == .currentV3)
        #expect(BackgroundDownloadTaskIdentity.markerVersion(taskDescription: marker)
                == .currentSegmentV3)
    }

    @Test("String convenience also emits only current marker")
    func stringBuilderIsCurrent() {
        let marker = StaticRangeSegmentMarker.value(offset: 512, attemptID: DownloadAttemptID(rawValue: "attempt-A")!)
        #expect(marker == "lbs-segment:v3:512:attempt-A")
        #expect(StaticRangeSegmentMarker.version(marker) == .currentV3)
    }

    @Test("Combined description round-trips row offset and attempt")
    func combinedDescriptionRoundTrips() {
        let description = StaticRangeSegmentMarker.taskDescription(
            ratingKey: "movie-123", offset: 536_870_912, attemptID: DownloadAttemptID(rawValue: "attempt-A")!)
        #expect(StaticRangeSegmentMarker.parse(description) == 536_870_912)
        #expect(StaticRangeSegmentMarker.attemptIdentity(description) ==
            DownloadAttemptID(rawValue: "attempt-A"))
        #expect(StaticRangeSegmentMarker.ratingKey(fromTaskDescription: description) == "movie-123")
    }

    @Test("v1 v2 and malformed segment markers are not parsed")
    func legacyAndMalformedAreRejected() {
        for marker in [
            "lbs-segment:v1:512", "lbs-segment:v2:512:attempt-A",
            "lbs-segment:v3:", "lbs-segment:v3:abc:attempt-A",
            "lbs-segment:v3:-1:attempt-A", "lbs-segment:v3:512:",
        ] {
            #expect(StaticRangeSegmentMarker.parse(marker) == nil)
            #expect(StaticRangeSegmentMarker.attemptIdentity(marker) == nil)
            #expect(StaticRangeSegmentMarker.version(marker) == nil)
        }
    }

    @Test("Plain rating keys remain unchanged")
    func plainRatingKey() {
        #expect(StaticRangeSegmentMarker.ratingKey(fromTaskDescription: "movie-123") == "movie-123")
        #expect(StaticRangeSegmentMarker.parse("movie-123") == nil)
    }
}

@Suite("Download attempt marker")
struct DownloadAttemptMarkerTests {
    @Test("Current marker round-trips key and exact attempt")
    func roundTrips() {
        let attemptID = DownloadAttemptID(rawValue: "attempt-A")!
        let description = DownloadAttemptMarker.taskDescription(
            ratingKey: "movie-123", attemptID: attemptID)
        #expect(description.contains("lbs-attempt:v2:attempt-A"))
        #expect(DownloadAttemptMarker.attemptIdentity(fromTaskDescription: description) == attemptID)
        #expect(DownloadAttemptMarker.ratingKey(fromTaskDescription: description) == "movie-123")
        #expect(DownloadAttemptMarker.version(fromTaskDescription: description) == .currentV2)
    }

    @Test("String convenience emits current and v1 is rejected")
    func stringBuilderIsCurrentAndLegacyRejected() {
        let current = DownloadAttemptMarker.taskDescription(
            ratingKey: "movie-123", attemptID: DownloadAttemptID(rawValue: "attempt-A")!)
        #expect(current.contains("lbs-attempt:v2:attempt-A"))
        #expect(DownloadAttemptMarker.version(fromTaskDescription: current) == .currentV2)
        let legacy = "movie-123\u{1F}lbs-attempt:v1:attempt-A"
        #expect(DownloadAttemptMarker.attemptIdentity(fromTaskDescription: legacy) == nil)
        #expect(DownloadAttemptMarker.version(fromTaskDescription: legacy) == nil)
    }

    @Test("Unified identity accessor reads both current lanes")
    func unifiedAttemptAccessor() {
        let segment = StaticRangeSegmentMarker.taskDescription(
            ratingKey: "movie-123", offset: 512, attemptID: DownloadAttemptID(rawValue: "attempt-A")!)
        let opaque = DownloadAttemptMarker.taskDescription(
            ratingKey: "movie-123", attemptID: DownloadAttemptID(rawValue: "attempt-B")!)
        #expect(BackgroundDownloadTaskIdentity.attemptIdentity(taskDescription: segment) ==
            DownloadAttemptID(rawValue: "attempt-A"))
        #expect(BackgroundDownloadTaskIdentity.attemptIdentity(taskDescription: opaque) ==
            DownloadAttemptID(rawValue: "attempt-B"))
        #expect(BackgroundDownloadTaskIdentity.attemptIdentity(
            taskDescription: "movie-123") == nil)
    }
}
