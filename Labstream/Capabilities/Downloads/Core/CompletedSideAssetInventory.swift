import Foundation
import PMSKit

/// One pass's observational evidence. Reuse never adopts orphan files or grants publication
/// authority; the store still fences every promotion and metadata mutation independently.
struct CompletedSideAssetInventory: Sendable {
    let record: DownloadRecord
    let key: DownloadAttemptKey
    let source: OfflineSideAssetSourceIdentity
    let generation: UInt64
    let reusable: Set<String>
    let missing: Set<DownloadSideAssetKind>
    let resources: [DownloadSideAssetKind: [String?]]

    func matches(_ store: DownloadStore) -> Bool {
        store.sideAssetSourceIdentity(for: key) == source
            && store.sideAssetObservationGeneration(for: key) == generation
    }

    static func observe(record: DownloadRecord, store: DownloadStore) -> Self? {
        guard let attemptID = record.attemptID, let metadata = record.metadata else { return nil }
        let key = DownloadAttemptKey(ratingKey: record.ratingKey, attemptID: attemptID)
        let source = metadata.sideAssetSourceIdentity
        guard let generation = store.sideAssetObservationGeneration(for: key),
              store.sideAssetSourceIdentity(for: key) == source else { return nil }
        let root = store.posterDestinationURL(ratingKey: record.ratingKey).deletingLastPathComponent()
        var observations: [String: Bool] = [:]
        func exists(_ relative: String) -> Bool {
            if let result = observations[relative] { return result }
            // The reusable-file seam validates exact ownership and safe, one-level paths before I/O.
            let result = store.reusableSideAssetRelativePath(
                for: key, destination: root.appendingPathComponent(relative)) == relative
            observations[relative] = result
            return result
        }
        let missing = DownloadSideAssetRepairInventory.missingKinds(record: record, fileExists: exists,
            jellyfinPlaylistTiles: { relative in
                guard let data = try? Data(contentsOf: root.appendingPathComponent(relative)),
                      let text = String(data: data, encoding: .utf8),
                      let playlist = try? JellyfinTrickPlayPlaylistParser.parse(text) else { return nil }
                return playlist.tiles.map { URL(fileURLWithPath: $0.uri).lastPathComponent }
            })
        var resources: [DownloadSideAssetKind: [String?]] = [:]
        for kind in missing {
            resources[kind] = DownloadSideAssetRepairInventory.retryResources(for: kind, record: record,
                fileExists: exists, chapterResource: {
                    store.chapterImageDestinationURL(ratingKey: record.ratingKey, index: $0).lastPathComponent
                })
        }
        let value = Self(record: record, key: key, source: source, generation: generation,
            reusable: Set(observations.compactMap { $0.value ? $0.key : nil }),
            missing: missing, resources: resources)
        return value.matches(store) ? value : nil
    }
}
