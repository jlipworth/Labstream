import Foundation
import PMSKit
import Testing
@testable import Labstream

struct EmbyCleanupTombstonePersistenceTests {
    private func cleanupAuthority(for root: URL) -> URL {
        root.deletingLastPathComponent().appendingPathComponent(
            ".\(root.lastPathComponent)-download-authority", isDirectory: true)
    }

    @Test func journalIODoesNotHoldTheDownloadIndexLock() throws {
        try withTemporaryDirectory { directory in
            let readEntered = DispatchSemaphore(value: 0)
            let releaseRead = DispatchSemaphore(value: 0)
            let loadFinished = DispatchSemaphore(value: 0)
            let indexReadFinished = DispatchSemaphore(value: 0)
            let store = DownloadStore(
                baseDirectory: directory,
                embyCleanupPersistence: .init(
                    read: { _ in
                        readEntered.signal()
                        releaseRead.wait()
                        return nil
                    },
                    encode: { try JSONEncoder().encode($0) },
                    commit: { data, url in try data.write(to: url, options: .atomic) }
                )
            )

            DispatchQueue.global().async {
                _ = store.loadEmbyConvertCleanupTombstones()
                loadFinished.signal()
            }
            defer { releaseRead.signal() }
            // Hosted matrices schedule hundreds of tests concurrently. These waits detect
            // deadlock rather than impose a product latency requirement, so keep them bounded
            // while allowing the coordination blocks to be descheduled behind suite-wide load.
            let coordinationTimeout = DispatchTimeInterval.seconds(10)
            guard readEntered.wait(timeout: .now() + coordinationTimeout) == .success else {
                Issue.record("Expected the injected cleanup-journal read to begin")
                return
            }

            DispatchQueue.global().async {
                _ = store.contains(ratingKey: "unrelated-index-row")
                indexReadFinished.signal()
            }
            #expect(indexReadFinished.wait(timeout: .now() + coordinationTimeout) == .success)
            releaseRead.signal()
            #expect(loadFinished.wait(timeout: .now() + coordinationTimeout) == .success)
        }
    }

    @Test func missingQueueLoadsEmptyAndValidMutationsPreserveSiblings() throws {
        try withTemporaryDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            #expect(try loaded(store).isEmpty)

            let first = LegacyEmbyTombstoneFixture.make(ratingKey: "emby:same")
            let second = LegacyEmbyTombstoneFixture.make(ratingKey: "emby:same")
            try LegacyEmbyTombstoneFixture.write([first, second], to: store)
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
                    commit: { data, url in try data.write(to: url, options: .atomic) }
                )
            )
            guard case .failed(let loadFailure) = readFailureStore.loadEmbyConvertCleanupTombstones()
            else {
                Issue.record("Expected injected read failure")
                return
            }
            #expect(loadFailure.stage == .read)
            guard case .failed(let removeReadFailure) = readFailureStore.removeEmbyConvertCleanupTombstone(id: UUID())
            else { Issue.record("Expected remove read failure"); return }
            #expect(removeReadFailure.stage == .read)

            let tombstone = LegacyEmbyTombstoneFixture.make(ratingKey: "emby:encode")
            let legacyData = try JSONEncoder().encode([tombstone])
            let encodeFailureStore = DownloadStore(
                baseDirectory: directory,
                embyCleanupPersistence: .init(
                    read: { _ in legacyData },
                    encode: { _ in throw InjectedTombstoneFailure() },
                    commit: { _, _ in Issue.record("Commit must not run after encode failure") }
                )
            )
            guard case .failed(let encodeFailure) = encodeFailureStore.removeEmbyConvertCleanupTombstone(
                id: tombstone.id
            ) else {
                Issue.record("Expected injected encode failure")
                return
            }
            #expect(encodeFailure.stage == .encode)
        }
    }

    @Test func removalFailuresNeverClaimDurableRecovery() throws {
        try withTemporaryDirectory { directory in
            let initial = DownloadStore(baseDirectory: directory)
            let first = LegacyEmbyTombstoneFixture.make(ratingKey: "emby:first")
            let second = LegacyEmbyTombstoneFixture.make(ratingKey: "emby:second")
            try LegacyEmbyTombstoneFixture.write([first, second], to: initial)
            let canonical = cleanupAuthority(for: directory)
                .appendingPathComponent("emby-convert-cleanup.json")
            let previous = try Data(contentsOf: canonical)

            let beforeReplace = DownloadStore(
                baseDirectory: directory,
                embyCleanupPersistence: .init(
                    read: { try Data(contentsOf: $0) },
                    encode: { try JSONEncoder().encode($0) },
                    commit: { _, _ in throw InjectedTombstoneFailure() }
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
            guard case .failed(let postFailure) = afterReplace.removeEmbyConvertCleanupTombstone(
                id: first.id
            ) else {
                Issue.record("A removal whose commit keeps throwing must not claim durability")
                return
            }
            #expect(postFailure.stage == .commit)
        }
    }

    private func replaceThenThrowPersistence() -> DownloadStore.EmbyCleanupPersistence {
        .init(
            read: { url in
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return try Data(contentsOf: url)
            },
            encode: { try JSONEncoder().encode($0) },
            commit: { data, url in
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

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("emby-cleanup-tombstones-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

private struct InjectedTombstoneFailure: Error {}
