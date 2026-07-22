import Foundation
import Testing
@testable import PMSKit

@Suite("Background download task identity")
struct BackgroundDownloadTaskIdentityTests {

    @Test("Current task description resolves a known row key")
    func taskDescriptionResolves() {
        let resolved = BackgroundDownloadTaskIdentity.ratingKey(
            taskDescription: "plex:movie",
            knownKeys: ["plex:movie", "jellyfin:jellyfin-movie"]
        )

        #expect(resolved == "plex:movie")
    }

    @Test("Missing task description never infers ownership")
    func missingDescriptionDoesNotInferKey() {
        let withoutDescription = BackgroundDownloadTaskIdentity.ratingKey(
            taskDescription: nil,
            knownKeys: ["movie-123"]
        )
        let withDescription = BackgroundDownloadTaskIdentity.ratingKey(
            taskDescription: "movie-123",
            knownKeys: ["movie-123"]
        )

        #expect(withoutDescription == nil)
        #expect(withDescription == "movie-123")
    }

    @Test("Combined current segment description resolves its row")
    func combinedSegmentDescriptionResolves() {
        let resolved = BackgroundDownloadTaskIdentity.ratingKey(
            taskDescription: StaticRangeSegmentMarker.taskDescription(
                ratingKey: "movie-123", offset: 536870912, attemptID: DownloadAttemptID(rawValue: "attempt-A")!),
            knownKeys: ["movie-123"]
        )

        #expect(resolved == "movie-123")
    }

    @Test("Current segment and attempt-stamped descriptions resolve their row")
    func attemptStampedDescriptionsResolve() {
        let segment = BackgroundDownloadTaskIdentity.ratingKey(
            taskDescription: StaticRangeSegmentMarker.taskDescription(
                ratingKey: "movie-123", offset: 536870912, attemptID: DownloadAttemptID(rawValue: "attempt-A")!),
            knownKeys: ["movie-123"]
        )
        let opaque = BackgroundDownloadTaskIdentity.ratingKey(
            taskDescription: DownloadAttemptMarker.taskDescription(
                ratingKey: "jellyfin:abcd", attemptID: DownloadAttemptID(rawValue: "attempt-B")!),
            knownKeys: ["jellyfin:abcd"]
        )

        #expect(segment == "movie-123")
        #expect(opaque == "jellyfin:abcd")
    }

    @Test("Startup purge requires a current marker mapped to a row")
    func startupPurgeClassification() {
        let attemptID = DownloadAttemptID(rawValue: "attempt-A")!
        let current = DownloadAttemptMarker.taskDescription(
            ratingKey: "plex:item", attemptID: attemptID)
        let legacy = "plex:item\u{1F}lbs-attempt:v1:\(attemptID.rawValue)"

        #expect(!BackgroundDownloadTaskIdentity.shouldPurgeBeforeAdmission(
            taskDescription: current,
            mapsToKnownRow: true))
        #expect(BackgroundDownloadTaskIdentity.shouldPurgeBeforeAdmission(
            taskDescription: legacy,
            mapsToKnownRow: true))
        #expect(BackgroundDownloadTaskIdentity.shouldPurgeBeforeAdmission(
            taskDescription: current,
            mapsToKnownRow: false))
    }
}
