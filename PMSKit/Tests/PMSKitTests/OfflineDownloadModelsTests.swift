import Foundation
import Testing
@testable import PMSKit

/// Hermetic tests for the offline-download value types moved out of the app
/// (`DownloadStore.swift`) into PMSKit. These pin the silent-data-loss-on-upgrade
/// surface — the pre-D2/pre-D5 migration behaviour and the launch reconciliation
/// transition table — which had no app test target to cover it.
@Suite("Offline download models")
struct OfflineDownloadModelsTests {

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - pre-D2: row JSON without an explicit `status`

    @Test("legacy progress 1.0 migrates to .complete")
    func legacyCompleteProgressMigratesToComplete() {
        #expect(DownloadStatus.migratedStatus(forLegacyProgress: 1.0) == .complete)
        #expect(DownloadStatus.migratedStatus(forLegacyProgress: 1.5) == .complete)
    }

    @Test("legacy partial progress migrates to .queued")
    func legacyPartialProgressMigratesToQueued() {
        #expect(DownloadStatus.migratedStatus(forLegacyProgress: 0.4) == .queued)
        #expect(DownloadStatus.migratedStatus(forLegacyProgress: 0.0) == .queued)
        #expect(DownloadStatus.migratedStatus(forLegacyProgress: 0.999) == .queued)
    }

    /// A `DownloadRecord` whose JSON omits `status` would fail to decode under the
    /// synthesized initializer (status is non-optional); the migration helper is what
    /// the app applies at the row level. Here we verify the helper produces the same
    /// defaulting an old finished-vs-partial row relied on.
    @Test("pre-D2 finished vs partial rows default their status correctly")
    func preD2RowsDefaultStatusByProgress() {
        let finishedProgress = 1.0
        let partialProgress = 0.4
        #expect(DownloadStatus.migratedStatus(forLegacyProgress: finishedProgress) == .complete)
        #expect(DownloadStatus.migratedStatus(forLegacyProgress: partialProgress) == .queued)
    }

    // MARK: - pre-D5: metadata JSON missing optional fields

    @Test("pre-D5 metadata without optional fields decodes gracefully")
    func preD5MetadataDecodesWithDefaults() throws {
        // Only the three required-ish fields present (and `type` itself omitted to
        // exercise the "movie" default rows persisted before `type` existed).
        let json = #"{"ratingKey":"123","title":"Old Movie"}"#
        let meta = try decode(OfflineMetadata.self, from: json)
        #expect(meta.ratingKey == "123")
        #expect(meta.title == "Old Movie")
        #expect(meta.type == "movie")          // defaulted
        #expect(meta.year == nil)
        #expect(meta.posterRelativePath == nil)
        #expect(meta.resolutionLabel == nil)
    }

    @Test("a record persisted before D5 (no metadata) decodes with nil metadata")
    func recordWithoutMetadataDecodes() throws {
        // DownloadRecord persists `localURL` as a URL; metadata + poster are optional.
        let json = """
        {"ratingKey":"99","title":"Pre-D5","localURL":"file:///tmp/x.mp4",
         "bytes":10,"progress":1.0,"status":"complete"}
        """
        let record = try decode(DownloadRecord.self, from: json)
        #expect(record.ratingKey == "99")
        #expect(record.status == .complete)
        #expect(record.isComplete)
        #expect(record.metadata == nil)
        #expect(record.posterURL == nil)
    }

    // MARK: - round-trip

