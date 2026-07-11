import Foundation
import PMSKit
import Testing
@testable import Labstream

struct DownloadStoreFaultInjectionTests {
    @Test func blockedOlderCommitStillFinishesWithNewestFreshStoreSnapshot() async throws {
        try await withTemporaryDirectory { directory in
            let firstWriteStarted = DispatchSemaphore(value: 0)
            let releaseFirstWrite = DispatchSemaphore(value: 0)
            let writeCount = LockedFaultBox(0)
            let store = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in
                    let count = writeCount.withValue { value in
                        value += 1
                        return value
                    }
                    if count == 1 {
                        firstWriteStarted.signal()
                        releaseFirstWrite.wait()
                    }
                    try data.write(to: url, options: .atomic)
                }
            )

            let first = Task.detached {
                store.upsert(Self.record("plex:first", directory: directory, bytes: 1))
            }
            #expect(await waitForSignal(firstWriteStarted))
            let second = Task.detached {
                store.upsert(Self.record("plex:second", directory: directory, bytes: 2))
            }
            #expect(await eventually { store.currentPersistenceTicket().revision == 2 })

            releaseFirstWrite.signal()
            await first.value
            await second.value

            let restored = DownloadStore(baseDirectory: directory)
            #expect(Set(restored.records.map(\.ratingKey)) == ["plex:first", "plex:second"])
            #expect(writeCount.value == 2)
        }
    }

    @Test func concurrentDisjointMutationsRestoreOneCoherentFullSnapshot() async throws {
        try await withTemporaryDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            for index in 0..<21 {
                store.upsert(Self.record(Self.key(index), directory: directory, bytes: index))
            }

            await withTaskGroup(of: Void.self) { group in
                for index in 0..<20 {
                    group.addTask {
                        switch index {
                        case 0..<5:
                            store.updateProgress(
                                ratingKey: Self.key(index), bytes: 10_000 + index, progress: 0.75
                            )
                        case 5..<10:
                            store.setStatus(ratingKey: Self.key(index), .failed)
                        case 10..<15:
                            store.setPosterRelativePath(
                                ratingKey: Self.key(index), "poster-\(index).jpg"
                            )
                        default:
                            store.remove(ratingKey: Self.key(index))
                        }
                    }
                }
            }
            // One final synchronous full-state mutation is the deterministic durability barrier;
            // it captures even progress updates intentionally throttled during the stress fanout.
            store.setStatus(ratingKey: Self.key(20), .paused)

            let restored = DownloadStore(baseDirectory: directory)
            for index in 0..<5 {
                let row = try #require(restored.record(for: Self.key(index)))
                #expect(row.bytes == 10_000 + index)
                #expect(row.progress == 0.75)
                #expect(row.status == .downloading)
            }
            for index in 5..<10 {
                #expect(restored.status(for: Self.key(index)) == .failed)
            }
            for index in 10..<15 {
                #expect(restored.metadata(for: Self.key(index))?.posterRelativePath == "poster-\(index).jpg")
            }
            for index in 15..<20 {
                #expect(!restored.contains(ratingKey: Self.key(index)))
            }
            #expect(restored.status(for: Self.key(20)) == .paused)
        }
    }

    @Test(arguments: IndexCommitFailureMode.allCases)
    func stagedIndexFailureKeepsAReadableCanonicalAndDirtyRetryCommits(
        mode: IndexCommitFailureMode
    ) async throws {
        try await withTemporaryDirectory { directory in
            let initial = DownloadStore(baseDirectory: directory)
            initial.upsert(Self.record("plex:old", directory: directory, bytes: 1))

            let harness = StagedIndexCommitHarness(mode: mode, directory: directory)
            let store = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in try harness.write(data, to: url) }
            )
            store.upsert(Self.record("plex:new", directory: directory, bytes: 2))

            let afterFailure = DownloadStore(baseDirectory: directory)
            let keysAfterFailure = Set(afterFailure.records.map(\.ratingKey))
            if mode == .replaceThenThrow {
                #expect(keysAfterFailure == ["plex:old", "plex:new"])
            } else {
                #expect(keysAfterFailure == ["plex:old"])
            }

            let ticket = store.currentPersistenceTicket()
            #expect(await store.flushPersistence(through: ticket, timeout: 1)
                == .committed(revision: ticket.revision))
            #expect(Set(DownloadStore(baseDirectory: directory).records.map(\.ratingKey))
                == ["plex:old", "plex:new"])
        }
    }

    @Test(arguments: [CocoaError.Code.fileWriteNoPermission, .fileWriteOutOfSpace])
    func permissionAndOutOfSpaceFailuresRemainDirtyAndPreserveLastIndex(
        code: CocoaError.Code
    ) async throws {
        try await withTemporaryDirectory { directory in
            let initial = DownloadStore(baseDirectory: directory)
            initial.upsert(Self.record("plex:old", directory: directory, bytes: 1))
            let store = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { _, _ in throw CocoaError(code) }
            )
            store.upsert(Self.record("plex:new", directory: directory, bytes: 2))
            let ticket = store.currentPersistenceTicket()

            guard case .failed(let revision, let stage, _) = await store.flushPersistence(
                through: ticket, timeout: 1
            ) else {
                Issue.record("Expected an observable persistence failure")
                return
            }
            #expect(revision == ticket.revision)
            #expect(stage == "commit")
            #expect(Set(DownloadStore(baseDirectory: directory).records.map(\.ratingKey)) == ["plex:old"])
        }
    }

    @Test func mediaRemovalFailureCannotResurrectTheDurablyDeletedRow() throws {
        try withTemporaryDirectory { directory in
            let mediaURL = directory.appendingPathComponent("owned.mp4")
            try Data([1, 2, 3]).write(to: mediaURL)
            let fileManager = SelectiveRemovalFailureFileManager(blockedPath: mediaURL.path)
            let store = DownloadStore(baseDirectory: directory, fileManager: fileManager)
            store.upsert(DownloadRecord(
                ratingKey: "plex:owned",
                title: "Owned",
                localURL: mediaURL,
                bytes: 3,
                progress: 1,
                status: .complete,
                metadata: OfflineMetadata(ratingKey: "plex:owned", title: "Owned", type: "movie")
            ))

            store.remove(ratingKey: "plex:owned")

            #expect(FileManager.default.fileExists(atPath: mediaURL.path))
            #expect(!DownloadStore(baseDirectory: directory).contains(ratingKey: "plex:owned"))
        }
    }

    private static func record(_ ratingKey: String, directory: URL, bytes: Int) -> DownloadRecord {
        DownloadRecord(
            ratingKey: ratingKey,
            title: ratingKey,
            localURL: directory.appendingPathComponent("\(ratingKey.replacingOccurrences(of: ":", with: "-")).mp4"),
            bytes: bytes,
            progress: 0.25,
            status: .queued,
            metadata: OfflineMetadata(ratingKey: ratingKey, title: ratingKey, type: "movie")
        )
    }

    private static func key(_ index: Int) -> String { "plex:item-\(index)" }

    private func waitForSignal(_ semaphore: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 1) == .success)
            }
        }
    }

    private func eventually(_ predicate: @escaping @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-store-faults-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func withTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-store-faults-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }
}

