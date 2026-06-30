import Foundation
import Testing
@testable import PMSKit

@Suite("Download static retry target policy")
struct DownloadStaticRetryTargetPolicyTests {
    private func part(_ id: Int) -> Part {
        Part(id: id, key: "/library/parts/\(id)")
    }

    private func item() -> MediaItem {
        MediaItem(ratingKey: "item",
                  title: "Title",
                  type: "movie",
                  media: [
                    Media(id: 1, part: [part(10), part(11)]),
                    Media(id: 2, part: [part(20), part(21)]),
                  ])
    }

    private func metadata(sourcePartID: Int? = nil,
                          mediaIndex: Int? = nil,
                          serverPrepared: Bool? = nil) -> OfflineMetadata {
        OfflineMetadata(ratingKey: "item",
                        title: "Title",
                        type: "movie",
                        mediaIndex: mediaIndex,
                        sourcePartID: sourcePartID,
                        serverPreparedVersion: serverPrepared)
    }

    @Test("Source part id on primary media retries as original")
    func sourcePartOnPrimaryMediaIsOriginal() {
        let target = DownloadStaticRetryTargetPolicy.target(metadata: metadata(sourcePartID: 11),
                                                            item: item(),
                                                            fallbackMediaIndex: 9,
                                                            fallbackPartIndex: 8)
        #expect(target == DownloadStaticRetryTarget(intent: .original, mediaIndex: 0, partIndex: 1))
    }

    @Test("Source part id on non-primary media retries as existing version")
    func sourcePartOnSecondaryMediaIsExistingVersion() {
        let target = DownloadStaticRetryTargetPolicy.target(metadata: metadata(sourcePartID: 20),
                                                            item: item(),
                                                            fallbackMediaIndex: 9,
                                                            fallbackPartIndex: 8)
        #expect(target == DownloadStaticRetryTarget(intent: .existingVersion, mediaIndex: 1, partIndex: 0))
    }

    @Test("Server-prepared primary media source part remains existing version")
    func serverPreparedPrimaryMediaIsExistingVersion() {
        let target = DownloadStaticRetryTargetPolicy.target(metadata: metadata(sourcePartID: 10,
                                                                               serverPrepared: true),
                                                            item: item(),
                                                            fallbackMediaIndex: 9,
                                                            fallbackPartIndex: 8)
        #expect(target == DownloadStaticRetryTarget(intent: .existingVersion, mediaIndex: 0, partIndex: 0))
    }

    @Test("Missing source part falls back to indices and persisted prepared state")
    func missingSourcePartFallback() {
        #expect(DownloadStaticRetryTargetPolicy.target(metadata: metadata(sourcePartID: 999),
                                                       item: item(),
                                                       fallbackMediaIndex: 3,
                                                       fallbackPartIndex: 4)
            == DownloadStaticRetryTarget(intent: .original, mediaIndex: 3, partIndex: 4))
        #expect(DownloadStaticRetryTargetPolicy.target(metadata: metadata(sourcePartID: 999,
                                                                          serverPrepared: true),
                                                       item: item(),
                                                       fallbackMediaIndex: 3,
                                                       fallbackPartIndex: 4)
            == DownloadStaticRetryTarget(intent: .existingVersion, mediaIndex: 3, partIndex: 4))
        #expect(DownloadStaticRetryTargetPolicy.target(metadata: metadata(mediaIndex: 2),
                                                       item: item(),
                                                       fallbackMediaIndex: 3,
                                                       fallbackPartIndex: 4)
            == DownloadStaticRetryTarget(intent: .existingVersion, mediaIndex: 3, partIndex: 4))
    }
}
