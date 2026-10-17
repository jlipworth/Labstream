#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

@Suite("P5 session transport", .serialized)
struct P5SessionTransportTests {
    private let total = 1_048_576
    private let headroom = DownloadStorageAdmissionPolicy.headroomBytes

    @Test("Session preflights count held disk bytes once and reserve the largest append (pin 2)")
    func preflightPhysicalTimeline() async throws {
        try await withSession { session, store, _ in
            let key = try seed(in: store, expected: 400)
            let working = try #require(store.attemptWorkingFileURL(for: key))
            try Data(repeating: 1, count: 100).write(to: working)
            let held = store.directory.appendingPathComponent("fixture.range-held-body")
            try Data(repeating: 2, count: 100).write(to: held)
            session.claimRangeBodyForTesting(held, for: key, bytes: 100, offset: 100)
            let second = store.directory.appendingPathComponent("fixture.range-held-second")
            try Data(repeating: 3, count: 100).write(to: second)
            session.claimRangeBodyForTesting(second, for: key, bytes: 100, offset: 200)
            defer {
                session.releaseRangeBodyForTesting(held)
                session.releaseRangeBodyForTesting(second)
            }
            #expect(session.requiredAdditionalFreeBytes(for: key, expectedBytes: 300,
                durableCheckpointBytes: 100) == headroom + 100)
            #expect(session.requiredAdditionalFreeBytes(for: key, expectedBytes: 400,
                durableCheckpointBytes: 100) == headroom + 200)
            session.availableStorageBytesForTesting = headroom + 199
            #expect(throws: DownloadManager.DownloadError.storageFull) {
                try session.start(ratingKey: key.ratingKey, with: request(), expectedBytes: 400,
                                  byteRangeCheckpoint: true)
            }
            #expect(try Data(contentsOf: working).count == 100)
        }
    }

    @Test("A refused persisted blob retains its authority and watermark (pin 7)")
    func refusedPersistedBlobKeepsAuthority() async throws {
        try await withSession { session, store, requests in
            let key = try seed(in: store, expected: total)
            let blob = try PropertyListSerialization.data(fromPropertyList: [:], format: .xml, options: 0)
            _ = store.setResumeData(for: key, blob, displayBytes: 4096)
            session.availableStorageBytesForTesting = 0
            #expect(session.resumeRange(ratingKey: key.ratingKey, resumeData: blob,
                                       expectedBytes: total) == .storageRefused)
            #expect(store.resumeData(for: key) == blob)
            #expect(store.resumeDisplayBytes(for: key) == 4096)
            #expect(store.lifecycleState(for: key)?.history.lastFailure == .storage)
            #expect(requests.count == 0)
        }
    }

    @Test("A transient blob refusal stops fallback and persists OS body authority (pin 7)")
    func refusedTransientBlobDoesNotRestart() async throws {
        try await withSession { session, store, requests in
            // Unknown total uses a continuous remainder, whose OS resume blob is admissible.
            let key = try seed(in: store, expected: nil)
            try session.start(ratingKey: key.ratingKey, with: request(), byteRangeCheckpoint: true)
            let first = try #require(await requests.waitForCount(1).first)
            await session.reportRangeProgressForTesting(bytes: 4096)
            session.availableStorageBytesForTesting = 0
            let blob = try PropertyListSerialization.data(fromPropertyList: [:], format: .xml, options: 0)
            first.fail(NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost,
                userInfo: [NSURLSessionDownloadTaskResumeData: blob]))
            #expect(await waitUntil { store.lifecycleState(for: key)?.history.lastFailure == .storage })
            #expect(store.resumeData(for: key) == blob)
            #expect(store.resumeDisplayBytes(for: key) == 4096)
            #expect(requests.count == 1)
            #expect(!session.isTrackingTransfer(ratingKey: key.ratingKey))
        }
    }

    @Test("Move rehydration holds rebuild grace; delayed move retry holds an operation (pin 8)")
    func moveRecoveryHoldsBackgroundWake() async throws {
        try await withSession { session, store, requests in
            let key = try seed(in: store, expected: total)
            let observed = P5Values<DownloadAttemptKey>()
            session.onRangeRequestNeeded = { key, _ in observed.append(key) }
            #expect(session.recoverMissingRangeBodyForTesting(key, hasRequest: false))
            #expect(observed.values == [key])
            #expect(session.diagnosticSnapshot(includePendingTempCleanupBytes: false)
                .pendingBackgroundCompletionOperationCount == 1)
            session.cancel(ratingKey: key.ratingKey)
            try session.start(ratingKey: key.ratingKey, with: request(), expectedBytes: total,
                              byteRangeCheckpoint: true)
            _ = await requests.waitForCount(1)
            #expect(session.recoverMissingRangeBodyForTesting(key, hasRequest: true))
            #expect(session.diagnosticSnapshot(includePendingTempCleanupBytes: false)
                .pendingBackgroundCompletionOperationCount == 1)
            session.cancel(ratingKey: key.ratingKey)
            #expect(await waitUntil { session.diagnosticSnapshot(includePendingTempCleanupBytes: false)
                .pendingBackgroundCompletionOperationCount == 0 })
        }
    }

    @Test("A timer from before same-attempt Pause and Resume cannot register work (pin 9)")
    func oldTimerAfterResumeIsSuppressed() async throws {
        try await withSession { session, store, requests in
            let key = try seed(in: store, expected: total)
            try session.start(ratingKey: key.ratingKey, with: request(), expectedBytes: total,
                              byteRangeCheckpoint: true)
            let first = try #require(await requests.waitForCount(1).first)
            first.finish(status: 503, body: Data(), headers: [:])
            #expect(await waitUntil { session.transportRetryCountForTesting(key) == 1 })
            session.pause(ratingKey: key.ratingKey)
            try session.start(ratingKey: key.ratingKey, with: request(), expectedBytes: total,
                              byteRangeCheckpoint: true)
            _ = await requests.waitForCount(2)
            let passedCurrency = P5Values<Bool>()
            session.delayedRetryDidPassCurrencyForTesting = { passedCurrency.append(true) }
            try await Task.sleep(for: .milliseconds(1250))
            #expect(passedCurrency.values.isEmpty)
            #expect(requests.count == 2)
            #expect(session.diagnosticSnapshot(includePendingTempCleanupBytes: false)
                .pendingBackgroundCompletionOperationCount == 0)
            session.cancel(ratingKey: key.ratingKey)
        }
    }

    @Test("A Pause and Resume between timer currency and registration is fenced (pin 9)")
    func registrationRechecksGeneration() async throws {
        try await withSession { session, store, requests in
            let key = try seed(in: store, expected: total)
            let fired = P5Values<Bool>()
            let rejected = P5Values<Bool>()
            session.delayedRetryRegistrationRejectedForTesting = { rejected.append(true) }
            session.delayedRetryWillRegisterForTesting = {
                session.pause(ratingKey: key.ratingKey)
                try? session.start(ratingKey: key.ratingKey, with: request(), expectedBytes: total,
                                   byteRangeCheckpoint: true)
                fired.append(true)
            }
            #expect(session.recoverMissingRangeBodyForTesting(key, hasRequest: true))
            #expect(await waitUntil { !fired.values.isEmpty })
            #expect(await waitUntil { session.diagnosticSnapshot(includePendingTempCleanupBytes: false)
                .pendingBackgroundCompletionOperationCount == 0 })
            #expect(rejected.values == [true])
            #expect(requests.count <= 1)
            session.cancel(ratingKey: key.ratingKey)
        }
    }

    @Test("Identical optimistic prefixes exhaust the drop budget; user Resume resets it (pin 10)")
    func repeatedPrefixesExhaustTransportBudget() async throws {
        try await withSession { session, store, requests in
            let key = try seed(in: store, expected: total)
            try session.start(ratingKey: key.ratingKey, with: request(), expectedBytes: total,
                              byteRangeCheckpoint: true)
            for index in 0...BackgroundDownloadTransientRetryPolicy.defaultMaxRangeTransportRetries {
                let started = await requests.waitForCount(index + 1)
                let current = try #require(started.last)
                await session.reportRangeProgressForTesting(bytes: 512)
                #expect(session.transportRetryCountForTesting(key) == index)
                // Internal backend rebuilds may call start, but must retain the budget (bg-48).
                try session.start(ratingKey: key.ratingKey, with: request(), expectedBytes: total,
                                  byteRangeCheckpoint: true, resetRangeRestartCounters: false)
                #expect(session.transportRetryCountForTesting(key) == index)
                current.fail(NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost))
            }
            #expect(await waitUntil { store.lifecycleState(for: key)?.lifecycle == .paused })
            #expect(requests.count == BackgroundDownloadTransientRetryPolicy.defaultMaxRangeTransportRetries + 1)
            #expect(store.durableStaticRangeCheckpointSize(for: key) == 0)
            try session.start(ratingKey: key.ratingKey, with: request(), expectedBytes: total,
                              byteRangeCheckpoint: true)
            #expect(session.transportRetryCountForTesting(key) == 0)
            session.cancel(ratingKey: key.ratingKey)
        }
    }

    @Test("Only a positive durable append clears the drop budget, including held drain (pin 10)")
    func durableHeldAppendResetsBudget() async throws {
        try await withSession { session, store, _ in
            let key = try seed(in: store, expected: total)
            let working = try #require(store.attemptWorkingFileURL(for: key))
            try Data().write(to: working)
            #expect(session.recoverMissingRangeBodyForTesting(key, hasRequest: true))
            let empty = store.directory.appendingPathComponent("fixture.range-held-empty")
            try Data().write(to: empty)
            session.installHeldBodyForTesting(empty, for: key, offset: 0, length: 0)
            #expect(session.drainHeldBodiesForTesting(key) == 0)
            #expect(session.transportRetryCountForTesting(key) == 1)
            let held = store.directory.appendingPathComponent("fixture.range-held-positive")
            try Data(repeating: 1, count: 64).write(to: held)
            session.installHeldBodyForTesting(held, for: key, offset: 0, length: 64)
            #expect(session.drainHeldBodiesForTesting(key) == 64)
            #expect(session.transportRetryCountForTesting(key) == 0)
            session.cancel(ratingKey: key.ratingKey)
        }
    }

    @Test("A claimed stash created after enumeration survives the tmp sweep (pin 12)")
    func tmpSweepRechecksClaimAfterEnumeration() async throws {
        try await withSession { session, store, _ in
            let key = try seed(in: store, expected: total)
            let stash = try #require(session.rangeBodyDirectoryForTesting)
                .appendingPathComponent("vp-range-body-987654321-o0")
            defer { try? FileManager.default.removeItem(at: stash) }
            // Enumerate the path first, then replace it with a newly claimed delegate body.
            try Data("old".utf8).write(to: stash)
            session.rangeStashSweepDidEnumerateForTesting = {
                session.claimRangeBodyForTesting(stash, for: key, bytes: 3)
                try? Data("new".utf8).write(to: stash)
            }
            session.sweepRangeBodiesForTesting(durable: false)
            #expect(try Data(contentsOf: stash) == Data("new".utf8))
            session.rangeStashSweepDidEnumerateForTesting = nil
            session.releaseRangeBodyForTesting(stash)
            session.sweepRangeBodiesForTesting(durable: false)
            #expect(!FileManager.default.fileExists(atPath: stash.path))
        }
    }

    @Test("A queued delegate append keeps its tmp body claimed (pin 12)")
    func queuedAppendKeepsStash() async throws {
        try await withSession { session, store, requests in
            let key = try seed(in: store, expected: total)
            try session.start(ratingKey: key.ratingKey, with: request(), expectedBytes: total,
                              byteRangeCheckpoint: true)
            let first = try #require(await requests.waitForCount(1).first)
            session.holdRangeIOForTesting()
            first.finish(status: 206, body: Data(repeating: 1, count: 64),
                         headers: ["Content-Range": "bytes 0-63/\(total)"])
            let captured = await waitUntil { !session.claimedRangeBodiesForTesting().isEmpty }
            let paths = session.claimedRangeBodiesForTesting()
            session.sweepRangeBodiesForTesting(durable: false)
            #expect(captured)
            #expect(paths.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
            session.releaseRangeIOForTesting()
            #expect(await waitUntil { session.claimedRangeBodiesForTesting().isEmpty })
            session.cancel(ratingKey: key.ratingKey)
        }
    }

    @Test("The durable sweep rechecks claims after taking its reference snapshot (pin 12)")
    func durableSweepRechecksClaimAfterEnumeration() async throws {
        try await withSession { session, store, _ in
            let key = try seed(in: store, expected: total)
            // The existing durable sweep targets this legacy filename class; opaque attempt-stage
            // filenames remain excluded. Exercise the deletion boundary with an eligible path.
            let held = store.directory.appendingPathComponent("fixture.range-held-128")
            try Data("old".utf8).write(to: held)
            session.durableStashSweepDidEnumerateForTesting = {
                session.claimRangeBodyForTesting(held, for: key, bytes: 3, offset: 128)
                try? Data("new".utf8).write(to: held)
            }
            session.sweepRangeBodiesForTesting(durable: true)
            #expect(try Data(contentsOf: held) == Data("new".utf8))
            session.durableStashSweepDidEnumerateForTesting = nil
            session.releaseRangeBodyForTesting(held)
            session.sweepRangeBodiesForTesting(durable: true)
            #expect(!FileManager.default.fileExists(atPath: held.path))
        }
    }

    @Test("The durable rename remains claimed before manifest publication (pin 12)")
    func durableSweepProtectsRenameBeforeManifest() async throws {
        try await withSession { session, store, _ in
            let key = try seed(in: store, expected: total)
            let working = try #require(store.attemptWorkingFileURL(for: key))
            try Data().write(to: working)
            let stash = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data(repeating: 1, count: 64).write(to: stash)
            let observed = P5Values<Bool>()
            session.durableHeldBodyDidRenameForTesting = { url in
                session.sweepRangeBodiesForTesting(durable: true)
                observed.append(FileManager.default.fileExists(atPath: url.path)
                    && session.claimedRangeBodiesForTesting().contains(url.standardizedFileURL))
            }
            session.applyFinishedHeldRangeBodyForTesting(attemptKey: key, workingURL: working,
                expectedBytes: total, baseOffset: 128, segmentLength: 64, stash: stash,
                contentRangeStart: 128)
            #expect(await waitUntil { !observed.values.isEmpty })
            #expect(observed.values == [true])
            #expect(await waitUntil { store.record(for: key)?.metadata?.heldRangeSegments?.count == 1 })
            session.cancel(ratingKey: key.ratingKey)
        }
    }

    private func request() -> URLRequest { URLRequest(url: URL(string: "https://example.invalid/body")!) }

    private func seed(in store: DownloadStore, expected: Int?) throws -> DownloadAttemptKey {
        let key = DownloadAttemptKey(ratingKey: "plex:p5-fixture", attemptID: .init(uuid: UUID()))
        let record = DownloadRecord(ratingKey: key.ratingKey, attemptID: key.attemptID, title: "Item",
            localURL: store.destinationURL(ratingKey: key.ratingKey, ext: "mp4"), status: .downloading,
            metadata: OfflineMetadata(ratingKey: key.ratingKey, title: "Item", type: "movie",
                sourcePartSize: expected, backendKind: .plex, resumeMode: .staticByteRange))
        #expect(store.createAttemptOwnedRecord(record, attemptID: key.attemptID) == .committed(key))
        return key
    }

    private func withSession(_ body: (BackgroundDownloadSession, DownloadStore, P5HeldRequests) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("p5-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let requests = P5HeldRequests()
        P5HeldRequestURLProtocol.configure(requests)
        defer { P5HeldRequestURLProtocol.configure(nil) }
        let store = DownloadStore(baseDirectory: directory)
        let session = BackgroundDownloadSession(store: store, protocolClasses: [P5HeldRequestURLProtocol.self])
        let temporaryBodies = directory.appendingPathComponent("NetworkTemps", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryBodies, withIntermediateDirectories: true)
        session.rangeBodyDirectoryForTesting = temporaryBodies
        session.availableStorageBytesForTesting = Int64.max
        defer { session.invalidateInjectedSessionForTesting() }
        let activated = await withCheckedContinuation { continuation in
            session.activateCurrentStore { continuation.resume(returning: $0) }
        }
        #expect(activated == .activated(cancelledTaskCount: 0))
        try await body(session, store, requests)
        for record in store.records { session.cancel(ratingKey: record.ratingKey) }
        _ = await waitUntil {
            session.diagnosticSnapshot(includePendingTempCleanupBytes: false)
                .pendingBackgroundCompletionOperationCount == 0
        }
        _ = await store.flushLifecycleAndPersistence(through: store.currentPersistenceTicket(),
            artifactWatermark: store.currentArtifactLifecycleWatermark(), timeout: 5)
    }

    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<700 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
}