    @Test("OfflineMetadata round-trips through encode/decode")
    func metadataRoundTrips() throws {
        let original = OfflineMetadata(
            ratingKey: "555",
            key: "/library/metadata/555",
            title: "Round Trip",
            type: "episode",
            year: 2021,
            duration: 3_600_000,
            viewOffset: 12_000,
            viewCount: 2,
            summary: "A summary.",
            contentRating: "TV-14",
            tagline: "tag",
            grandparentTitle: "The Show",
            grandparentRatingKey: "show-1",
            grandparentThumb: "/show/thumb",
            parentTitle: "Season 2",
            parentRatingKey: "season-2",
            parentThumb: "/season/thumb",
            parentIndex: 2,
            index: 5,
            thumb: "/thumb/1",
            art: "/art/1",
            resolutionLabel: "1080p",
            librarySectionID: 3,
            librarySectionKey: "/library/sections/3",
            mediaIndex: 0,
            partIndex: 1,
            sourcePartID: 42,
            optimizeTargetName: "Original video quality",
            optimizeQueueTitle: "Round Trip [VisionPlay 12345678]",
            optimizeBaselinePartIDs: [42, 43, 44],
            posterRelativePath: "555.poster.jpg")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OfflineMetadata.self, from: data)
        #expect(decoded == original)
    }

    @Test("makeMediaItem carries the captured fields onto a faithful MediaItem")
    func makeMediaItemPreservesFields() {
        let meta = OfflineMetadata(
            ratingKey: "777",
            key: "/library/metadata/777",
            title: "Episode Title",
            type: "episode",
            year: 1999,
            duration: 7_200_000,
            viewOffset: 60_000,
            viewCount: 1,
            summary: "S",
            contentRating: "R",
            tagline: "T",
            grandparentTitle: "The Show",
            grandparentRatingKey: "show-1",
            grandparentThumb: "/show/thumb",
            parentTitle: "Season 2",
            parentRatingKey: "season-2",
            parentThumb: "/season/thumb",
            parentIndex: 2,
            index: 5,
            thumb: "/t",
            art: "/a")
        let item = meta.makeMediaItem()
        #expect(item.ratingKey == "777")
        #expect(item.key == "/library/metadata/777")
        #expect(item.title == "Episode Title")
        #expect(item.type == "episode")
        #expect(item.year == 1999)
        #expect(item.duration == 7_200_000)
        #expect(item.viewOffset == 60_000)
        #expect(item.viewCount == 1)
        #expect(item.summary == "S")
        #expect(item.contentRating == "R")
        #expect(item.tagline == "T")
        #expect(item.thumb == "/t")
        #expect(item.art == "/a")
        #expect(item.grandparentTitle == "The Show")
        #expect(item.grandparentRatingKey == "show-1")
        #expect(item.grandparentThumb == "/show/thumb")
        #expect(item.parentTitle == "Season 2")
        #expect(item.parentRatingKey == "season-2")
        #expect(item.parentThumb == "/season/thumb")
        #expect(item.parentIndex == 2)
        #expect(item.index == 5)
        #expect(item.seasonEpisodeCode == "S2E5")
        #expect(item.displaySubtitleLine == "The Show · S2E5 · Episode Title")
    }

    @Test("DownloadRecord round-trips through encode/decode")
    func recordRoundTrips() throws {
        let original = DownloadRecord(
            ratingKey: "1",
            title: "Title",
            localURL: URL(fileURLWithPath: "/tmp/1.mp4"),
            bytes: 1234,
            progress: 0.5,
            status: .downloading,
            metadata: OfflineMetadata(ratingKey: "1", title: "Title", type: "movie"),
            posterURL: URL(fileURLWithPath: "/tmp/1.poster.jpg"))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DownloadRecord.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - reconciledStatus transition table

    @Test("complete row keeps complete only while its file exists")
    func completeRowDemotedWhenFileMissing() {
        #expect(DownloadStatus.reconciledStatus(
            current: .complete, fileExists: true, hasLiveTask: false) == .complete)
        #expect(DownloadStatus.reconciledStatus(
            current: .complete, fileExists: true, hasLiveTask: true) == .complete)
        #expect(DownloadStatus.reconciledStatus(
            current: .complete, fileExists: false, hasLiveTask: false) == .failed)
        #expect(DownloadStatus.reconciledStatus(
            current: .complete, fileExists: false, hasLiveTask: true) == .failed)
    }

    @Test("queued/downloading rows survive only with a live task")
    func inFlightRowsSurviveOnlyWithLiveTask() {
        for current in [DownloadStatus.queued, .downloading] {
            // Live task -> untouched regardless of file presence.
            #expect(DownloadStatus.reconciledStatus(
                current: current, fileExists: true, hasLiveTask: true) == current)
            #expect(DownloadStatus.reconciledStatus(
                current: current, fileExists: false, hasLiveTask: true) == current)
            // No live task -> not trustworthy -> failed (even if a partial file exists).
            #expect(DownloadStatus.reconciledStatus(
                current: current, fileExists: true, hasLiveTask: false) == .failed)
            #expect(DownloadStatus.reconciledStatus(
                current: current, fileExists: false, hasLiveTask: false) == .failed)
        }
    }

    @Test("failed rows stay failed across all disk/task combinations")
    func failedRowsAreTerminal() {
        for fileExists in [true, false] {
            for hasLiveTask in [true, false] {
                #expect(DownloadStatus.reconciledStatus(
                    current: .failed, fileExists: fileExists, hasLiveTask: hasLiveTask) == .failed)
            }
        }
    }
}
