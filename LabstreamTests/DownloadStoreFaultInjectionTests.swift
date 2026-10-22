import Foundation
import PMSKit
import Testing
@testable import Labstream

@Suite(.downloadTestFiles)
struct DownloadStoreFaultInjectionTests {
    @Test func lifecycleSubmissionReturnsWhileItsCommitIsBlockedAndCommitsLater() async throws {
        try await withTemporaryDirectory { directory in
            let blocked = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let writes = LockedFaultBox(0)
            let store = DownloadTestFiles.store(
                baseDirectory: directory,
                indexPersistence: .init { data, url in
                    let count = writes.withValue { value in value += 1; return value }
                    if count == 2 {
                        blocked.signal()
                        release.wait()
                    }
                    try data.write(to: url, options: .atomic)
                }
            )
            let attemptID = DownloadAttemptID(rawValue: UUID().uuidString)!
            guard case .committed(let key) = store.createAttemptOwnedRecord(
                Self.record("plex:lifecycle-ticket", directory: directory, bytes: 1),
                attemptID: attemptID
            ) else {
                Issue.record("Seed must commit")
                return
            }

            let submission = store.submitStatus(for: key, .paused)
            guard case .accepted(change: .applied, ticket: let ticket?) = submission else {
                Issue.record("Expected an exact accepted persistence ticket")
                return
            }
            #expect(await waitForSignal(blocked))
            #expect(store.status(for: key.ratingKey) == .paused)
            #expect(await store.flushPersistence(through: ticket, timeout: 0.01)
                == .timedOut(targetRevision: ticket.revision, committedRevision: 1))

            release.signal()
            #expect(await store.flushPersistence(through: ticket, timeout: 1)
                == .committed(revision: ticket.revision))
            let restored = DownloadTestFiles.store(baseDirectory: directory)
            #expect(restored.status(for: key.ratingKey) == .paused)
        }
    }

    @Test func blockedOlderSubmissionStillFinishesWithNewestFreshStoreSnapshot() async throws {
        try await withTemporaryDirectory { directory in
            // This establishes ordering of two disjoint full-state submissions while older I/O
            // is blocked. It does not exercise the synchronous upsert wrapper's wait contract.
            let seed = DownloadTestFiles.store(baseDirectory: directory)
            let firstID = try #require(DownloadAttemptID(rawValue: "first-attempt"))
            let secondID = try #require(DownloadAttemptID(rawValue: "second-attempt"))
            guard case .committed(let firstKey) = seed.createAttemptOwnedRecord(
                Self.record("plex:first", directory: directory, bytes: 1), attemptID: firstID),
                  case .committed(let secondKey) = seed.createAttemptOwnedRecord(
                Self.record("plex:second", directory: directory, bytes: 2), attemptID: secondID) else {
                Issue.record("Seed rows must commit before the ordering experiment")
                return
            }
            let firstWriteStarted = DispatchSemaphore(value: 0)
            let releaseFirstWrite = DispatchSemaphore(value: 0)
            defer { releaseFirstWrite.signal() }
            let writeCount = LockedFaultBox(0)
            let store = DownloadTestFiles.store(
                baseDirectory: directory,
                indexPersistence: .init { data, url in
                    let count = writeCount.withValue { value in value += 1; return value }
                    if count == 1 {
                        firstWriteStarted.signal()
                        releaseFirstWrite.wait()
                    }
                    try data.write(to: url, options: .atomic)
                }
            )
            guard case .accepted(change: .applied, ticket: let firstTicket?) =
                    store.submitStatus(for: firstKey, .paused) else {
                Issue.record("First mutation must return an admitted full-snapshot ticket")
                return
            }
            // Bounded fixture guard, not a revision-polling deadline or correctness oracle.
            try #require(await waitForSignal(firstWriteStarted, timeout: 30))
            guard case .accepted(change: .applied, ticket: let secondTicket?) =
                    store.submitStatus(for: secondKey, .failed) else {
                Issue.record("Second mutation must return an admitted full-snapshot ticket")
                return
            }
            #expect(firstTicket.revision == 1)
            #expect(secondTicket.revision == 2)
            #expect(store.currentPersistenceTicket() == secondTicket)
            #expect(store.status(for: firstKey.ratingKey) == .paused)
            #expect(store.status(for: secondKey.ratingKey) == .failed)
            releaseFirstWrite.signal()
            try #require(await store.flushPersistence(through: secondTicket, timeout: 30)
                == .committed(revision: secondTicket.revision))
            let restored = DownloadTestFiles.store(baseDirectory: directory)
            #expect(Set(restored.records.map(\.ratingKey)) == ["plex:first", "plex:second"])
            #expect(restored.status(for: firstKey.ratingKey) == .paused)
            #expect(restored.status(for: secondKey.ratingKey) == .failed)
            #expect(writeCount.value == 2)
        }
    }

    @Test func concurrentDisjointMutationsRestoreOneCoherentFullSnapshot() async throws {
        try await withTemporaryDirectory { directory in
            let store = DownloadTestFiles.store(baseDirectory: directory)
            var attemptKeys: [Int: DownloadAttemptKey] = [:]
            for index in 0..<21 {
                let id = DownloadAttemptID(uuid: UUID())
                guard case .committed(let key) = store.createAttemptOwnedRecord(
                    Self.record(Self.key(index), directory: directory, bytes: index),
                    attemptID: id) else {
                    Issue.record("seed must commit"); return
                }
                attemptKeys[index] = key
            }
            let seededAttemptKeys = attemptKeys

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
                            if let key = seededAttemptKeys[index] { _ = store.remove(for: key) }
                        }
                    }
                }
            }
            // One final synchronous full-state mutation is the deterministic durability barrier;
            // it captures even progress updates intentionally throttled during the stress fanout.
            store.setStatus(ratingKey: Self.key(20), .paused)

            let restored = DownloadTestFiles.store(baseDirectory: directory)
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
            let initial = DownloadTestFiles.store(baseDirectory: directory)
            initial.upsert(Self.record("plex:old", directory: directory, bytes: 1))

            let harness = StagedIndexCommitHarness(mode: mode, directory: directory)
            let store = DownloadTestFiles.store(
                baseDirectory: directory,
                indexPersistence: .init { data, url in try harness.write(data, to: url) }
            )
            store.upsert(Self.record("plex:new", directory: directory, bytes: 2))

            let afterFailure = DownloadTestFiles.store(baseDirectory: directory)
            let keysAfterFailure = Set(afterFailure.records.map(\.ratingKey))
            if mode == .replaceThenThrow {
                #expect(keysAfterFailure == ["plex:old", "plex:new"])
            } else {
                #expect(keysAfterFailure == ["plex:old"])
            }

            let ticket = store.currentPersistenceTicket()
            #expect(await store.flushPersistence(through: ticket, timeout: 1)
                == .committed(revision: ticket.revision))
            #expect(Set(DownloadTestFiles.store(baseDirectory: directory).records.map(\.ratingKey))
                == ["plex:old", "plex:new"])
        }
    }

    @Test(arguments: [CocoaError.Code.fileWriteNoPermission, .fileWriteOutOfSpace])
    func permissionAndOutOfSpaceFailuresRemainDirtyAndPreserveLastIndex(
        code: CocoaError.Code
    ) async throws {
        try await withTemporaryDirectory { directory in
            let initial = DownloadTestFiles.store(baseDirectory: directory)
            initial.upsert(Self.record("plex:old", directory: directory, bytes: 1))
            let store = DownloadTestFiles.store(
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
            #expect(Set(DownloadTestFiles.store(baseDirectory: directory).records.map(\.ratingKey)) == ["plex:old"])
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

    private func waitForSignal(_ semaphore: DispatchSemaphore, timeout: TimeInterval = 1) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + timeout) == .success)
            }
        }
    }

    private func withTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = DownloadTestFiles.temporaryDirectory
            .appendingPathComponent("download-store-faults-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

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
