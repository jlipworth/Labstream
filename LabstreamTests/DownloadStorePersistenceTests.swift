import Foundation
import PMSKit
import Testing
@testable import Labstream

struct DownloadStorePersistenceTests {
    @Test func mutationDoesNotReturnBeforeAtomicWriteAttemptFinishes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-store-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writeStarted = DispatchSemaphore(value: 0)
        let releaseWrite = DispatchSemaphore(value: 0)
        let mutationReturned = DispatchSemaphore(value: 0)
        let store = DownloadStore(
            baseDirectory: directory,
            indexPersistence: .init { data, url in
                writeStarted.signal()
                releaseWrite.wait()
                try data.write(to: url, options: .atomic)
            }
        )
        let record = makeRecord(
            ratingKey: "plex:blocked",
            title: "Blocked Write",
            directory: directory,
            bytes: 10
        )

        DispatchQueue.global(qos: .utility).async {
            store.upsert(record)
            mutationReturned.signal()
        }

        #expect(await waitForSignal(writeStarted, timeout: 1))
        #expect(!(await waitForSignal(mutationReturned, timeout: 0.02)))
        releaseWrite.signal()
        #expect(await waitForSignal(mutationReturned, timeout: 1))
    }

    @Test func freshStoreRestoresWriterBackedIndexWithoutChangingSchema() throws {
        try withTemporaryDirectory { directory in
            let record = makeRecord(
                ratingKey: "plex:item-1",
                title: "First Item",
                directory: directory,
                bytes: 1_024
            )

            let store = DownloadStore(baseDirectory: directory)
            store.upsert(record)

            let indexData = try Data(contentsOf: directory.appendingPathComponent("index.json"))
            let index = try #require(
                JSONSerialization.jsonObject(with: indexData) as? [String: Any]
            )
            #expect(index["schemaVersion"] as? Int == 2)

            let restored = DownloadStore(baseDirectory: directory)
            let restoredRecord = try #require(
                restored.records.first { $0.ratingKey == record.ratingKey }
            )
            #expect(restored.records.count == 1)
            #expect(restoredRecord.title == record.title)
            #expect(restoredRecord.localURL == record.localURL)
            #expect(restoredRecord.bytes == record.bytes)
            #expect(restoredRecord.status == record.status)
            #expect(restoredRecord.metadata == record.metadata)
        }
    }

    @Test func failedAtomicWriteIsRecoveredByLaterFullStateMutation() throws {
        try withTemporaryDirectory { directory in
            let writes = AtomicWriteHarness(failFirstWrite: true)
            let store = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in
                    try writes.write(data, to: url)
                }
            )

            store.upsert(makeRecord(
                ratingKey: "plex:item-1",
                title: "First Item",
                directory: directory,
                bytes: 100
            ))

            #expect(writes.attemptCount == 1)
            #expect(!FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("index.json").path
            ))

            store.upsert(makeRecord(
                ratingKey: "plex:item-2",
                title: "Second Item",
                directory: directory,
                bytes: 200
            ))

            #expect(writes.attemptCount == 2)
            let restored = DownloadStore(baseDirectory: directory)
            #expect(Set(restored.records.map(\.ratingKey)) == ["plex:item-1", "plex:item-2"])
            #expect(Dictionary(uniqueKeysWithValues: restored.records.map { ($0.ratingKey, $0.bytes) }) == [
                "plex:item-1": 100,
                "plex:item-2": 200,
            ])
        }
    }

    @Test func subtitleRepairPersistsThroughInjectedWriter() throws {
        try withTemporaryDirectory { directory in
            let ratingKey = "plex:item-1"
            let initial = DownloadStore(baseDirectory: directory)
            initial.upsert(makeRecord(
                ratingKey: ratingKey,
                title: "Subtitle Item",
                directory: directory,
                bytes: 300,
                metadata: OfflineMetadata(
                    ratingKey: ratingKey,
                    title: "Subtitle Item",
                    type: "movie"
                )
            ))

            let subtitleURL = initial.textSubtitleDestinationURL(
                ratingKey: ratingKey,
                streamID: 7,
                ext: "srt"
            )
            try Data("1\n00:00:00,000 --> 00:00:01,000\nHello\n".utf8).write(to: subtitleURL)

            let writes = AtomicWriteHarness()
            let repaired = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in
                    try writes.write(data, to: url)
                }
            )

            #expect(writes.attemptCount == 1)
            let repairedTrack = try #require(
                repaired.records.first?.metadata?.offlineTextSubtitles?.first
            )
            #expect(repairedTrack.id == 7)
            #expect(repairedTrack.codec == "srt")
            #expect(repairedTrack.relativePath == subtitleURL.lastPathComponent)

            let restored = DownloadStore(baseDirectory: directory)
            #expect(restored.records.first?.metadata?.offlineTextSubtitles == [repairedTrack])
        }
    }

    private func makeRecord(
        ratingKey: String,
        title: String,
        directory: URL,
        bytes: Int,
        metadata: OfflineMetadata? = nil
    ) -> DownloadRecord {
        DownloadRecord(
            ratingKey: ratingKey,
            title: title,
            localURL: directory.appendingPathComponent("\(ratingKey.replacingOccurrences(of: ":", with: "_")).mp4"),
            bytes: bytes,
            progress: 0.5,
            status: .paused,
            metadata: metadata
        )
    }

    private func withTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-store-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func waitForSignal(_ semaphore: DispatchSemaphore, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + timeout) == .success)
            }
        }
    }
}

private struct InjectedAtomicWriteFailure: Error {}

private final class AtomicWriteHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFailNextWrite: Bool
    private var attempts = 0

    init(failFirstWrite: Bool = false) {
        shouldFailNextWrite = failFirstWrite
    }

    var attemptCount: Int {
        lock.withLock { attempts }
    }

    func write(_ data: Data, to url: URL) throws {
        let shouldFail = lock.withLock {
            attempts += 1
            defer { shouldFailNextWrite = false }
            return shouldFailNextWrite
        }
        if shouldFail { throw InjectedAtomicWriteFailure() }
        try data.write(to: url, options: .atomic)
    }
}