enum IndexCommitFailureMode: String, CaseIterable, Sendable {
    case beforeTempWrite
    case afterTempWriteBeforeReplace
    case replaceThenThrow
}

private final class StagedIndexCommitHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = true
    private let mode: IndexCommitFailureMode
    private let tempURL: URL

    init(mode: IndexCommitFailureMode, directory: URL) {
        self.mode = mode
        self.tempURL = directory.appendingPathComponent("injected-index.tmp")
    }

    func write(_ data: Data, to url: URL) throws {
        let fail = lock.withLock {
            defer { shouldFail = false }
            return shouldFail
        }
        guard fail else {
            try data.write(to: url, options: .atomic)
            return
        }
        switch mode {
        case .beforeTempWrite:
            throw InjectedIndexCommitFailure()
        case .afterTempWriteBeforeReplace:
            try data.write(to: tempURL)
            throw InjectedIndexCommitFailure()
        case .replaceThenThrow:
            try data.write(to: url, options: .atomic)
            throw InjectedIndexCommitFailure()
        }
    }
}

private final class SelectiveRemovalFailureFileManager: FileManager, @unchecked Sendable {
    private let blockedPath: String

    init(blockedPath: String) {
        self.blockedPath = blockedPath
        super.init()
    }

    override func removeItem(at URL: URL) throws {
        if URL.path == blockedPath { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(at: URL)
    }
}

private final class LockedFaultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value { lock.withLock { storage } }

    @discardableResult
    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&storage) }
    }
}

private struct InjectedIndexCommitFailure: Error {}
