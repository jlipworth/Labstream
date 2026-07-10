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
}
