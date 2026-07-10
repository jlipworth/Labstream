import Testing
@testable import PMSKit

@Suite("Static range segment marker")
struct StaticRangeSegmentMarkerTests {
    @Test("Round-trips a valid marker")
    func roundTrips() {
        let marker = StaticRangeSegmentMarker.value(offset: 512)
        #expect(marker == "lbs-segment:v1:512")
        #expect(StaticRangeSegmentMarker.parse(marker) == 512)
    }

    @Test("Round-trips a zero offset")
    func roundTripsZero() {
        let marker = StaticRangeSegmentMarker.value(offset: 0)
        #expect(StaticRangeSegmentMarker.parse(marker) == 0)
    }

    @Test("Combined descriptions expose both the offset and rating key")
    func combinedDescriptionParses() {
        let description = "movie-123\u{1F}lbs-segment:v1:536870912"

        #expect(StaticRangeSegmentMarker.parse(description) == 536870912)
        #expect(StaticRangeSegmentMarker.ratingKey(fromTaskDescription: description) == "movie-123")
    }

    @Test("Plain rating keys remain unchanged and do not parse as markers")
    func plainRatingKey() {
        let description = "movie-123"

        #expect(StaticRangeSegmentMarker.ratingKey(fromTaskDescription: description) == description)
        #expect(StaticRangeSegmentMarker.parse(description) == nil)
    }

    @Test("Combined-description builder round-trips both values")
    func taskDescriptionRoundTrips() {
        let description = StaticRangeSegmentMarker.taskDescription(
            ratingKey: "movie-123",
            offset: 536870912
        )

        #expect(StaticRangeSegmentMarker.parse(description) == 536870912)
        #expect(StaticRangeSegmentMarker.ratingKey(fromTaskDescription: description) == "movie-123")
    }

    @Test("Rejects nil, missing prefix, non-numeric, and negative-offset markers")
    func rejectsMalformed() {
        #expect(StaticRangeSegmentMarker.parse(nil) == nil)
        #expect(StaticRangeSegmentMarker.parse("") == nil)
        #expect(StaticRangeSegmentMarker.parse("plex:item") == nil)
        #expect(StaticRangeSegmentMarker.parse("lbs-segment:v1:") == nil)
        #expect(StaticRangeSegmentMarker.parse("lbs-segment:v1:abc") == nil)
        #expect(StaticRangeSegmentMarker.parse("lbs-segment:v1:-512") == nil)
        #expect(StaticRangeSegmentMarker.parse("lbs-segment:v2:512") == nil)
        #expect(StaticRangeSegmentMarker.parse("prefix-lbs-segment:v1:512") == 512)
    }

    @Test("v2 marker round-trips offset and attempt token")
    func v2RoundTrips() {
        let marker = StaticRangeSegmentMarker.value(offset: 512, attemptID: "attempt-A")
        #expect(marker == "lbs-segment:v2:512:attempt-A")
        #expect(StaticRangeSegmentMarker.parse(marker) == 512)
        #expect(StaticRangeSegmentMarker.attemptID(marker) == "attempt-A")
    }

    @Test("v2 combined-description builder round-trips key, offset, and attempt")
    func v2TaskDescriptionRoundTrips() {
        let description = StaticRangeSegmentMarker.taskDescription(
            ratingKey: "movie-123",
            offset: 536870912,
            attemptID: "0B7C2A1E-attempt"
        )

        #expect(StaticRangeSegmentMarker.parse(description) == 536870912)
        #expect(StaticRangeSegmentMarker.attemptID(description) == "0B7C2A1E-attempt")
        #expect(StaticRangeSegmentMarker.ratingKey(fromTaskDescription: description) == "movie-123")
    }

    @Test("Legacy v1 markers parse an offset but expose no attempt token")
    func v1HasNoAttemptToken() {
        let description = StaticRangeSegmentMarker.taskDescription(ratingKey: "movie-123", offset: 512)

        #expect(StaticRangeSegmentMarker.parse(description) == 512)
        #expect(StaticRangeSegmentMarker.attemptID(description) == nil)
        #expect(StaticRangeSegmentMarker.ratingKey(fromTaskDescription: description) == "movie-123")
    }

    @Test("Malformed v2 markers are treated as unmarked")
    func rejectsMalformedV2() {
        #expect(StaticRangeSegmentMarker.parse("lbs-segment:v2:") == nil)
        #expect(StaticRangeSegmentMarker.parse("lbs-segment:v2:abc:attempt") == nil)
        #expect(StaticRangeSegmentMarker.parse("lbs-segment:v2:-512:attempt") == nil)
        #expect(StaticRangeSegmentMarker.parse("lbs-segment:v2:512:") == nil)
        #expect(StaticRangeSegmentMarker.attemptID("lbs-segment:v2:512:") == nil)
        #expect(StaticRangeSegmentMarker.attemptID("lbs-segment:v1:512") == nil)
    }
}

@Suite("Download attempt marker")
struct DownloadAttemptMarkerTests {
    @Test("Round-trips key and attempt token")
    func roundTrips() {
        let description = DownloadAttemptMarker.taskDescription(ratingKey: "movie-123",
                                                                attemptID: "attempt-A")

        #expect(DownloadAttemptMarker.attemptID(fromTaskDescription: description) == "attempt-A")
        #expect(DownloadAttemptMarker.ratingKey(fromTaskDescription: description) == "movie-123")
    }

    @Test("Bare rating keys expose no attempt and pass through unchanged")
    func bareKeyPassesThrough() {
        #expect(DownloadAttemptMarker.attemptID(fromTaskDescription: "movie-123") == nil)
        #expect(DownloadAttemptMarker.attemptID(fromTaskDescription: nil) == nil)
        #expect(DownloadAttemptMarker.attemptID(fromTaskDescription: "lbs-attempt:v1:") == nil)
        #expect(DownloadAttemptMarker.ratingKey(fromTaskDescription: "movie-123") == "movie-123")
    }

    @Test("Unified identity accessor reads both lane formats")
    func unifiedAttemptAccessor() {
        let segment = StaticRangeSegmentMarker.taskDescription(
            ratingKey: "movie-123", offset: 512, attemptID: "attempt-A")
        let opaque = DownloadAttemptMarker.taskDescription(
            ratingKey: "movie-123", attemptID: "attempt-B")

        #expect(BackgroundDownloadTaskIdentity.attemptID(taskDescription: segment) == "attempt-A")
        #expect(BackgroundDownloadTaskIdentity.attemptID(taskDescription: opaque) == "attempt-B")
        #expect(BackgroundDownloadTaskIdentity.attemptID(taskDescription: "movie-123") == nil)
        #expect(BackgroundDownloadTaskIdentity.attemptID(taskDescription: nil) == nil)
    }
}
