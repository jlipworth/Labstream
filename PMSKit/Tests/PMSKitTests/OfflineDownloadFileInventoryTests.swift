import Testing
@testable import PMSKit

@Suite("Offline download file inventory")
struct OfflineDownloadFileInventoryTests {

    @Test("referenced paths include main media side assets subtitles and resume blobs")
    func referencedPathsIncludeKnownAssets() {
        let metadata = OfflineMetadata(
            ratingKey: "plex:1",
            title: "Episode",
            type: "episode",
            posterRelativePath: "plex_1.poster.jpg",
            plexBIFRelativePath: "plex_1.plex-sd.bif",
            jellyfinTrickPlayPlaylistRelativePath: "plex_1.jf-trickplay.m3u8",
            jellyfinTrickPlayTileRelativePaths: ["plex_1.jf-trickplay-0.jpg"],
            chapterImageRelativePaths: [0: "plex_1.chapter-0.jpg"],
            offlineTextSubtitles: [
                OfflineTextSubtitleTrack(id: 1, displayName: "English", language: "en",
                                         codec: "vtt", relativePath: "plex_1.sub-1.vtt")
            ],
            resumeDataRelativePath: "plex_1.resume"
        )

        let paths = OfflineDownloadFileInventory.referencedRelativePaths(
            mainRelativePaths: ["plex_1.mp4"],
            metadata: [metadata]
        )

        #expect(paths == [
            "plex_1.mp4",
            "plex_1.poster.jpg",
            "plex_1.plex-sd.bif",
            "plex_1.jf-trickplay.m3u8",
            "plex_1.jf-trickplay-0.jpg",
            "plex_1.chapter-0.jpg",
            "plex_1.sub-1.vtt",
            "plex_1.resume",
        ])
    }

    @Test("audit reports directory referenced and orphan candidate bytes")
    func auditReportsOrphanCandidates() {
        let files = [
            OfflineDownloadFileSnapshot(relativePath: "index.json", byteCount: 50),
            OfflineDownloadFileSnapshot(relativePath: "plex_1.mp4", byteCount: 1_000),
            OfflineDownloadFileSnapshot(relativePath: "plex_1.poster.jpg", byteCount: 100),
            OfflineDownloadFileSnapshot(relativePath: "plex_2.poster.jpg", byteCount: 200),
            OfflineDownloadFileSnapshot(relativePath: "tmp-random", byteCount: 300),
        ]

        let audit = OfflineDownloadFileInventory.audit(
            directoryFiles: files,
            referencedRelativePaths: ["plex_1.mp4", "plex_1.poster.jpg"]
        )

        #expect(audit.referencedBytes == 1_100)
        #expect(audit.directoryBytes == 1_600)
        #expect(audit.unreferencedBytes == 500)
        #expect(audit.orphanCandidates == [
            OfflineDownloadFileSnapshot(relativePath: "plex_2.poster.jpg", byteCount: 200)
        ])
    }

    @Test("in flight files and unsafe paths are not orphan candidates")
    func inFlightAndUnsafePathsAreNotCandidates() {
        let files = [
            OfflineDownloadFileSnapshot(relativePath: "plex_1.mp4", byteCount: 1_000),
            OfflineDownloadFileSnapshot(relativePath: "../escape.mp4", byteCount: 1_000),
            OfflineDownloadFileSnapshot(relativePath: "nested/file.mp4", byteCount: 1_000),
            OfflineDownloadFileSnapshot(relativePath: "unowned.tmp", byteCount: 1_000),
        ]

        let audit = OfflineDownloadFileInventory.audit(directoryFiles: files,
                                                       referencedRelativePaths: [],
                                                       inFlightRelativePaths: ["plex_1.mp4"])

        #expect(audit.orphanCandidates.isEmpty)
        #expect(OfflineDownloadFileInventory.isLabstreamOwnedDownloadFilename("plex_1.resume"))
        #expect(OfflineDownloadFileInventory.isLabstreamOwnedDownloadFilename("plex_1.sub-2.srt"))
        #expect(!OfflineDownloadFileInventory.isLabstreamOwnedDownloadFilename("index.json"))
        #expect(!OfflineDownloadFileInventory.isLabstreamOwnedDownloadFilename("../escape.mp4"))
        #expect(!OfflineDownloadFileInventory.isLabstreamOwnedDownloadFilename("unowned.tmp"))
    }
}
