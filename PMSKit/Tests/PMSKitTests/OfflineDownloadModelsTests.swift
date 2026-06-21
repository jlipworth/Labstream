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
        #expect(meta.plexBIFRelativePath == nil)
        #expect(meta.jellyfinTrickPlayPlaylistRelativePath == nil)
        #expect(meta.jellyfinTrickPlayTileRelativePaths == nil)
        #expect(meta.chapterImageRelativePaths == nil)
        #expect(meta.offlineTextSubtitles == nil)
        #expect(meta.markers == nil)
        #expect(meta.resolutionLabel == nil)
    }

    @Test("resolvedBackendKind falls back to the ratingKey prefix for legacy rows")
    func resolvedBackendKindLegacyPrefixFallback() throws {
        // Pre-#84 metadata has no `backendKind`; the row's backend is recovered from the key prefix.
        let legacy = try decode(OfflineMetadata.self, from: #"{"ratingKey":"123","title":"t"}"#)
        #expect(legacy.backendKind == nil)
        #expect(legacy.resolvedBackendKind(ratingKey: "123") == .plex)
        #expect(legacy.resolvedBackendKind(ratingKey: "jellyfin:99") == .jellyfin)
        #expect(legacy.resolvedBackendKind(ratingKey: "emby:99") == .emby)
    }

    @Test("a persisted backendKind wins over the ratingKey prefix")
    func resolvedBackendKindStoredFieldWins() throws {
        // A stored backendKind is authoritative even if the key prefix would say otherwise.
        let stored = try decode(OfflineMetadata.self,
                                from: #"{"ratingKey":"emby:99","title":"t","backendKind":"plex"}"#)
        #expect(stored.backendKind == .plex)
        #expect(stored.resolvedBackendKind(ratingKey: "emby:99") == .plex)
    }

    @Test("resolvedDownloadLane falls back for legacy rows and honors stored compatible-remux")
    func resolvedDownloadLaneFallbackAndStoredField() throws {
        let legacyOriginal = try decode(OfflineMetadata.self,
                                        from: #"{"ratingKey":"123","title":"t"}"#)
        #expect(legacyOriginal.downloadLane == nil)
        #expect(legacyOriginal.resolvedDownloadLane() == .original)

        let legacyOptimize = try decode(OfflineMetadata.self,
                                        from: #"{"ratingKey":"123","title":"t","optimizeTargetName":"1080p 8 Mbps"}"#)
        #expect(legacyOptimize.downloadLane == nil)
        #expect(legacyOptimize.resolvedDownloadLane() == .optimize)

        let compatible = try decode(OfflineMetadata.self,
                                    from: #"{"ratingKey":"jellyfin:123","title":"t","downloadLane":"compatibleRemux"}"#)
        #expect(compatible.downloadLane == .compatibleRemux)
        #expect(compatible.resolvedDownloadLane() == .compatibleRemux)
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
            chapters: [OfflineChapter(chapterID: 7, tag: "Chapter 7", startTimeOffset: 7_000)],
            markers: [OfflineMarker(markerID: 8, type: "intro", startTimeOffset: 15_000, endTimeOffset: 75_000, isFinal: false),
                      OfflineMarker(markerID: 9, type: "credits", startTimeOffset: 3_500_000, endTimeOffset: 3_600_000, isFinal: true)],
            resolutionLabel: "1080p",
            librarySectionID: 3,
            librarySectionKey: "/library/sections/3",
            mediaIndex: 0,
            partIndex: 1,
            sourcePartID: 42,
            optimizeTargetName: "Original video quality",
            optimizeQueueTitle: "Round Trip [VisionPlay 12345678]",
            optimizeBaselinePartIDs: [42, 43, 44],
            posterRelativePath: "555.poster.jpg",
            plexBIFRelativePath: "555.plex-sd.bif",
            jellyfinTrickPlayPlaylistRelativePath: "555.jf-trickplay.m3u8",
            jellyfinTrickPlayTileRelativePaths: ["555.jf-trickplay-0.jpg"],
            chapterImageRelativePaths: [0: "555.chapter-0.jpg", 3: "555.chapter-3.jpg"],
            offlineTextSubtitles: [OfflineTextSubtitleTrack(id: 1, displayName: "English", language: "eng", codec: "srt", relativePath: "555.sub.1.srt")],
            backendKind: .jellyfin,
            backendBaseURLString: "https://media.example.test/jellyfin",
            backendServerID: "server-123",
            backendUserID: "user-456",
            mediaSourceID: "media-source-789",
            playSessionID: "visionplay-download-abc",
            downloadLane: .compatibleRemux)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OfflineMetadata.self, from: data)
        #expect(decoded == original)
    }

    @Test("chapterImageRelativePaths (index-keyed dict) round-trips through encode/decode")
    func chapterImagePathsRoundTrip() throws {
        // [Int: String] is the only non-String-keyed field on the model; pin its JSON round-trip
        // explicitly so a future encoder change can't silently drop the offline chapter-image map.
        let meta = OfflineMetadata(ratingKey: "9", title: "t", type: "movie",
                                   chapterImageRelativePaths: [0: "9.chapter-0.jpg",
                                                               2: "9.chapter-2.jpg",
                                                               5: "9.chapter-5.jpg"])
        let decoded = try JSONDecoder().decode(OfflineMetadata.self,
                                               from: JSONEncoder().encode(meta))
        #expect(decoded.chapterImageRelativePaths == meta.chapterImageRelativePaths)
        #expect(decoded.chapterImageRelativePaths?[2] == "9.chapter-2.jpg")
    }

    @Test("pre-#88 metadata without chapterImageRelativePaths decodes to nil")
    func preChapterImageMetadataDecodesNil() throws {
        let meta = try decode(OfflineMetadata.self, from: #"{"ratingKey":"1","title":"t"}"#)
        #expect(meta.chapterImageRelativePaths == nil)
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
            art: "/a",
            chapters: [OfflineChapter(chapterID: 1,
                                      tag: "Opening",
                                      startTimeOffset: 0,
                                      endTimeOffset: 600_000,
                                      thumb: "/chapter/1")],
            markers: [OfflineMarker(markerID: 2,
                                    type: "intro",
                                    startTimeOffset: 10_000,
                                    endTimeOffset: 70_000,
                                    isFinal: false),
                      OfflineMarker(markerID: 3,
                                    type: "credits",
                                    startTimeOffset: 7_000_000,
                                    endTimeOffset: nil,
                                    isFinal: true)])
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
        #expect(item.chapters?.count == 1)
        #expect(item.chapters?.first?.tag == "Opening")
        #expect(item.chapters?.first?.startTimeOffset == 0)
        #expect(item.chapters?.first?.thumb == "/chapter/1")
        #expect(item.markers?.count == 2)
        #expect(item.markers?.first?.markerID == 2)
        #expect(item.markers?.first?.type == "intro")
        #expect(item.markers?.first?.startTimeOffset == 10_000)
        #expect(item.markers?.first?.endTimeOffset == 70_000)
        #expect(item.markers?.first?.isFinal == false)
        #expect(item.markers?.last?.type == "credits")
        #expect(item.markers?.last?.isFinal == true)
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
            metadata: OfflineMetadata(ratingKey: "1", title: "Title", type: "movie",
                                      plexBIFRelativePath: "1.plex-sd.bif"),
            posterURL: URL(fileURLWithPath: "/tmp/1.poster.jpg"),
            plexBIFURL: URL(fileURLWithPath: "/tmp/1.plex-sd.bif"),
            jellyfinTrickPlayPlaylistURL: URL(fileURLWithPath: "/tmp/1.jf-trickplay.m3u8"),
            chapterImageURLs: [0: URL(fileURLWithPath: "/tmp/1.chapter-0.jpg")],
            sideAssetBytes: 42)
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

    // MARK: - #95: .paused (recoverably-interrupted) rows

    @Test("paused round-trips through encode/decode and decodes legacy rows without the case")
    func pausedRoundTripsAndLegacyDecodes() throws {
        let data = try JSONEncoder().encode(DownloadStatus.paused)
        #expect(try JSONDecoder().decode(DownloadStatus.self, from: data) == .paused)
        // A row whose JSON omits `status` (pre-this-change) still defaults via the migration.
        #expect(DownloadStatus.migratedStatus(forLegacyProgress: 0.5) == .queued)
    }

    @Test("a paused row stays resumable across relaunch only while its resume blob survives")
    func pausedRowKeptResumableWithResumeData() {
        // No live task but the resume blob is on disk -> keep it paused (resumable).
        #expect(DownloadStatus.reconciledStatus(
            current: .paused, fileExists: true, hasLiveTask: false, hasResumeData: true) == .paused)
        // The partial file alone (no resume blob) can't be continued -> demote to retryable failed.
        #expect(DownloadStatus.reconciledStatus(
            current: .paused, fileExists: true, hasLiveTask: false, hasResumeData: false) == .failed)
        #expect(DownloadStatus.reconciledStatus(
            current: .paused, fileExists: false, hasLiveTask: false, hasResumeData: false) == .failed)
        // If the task is somehow live again, let it run.
        #expect(DownloadStatus.reconciledStatus(
            current: .paused, fileExists: true, hasLiveTask: true, hasResumeData: true) == .downloading)
        // Default hasResumeData is false (backward-compatible call sites) -> failed.
        #expect(DownloadStatus.reconciledStatus(
            current: .paused, fileExists: true, hasLiveTask: false) == .failed)
    }

    @Test("OfflineMetadata carries resumeDataRelativePath through encode/decode")
    func metadataCarriesResumeDataPath() throws {
        let meta = OfflineMetadata(ratingKey: "jellyfin:42", title: "Movie", type: "movie",
                                   resumeDataRelativePath: "jellyfin_42.resume")
        let round = try JSONDecoder().decode(OfflineMetadata.self,
                                             from: try JSONEncoder().encode(meta))
        #expect(round.resumeDataRelativePath == "jellyfin_42.resume")
        // Legacy metadata without the field decodes to nil (no silent failure).
        let legacy = try decode(OfflineMetadata.self,
                                from: #"{"ratingKey":"x","title":"T","type":"movie"}"#)
        #expect(legacy.resumeDataRelativePath == nil)
    }

    @Test("validation policy shortens required playback for short clips")
    func validationPolicyShortClipRequiredPlayback() {
        let short = OfflinePlaybackValidationPolicy.make(durationMs: 2_000)
        #expect(short.requiredPlaybackSeconds == 0.2)
        #expect(short.timeoutSeconds == 8.0)

        let tiny = OfflinePlaybackValidationPolicy.make(durationMs: 300)
        #expect(tiny.requiredPlaybackSeconds == 0.05)
    }

    @Test("validation policy uses longer timeout for remote preflight")
    func validationPolicyRemotePreflightTimeout() {
        let local = OfflinePlaybackValidationPolicy.make(durationMs: nil)
        let remote = OfflinePlaybackValidationPolicy.make(durationMs: nil, isRemotePreflight: true)
        #expect(local.requiredPlaybackSeconds == 0.5)
        #expect(remote.requiredPlaybackSeconds == 0.5)
        #expect(local.timeoutSeconds == 8.0)
        #expect(remote.timeoutSeconds == 12.0)
    }

}
