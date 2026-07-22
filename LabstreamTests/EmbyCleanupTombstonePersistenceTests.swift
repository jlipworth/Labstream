import Foundation
import PMSKit
import Testing
@testable import Labstream

struct EmbyCleanupTombstonePersistenceTests {
    private func cleanupAuthority(for root: URL) -> URL {
        root.deletingLastPathComponent().appendingPathComponent(
            ".\(root.lastPathComponent)-download-authority", isDirectory: true)
    }

    @Test func missingQueueLoadsEmptyAndValidMutationsPreserveSiblings() throws {
        try withTemporaryDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            #expect(try loaded(store).isEmpty)

            let first = try committedAdd(store, ratingKey: "emby:same")
            let second = try committedAdd(store, ratingKey: "emby:same")
            #expect(try loaded(store).map(\.id) == [first.id, second.id])

            guard case .committed(removed: true) = store.removeEmbyConvertCleanupTombstone(
                id: first.id
            ) else {
                Issue.record("Expected durable tombstone removal")
                return
            }
            #expect(try loaded(store).map(\.id) == [second.id])
            #expect(store.removeEmbyConvertCleanupTombstone(id: first.id) == .committed(removed: false))
        }
    }

    @Test func malformedQueueFailsClosedWithoutChangingCanonicalBytes() throws {
        try withTemporaryDirectory { directory in
            let canonical = cleanupAuthority(for: directory)
                .appendingPathComponent("emby-convert-cleanup.json")
            try FileManager.default.createDirectory(
                at: cleanupAuthority(for: directory), withIntermediateDirectories: true)
            let corrupt = Data("not-json".utf8)
            try corrupt.write(to: canonical)
            let store = DownloadStore(baseDirectory: directory)

            guard case .failed(let loadFailure) = store.loadEmbyConvertCleanupTombstones() else {
                Issue.record("Expected corrupt queue to fail decoding")
                return
            }
            #expect(loadFailure.stage == .decode)
            guard case .failed(let addFailure) = store.addEmbyConvertCleanupTombstone(
                ratingKey: "emby:new", metadata: metadata("emby:new")
            ) else {
                Issue.record("Expected add to refuse corrupt queue")
                return
            }
            #expect(addFailure.stage == .decode)
            guard case .failed(let removeFailure) = store.removeEmbyConvertCleanupTombstone(
                id: UUID()
            ) else {
                Issue.record("Expected remove to refuse corrupt queue")
                return
            }
            #expect(removeFailure.stage == .decode)
            #expect(try Data(contentsOf: canonical) == corrupt)
        }
    }

    @Test func readAndEncodeFailuresAreObservableAndFailClosed() throws {
        try withTemporaryDirectory { directory in
            let readFailureStore = DownloadStore(
                baseDirectory: directory,
                embyCleanupPersistence: .init(
                    read: { _ in throw InjectedTombstoneFailure() },
                    encode: { try JSONEncoder().encode($0) },
                    atomicWrite: { data, url in try data.write(to: url, options: .atomic) }
                )
            )
            guard case .failed(let loadFailure) = readFailureStore.loadEmbyConvertCleanupTombstones()
            else {
                Issue.record("Expected injected read failure")
                return
            }
            #expect(loadFailure.stage == .read)
            guard case .failed(let addReadFailure) = readFailureStore.addEmbyConvertCleanupTombstone(
                ratingKey: "emby:read", metadata: metadata("emby:read")
            ) else {
                Issue.record("Expected add read failure")
                return
            }
            #expect(addReadFailure.stage == .read)

            let encodeFailureStore = DownloadStore(
                baseDirectory: directory,
                embyCleanupPersistence: .init(
                    read: { _ in nil },
                    encode: { _ in throw InjectedTombstoneFailure() },
                    atomicWrite: { _, _ in Issue.record("Commit must not run after encode failure") }
                )
            )
            guard case .failed(let encodeFailure) = encodeFailureStore.addEmbyConvertCleanupTombstone(
                ratingKey: "emby:encode", metadata: metadata("emby:encode")
            ) else {
                Issue.record("Expected injected encode failure")
                return
            }
            #expect(encodeFailure.stage == .encode)
        }
    }

    @Test func tempWriteThenFailurePreservesThePreviousCanonicalQueue() throws {
        try withTemporaryDirectory { directory in
            let initial = DownloadStore(baseDirectory: directory)
            let first = try committedAdd(initial, ratingKey: "emby:first")
            let canonical = cleanupAuthority(for: directory)
                .appendingPathComponent("emby-convert-cleanup.json")
            let previous = try Data(contentsOf: canonical)
            let temp = directory.appendingPathComponent("injected-tombstone.tmp")
            let failing = DownloadStore(
                baseDirectory: directory,
                embyCleanupPersistence: .init(
                    read: { try Data(contentsOf: $0) },
                    encode: { try JSONEncoder().encode($0) },
                    atomicWrite: { data, _ in
                        try data.write(to: temp)
                        throw InjectedTombstoneFailure()
                    }
                )
            )

            guard case .failed(let failure) = failing.addEmbyConvertCleanupTombstone(
                ratingKey: "emby:second", metadata: metadata("emby:second")
            ) else {
                Issue.record("Expected temp/pre-replace failure")
                return
            }
            #expect(failure.stage == .commit)
            #expect(try Data(contentsOf: canonical) == previous)
            #expect(try loaded(DownloadStore(baseDirectory: directory)).map(\.id) == [first.id])
            #expect(FileManager.default.fileExists(atPath: temp.path))
        }
    }

    @Test func replaceThenThrowReconcilesAddFromCanonicalQueue() throws {
        try withTemporaryDirectory { directory in
            let replacing = DownloadStore(
                baseDirectory: directory,
                embyCleanupPersistence: replaceThenThrowPersistence()
            )
            guard case .committed(let tombstone) = replacing.addEmbyConvertCleanupTombstone(
                ratingKey: "emby:ambiguous", metadata: metadata("emby:ambiguous")
            ) else {
                Issue.record("Expected canonical re-read to prove the add committed")
                return
            }
            let restored = try loaded(DownloadStore(baseDirectory: directory))
            #expect(restored == [tombstone])
        }
    }

    @Test func removalFailuresNeverClaimDurableRecovery() throws {
        try withTemporaryDirectory { directory in
            let initial = DownloadStore(baseDirectory: directory)
            let first = try committedAdd(initial, ratingKey: "emby:first")
            let second = try committedAdd(initial, ratingKey: "emby:second")
            let canonical = cleanupAuthority(for: directory)
                .appendingPathComponent("emby-convert-cleanup.json")
            let previous = try Data(contentsOf: canonical)

            let beforeReplace = DownloadStore(
                baseDirectory: directory,
                embyCleanupPersistence: .init(
                    read: { try Data(contentsOf: $0) },
                    encode: { try JSONEncoder().encode($0) },
                    atomicWrite: { _, _ in throw InjectedTombstoneFailure() }
                )
            )
            guard case .failed(let preFailure) = beforeReplace.removeEmbyConvertCleanupTombstone(
                id: first.id
            ) else {
                Issue.record("Expected pre-replace removal failure")
                return
            }
            #expect(preFailure.stage == .commit)
            #expect(try Data(contentsOf: canonical) == previous)
            #expect(try loaded(DownloadStore(baseDirectory: directory)).map(\.id) == [first.id, second.id])

            let afterReplace = DownloadStore(
                baseDirectory: directory,
                embyCleanupPersistence: replaceThenThrowPersistence()
            )
            guard case .committed(removed: true) = afterReplace.removeEmbyConvertCleanupTombstone(
                id: first.id
            ) else {
                Issue.record("Expected canonical re-read to prove removal committed")
                return
            }
            #expect(try loaded(DownloadStore(baseDirectory: directory)).map(\.id) == [second.id])
        }
    }

    private func replaceThenThrowPersistence() -> DownloadStore.EmbyCleanupPersistence {
        .init(
            read: { url in
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return try Data(contentsOf: url)
            },
            encode: { try JSONEncoder().encode($0) },
            atomicWrite: { data, url in
                try data.write(to: url, options: .atomic)
                throw InjectedTombstoneFailure()
            }
        )
    }

    private func loaded(_ store: DownloadStore) throws
        -> [DownloadStore.EmbyConvertCleanupTombstone] {
        guard case .loaded(let values) = store.loadEmbyConvertCleanupTombstones() else {
            throw InjectedTombstoneFailure()
        }
        return values
    }

    private func committedAdd(_ store: DownloadStore, ratingKey: String) throws
        -> DownloadStore.EmbyConvertCleanupTombstone {
        guard case .committed(let tombstone) = store.addEmbyConvertCleanupTombstone(
            ratingKey: ratingKey, metadata: metadata(ratingKey)
        ) else {
            throw InjectedTombstoneFailure()
        }
        return tombstone
    }

    private func metadata(_ ratingKey: String) -> OfflineMetadata {
        OfflineMetadata(ratingKey: ratingKey, title: ratingKey, type: "movie")
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("emby-cleanup-tombstones-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

private struct InjectedTombstoneFailure: Error {}
