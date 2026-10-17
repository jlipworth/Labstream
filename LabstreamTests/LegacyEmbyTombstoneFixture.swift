#if !os(tvOS)
import Foundation
import PMSKit
@testable import Labstream

/// Writes the legacy wire shape directly; new cleanup work uses the intent journal.
enum LegacyEmbyTombstoneFixture {
    static func make(ratingKey: String, metadata: OfflineMetadata? = nil)
        -> DownloadStore.EmbyConvertCleanupTombstone {
        .init(id: UUID(), ratingKey: ratingKey,
              metadata: metadata ?? OfflineMetadata(ratingKey: ratingKey, title: "Fixture", type: "movie"))
    }

    static func write(_ values: [DownloadStore.EmbyConvertCleanupTombstone], to store: DownloadStore) throws {
        let directory = store.durableCleanupAuthorityDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(values).write(
            to: directory.appendingPathComponent("emby-convert-cleanup.json"), options: .atomic)
    }
}
#endif
