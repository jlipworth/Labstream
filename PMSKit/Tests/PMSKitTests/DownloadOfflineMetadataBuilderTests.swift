import Foundation
import Testing
@testable import PMSKit

@Suite("Download offline metadata builder")
struct DownloadOfflineMetadataBuilderTests {
    private let session = BackendSession(kind: .jellyfin,
                                         baseURL: URL(string: "https://jelly.example/base")!,
                                         token: "redacted-token",
                                         userID: "user-1",
                                         serverID: "server-1")

    private func item() -> MediaItem {
        MediaItem(ratingKey: "item-1",
                  key: "/library/metadata/item-1",
                  title: "Episode Title",
                  type: "episode",
                  duration: 123_000,
                  viewOffset: 42,
                  viewCount: 2,
                  year: 2026,
                  summary: "Summary",
                  thumb: "thumb",
                  art: "art",
                  media: [
                    Media(id: 1, bitrate: 68_000, width: 3840, height: 2160, part: [
                        Part(id: 10, key: "/part/10", size: 1_000),
                    ]),
                    Media(id: 2, bitrate: 12_000, width: 1920, height: 1080, part: [
                        Part(id: 20, key: "/part/20", size: 2_000),
                    ]),
                  ],
                  librarySectionID: 7,
                  librarySectionKey: "section",
                  contentRating: "TV-MA",
                  tagline: "tagline",
                  grandparentTitle: "Show",
                  grandparentRatingKey: "show-1",
                  grandparentThumb: "show-thumb",
                  parentTitle: "Season",
                  parentRatingKey: "season-1",
                  parentThumb: "season-thumb",
                  parentIndex: 6,
                  index: 1)
    }

    @Test("Builder persists item fields, source part, and backend session identity")
    func persistsSnapshotFields() {
        let metadata = DownloadOfflineMetadataBuilder.metadata(from: item(),
                                                               resolutionLabel: "1080p",
                                                               requestedProfileLabel: "4K 40 Mbps",
                                                               mediaIndex: 1,
                                                               partIndex: 0,
                                                               optimizeQueueTitle: "queue-title",
                                                               session: session,
                                                               mediaSourceID: "media-source",
                                                               audioStreamIndex: 7,
                                                               downloadLane: .original)

        #expect(metadata.ratingKey == "item-1")
        #expect(metadata.title == "Episode Title")
        #expect(metadata.type == "episode")
        #expect(metadata.resolutionLabel == "1080p")
        #expect(metadata.requestedProfileLabel == "4K 40 Mbps")
        #expect(metadata.downloadBitrateKbps == 12_000)
        #expect(metadata.mediaIndex == 1)
        #expect(metadata.partIndex == 0)
        #expect(metadata.sourceMediaHeight == 1080)
        #expect(metadata.sourcePartID == 20)
        #expect(metadata.sourcePartSize == 2_000)
        #expect(metadata.optimizeQueueTitle == "queue-title")
        #expect(metadata.backendKind == .jellyfin)
        #expect(metadata.backendBaseURLString == "https://jelly.example/base")
        #expect(metadata.backendServerID == "server-1")
        #expect(metadata.backendUserID == "user-1")
        #expect(metadata.mediaSourceID == "media-source")
        #expect(metadata.audioStreamIndex == 7)
        #expect(metadata.playSessionID == nil)
        #expect(metadata.resumeMode == .staticByteRange)
        #expect(metadata.serverPreparedVersion == nil)
    }

    @Test("Missing explicit lane falls back to optimize only when target is nonempty")
    func laneFallback() {
        let optimized = DownloadOfflineMetadataBuilder.metadata(from: item(),
                                                                resolutionLabel: nil,
                                                                mediaIndex: 0,
                                                                partIndex: 0,
                                                                optimizeTargetName: "720p 4 Mbps",
                                                                session: BackendSession(kind: .plex,
                                                                                        baseURL: URL(string: "https://plex.example")!,
                                                                                        token: "redacted"))
        #expect(optimized.downloadLane == nil)
        #expect(optimized.resumeMode == .serverPrepThenStatic)
        #expect(optimized.downloadBitrateKbps == 4_000)

        let originalQuality = DownloadOfflineMetadataBuilder.metadata(from: item(),
                                                                      resolutionLabel: nil,
                                                                      mediaIndex: 0,
                                                                      partIndex: 0,
                                                                      optimizeTargetName: "Original video quality",
                                                                      session: BackendSession(kind: .plex,
                                                                                              baseURL: URL(string: "https://plex.example")!,
                                                                                              token: "redacted"))
        #expect(originalQuality.downloadBitrateKbps == 68_000)

        let original = DownloadOfflineMetadataBuilder.metadata(from: item(),
                                                               resolutionLabel: nil,
                                                               mediaIndex: 0,
                                                               partIndex: 0,
                                                               optimizeTargetName: "",
                                                               session: session)
        #expect(original.downloadLane == nil)
        #expect(original.resumeMode == .staticByteRange)
        #expect(original.downloadBitrateKbps == 68_000)
    }

    @Test("Explicit MediaBrowser compatible lane persists live forward-only resume mode")
    func compatibleLane() {
        let metadata = DownloadOfflineMetadataBuilder.metadata(from: item(),
                                                               resolutionLabel: nil,
                                                               mediaIndex: 0,
                                                               partIndex: 0,
                                                               session: session,
                                                               downloadLane: .compatibleRemux)
        #expect(metadata.downloadLane == .compatibleRemux)
        #expect(metadata.resumeMode == .liveForwardOnly)
    }

    @Test("Server-prepared flag is stored only when true")
    func serverPreparedFlag() {
        let prepared = DownloadOfflineMetadataBuilder.metadata(from: item(),
                                                               resolutionLabel: nil,
                                                               mediaIndex: 0,
                                                               partIndex: 0,
                                                               session: session,
                                                               serverPreparedVersion: true)
        let notPrepared = DownloadOfflineMetadataBuilder.metadata(from: item(),
                                                                  resolutionLabel: nil,
                                                                  mediaIndex: 0,
                                                                  partIndex: 0,
                                                                  session: session,
                                                                  serverPreparedVersion: false)
        #expect(prepared.serverPreparedVersion == true)
        #expect(notPrepared.serverPreparedVersion == nil)
    }
}