private final class P5Values<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []
    var values: [Value] { lock.withLock { stored } }
    func append(_ value: Value) { lock.withLock { stored.append(value) } }
}

private final class P5HeldRequest: @unchecked Sendable {
    let id = UUID()
    let url: URL?
    let range: String?
    private weak var owner: URLProtocol?

    init(owner: URLProtocol) {
        self.owner = owner
        self.url = owner.request.url
        self.range = owner.request.value(forHTTPHeaderField: "Range")
    }

    func finish(status: Int, body: Data, headers: [String: String]) {
        guard let owner, let url, let client = owner.client,
              let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
        else { return }
        client.urlProtocol(owner, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(owner, didLoad: body)
        client.urlProtocolDidFinishLoading(owner)
    }

    func fail(_ error: Error) {
        guard let owner else { return }
        owner.client?.urlProtocol(owner, didFailWithError: error)
    }
}

private final class P5HeldRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var started: [P5HeldRequest] = []

    func record(_ request: P5HeldRequest) { lock.withLock { started.append(request) } }

    var count: Int { lock.withLock { started.count } }

    func waitForCount(_ count: Int) async -> [P5HeldRequest] {
        for _ in 0..<1000 {
            let snapshot = lock.withLock { started }
            if snapshot.count >= count { return snapshot }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return lock.withLock { started }
    }
}

private final class P5HeldRequestURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var configured: P5HeldRequests?
    private var held: P5HeldRequest?

    static func configure(_ requests: P5HeldRequests?) {
        lock.withLock { configured = requests }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = P5HeldRequest(owner: self)
        held = request
        Self.lock.withLock { Self.configured }?.record(request)
    }

    override func stopLoading() {}
}
#endif
