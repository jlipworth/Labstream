import Foundation
import Testing
@testable import PMSKit

@Suite("Background download task identity")
struct BackgroundDownloadTaskIdentityTests {

    @Test("Task description wins when it matches a known row key")
    func taskDescriptionWins() {
        let resolved = BackgroundDownloadTaskIdentity.ratingKey(
            taskDescription: "plex:movie",
            requestURL: URL(string: "https://example.test/Items/jellyfin-movie/Download"),
            knownKeys: ["plex:movie", "jellyfin:jellyfin-movie"]
        )

        #expect(resolved == "plex:movie")
    }

    @Test("Request URLs never mint or recover download ownership")
    func requestURLCannotResolveOwnership() {
        let urls = [
            "https://plex.example/video/:/transcode/universal/start.m3u8?path=%2Flibrary%2Fmetadata%2F1234",
            "https://jellyfin.example/Items/item-1/Download",
            "https://emby.example/Videos/video-1/stream.mp4",
        ]
        for url in urls {
            #expect(BackgroundDownloadTaskIdentity.ratingKey(
                taskDescription: nil,
                requestURL: URL(string: url),
                knownKeys: ["1234", "item-1", "video-1", "jellyfin:item-1"]
            ) == nil)
        }
    }

    @Test("Plex part URLs require task description because source key is absent")
    func plexPartURLDoesNotInferKey() {
        let withoutDescription = BackgroundDownloadTaskIdentity.ratingKey(
            taskDescription: nil,
            requestURL: URL(string: "https://plex.example/library/parts/9876/file.mp4"),
            knownKeys: ["movie-123"]
        )
        let withDescription = BackgroundDownloadTaskIdentity.ratingKey(
            taskDescription: "movie-123",
            requestURL: URL(string: "https://plex.example/library/parts/9876/file.mp4"),
            knownKeys: ["movie-123"]
        )

        #expect(withoutDescription == nil)
        #expect(withDescription == "movie-123")
    }

    @Test("Combined segment description resolves Plex part URL to its row")
    func combinedSegmentDescriptionResolvesPlexPartURL() {
        let resolved = BackgroundDownloadTaskIdentity.ratingKey(
            taskDescription: StaticRangeSegmentMarker.taskDescription(
                ratingKey: "movie-123", offset: 536870912, attemptID: "attempt-A"),
            requestURL: URL(string: "https://plex.example/library/parts/9876/file.mp4"),
            knownKeys: ["movie-123"]
        )

        #expect(resolved == "movie-123")
    }

    @Test("v2 segment and attempt-stamped descriptions resolve their row")
    func attemptStampedDescriptionsResolve() {
        let segment = BackgroundDownloadTaskIdentity.ratingKey(
            taskDescription: StaticRangeSegmentMarker.taskDescription(
                ratingKey: "movie-123", offset: 536870912, attemptID: "attempt-A"),
            requestURL: URL(string: "https://plex.example/library/parts/9876/file.mp4"),
            knownKeys: ["movie-123"]
        )
        let opaque = BackgroundDownloadTaskIdentity.ratingKey(
            taskDescription: DownloadAttemptMarker.taskDescription(
                ratingKey: "jellyfin:abcd", attemptID: "attempt-B"),
            requestURL: nil,
            knownKeys: ["jellyfin:abcd"]
        )

        #expect(segment == "movie-123")
        #expect(opaque == "jellyfin:abcd")
    }

    @Test("Startup purge requires a current marker mapped to a non-reset row")
    func startupPurgeClassification() {
        let attemptID = DownloadAttemptID(rawValue: "attempt-A")!
        let current = DownloadAttemptMarker.taskDescription(
            ratingKey: "plex:item", attemptID: attemptID)
        let legacy = "plex:item\u{1F}lbs-attempt:v1:\(attemptID.rawValue)"

        #expect(!BackgroundDownloadTaskIdentity.shouldPurgeBeforeAdmission(
            taskDescription: current,
            mapsToKnownRow: true,
            mapsToApprovedResetKey: false))
        #expect(BackgroundDownloadTaskIdentity.shouldPurgeBeforeAdmission(
            taskDescription: legacy,
            mapsToKnownRow: true,
            mapsToApprovedResetKey: false))
        #expect(BackgroundDownloadTaskIdentity.shouldPurgeBeforeAdmission(
            taskDescription: current,
            mapsToKnownRow: false,
            mapsToApprovedResetKey: false))
        #expect(BackgroundDownloadTaskIdentity.shouldPurgeBeforeAdmission(
            taskDescription: current,
            mapsToKnownRow: true,
            mapsToApprovedResetKey: true))
    }
}
