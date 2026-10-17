#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

/// Pins for the P1 review findings on static-range ownership (B00), system-cancel parking (B09) and
/// post-construction activation failure (B05/B07). Each test drives the real session delegate
/// through an injected URLProtocol that holds every request until the test resolves it.
@Suite("Background download range ownership", .serialized)
struct BackgroundDownloadRangeOwnershipTests {
    private static let trainBytes = 2 * StaticRangeTransferConfiguration.segmentBytes
    /// One closed segment: no sibling task can mask a gap in the finishing task's own ownership.
    private static let singleSegmentBytes = 1_048_576

    @Test("A finished Range body stays owned while it leaves live tracking (B00)")
    func finishedBodyIsOwnedAcrossTrackingHandoff() async throws {
        try await withRangeSession { session, store, requests in
            let key = try seedStaticRow("plex:b00-finish", bytes: Self.singleSegmentBytes, in: store)
            let observed = OwnershipObservations()
            session.rangeTrackingDroppedForTesting = { [weak session] ratingKey in
                observed.append(session?.ownsInProgressStaticRangeWork(ratingKey: ratingKey))
            }
            try startTrain(session, key: key, bytes: Self.singleSegmentBytes)
            let first = try #require(await requests.waitForCount(1).first)

            first.finish(status: 206, body: Data(repeating: 0x11, count: 64),
                         headers: ["Content-Range": "bytes 0-63/\(Self.singleSegmentBytes)"])

            #expect(await observed.waitForCount(1) == [true])
            session.cancel(ratingKey: key.ratingKey)
            await waitForSessionWorkToDrain(session, ratingKey: key.ratingKey)
        }
    }

    @Test("An errored Range task stays owned until its disposition takes over (B00)")
    func erroredTaskIsOwnedAcrossTrackingHandoff() async throws {
        try await withRangeSession { session, store, requests in
            let key = try seedStaticRow("plex:b00-error", bytes: Self.singleSegmentBytes, in: store)
            let observed = OwnershipObservations()
            session.rangeTrackingDroppedForTesting = { [weak session] ratingKey in
                observed.append(session?.ownsInProgressStaticRangeWork(ratingKey: ratingKey))
            }
            try startTrain(session, key: key, bytes: Self.singleSegmentBytes)
            let first = try #require(await requests.waitForCount(1).first)

            // An app-side cancel (-999 without a system reason) is a terminal disposition: it
            // exercises the same tracking handoff without scheduling a delayed retry that could
            // outlive the test's session.
            first.fail(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))

            #expect(await observed.waitForCount(1) == [true])
            session.cancel(ratingKey: key.ratingKey)
            await waitForSessionWorkToDrain(session, ratingKey: key.ratingKey)
        }
    }

    @Test("A system cancel of one segment parks the whole train (B09)")
    func systemCancelParksWholeTrain() async throws {
        try await withRangeSession { session, store, requests in
            let key = try seedStaticRow("plex:b09-train", in: store)
            try startTrain(session, key: key)
            let started = await requests.waitForCount(2)
            #expect(started.count == 2)
            let cancelled = try #require(started.first)

            cancelled.fail(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: [
                NSURLErrorBackgroundTaskCancelledReasonKey:
                    NSURLErrorCancelledReasonBackgroundUpdatesDisabled,
            ]))

            for _ in 0..<200 where store.record(for: key)?.status != .paused
                || session.isTrackingTransfer(ratingKey: key.ratingKey) {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(store.record(for: key)?.status == .paused)
            // The sibling segment was superseded, so its progress cannot re-promote the row.
            #expect(!session.isTrackingTransfer(ratingKey: key.ratingKey))
            #expect(await requests.waitUntilStopped(started[1]))
            try await Task.sleep(for: .milliseconds(200))
            #expect(store.record(for: key)?.status == .paused)
            #expect(await requests.count == 2)
        }
    }

    @Test("Failed activation with a live transport keeps owned holds before releasing the wake (B07)")
    func failedActivationKeepsOwnedHoldsUntilTheyDrain() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        try writeUnsupportedIndex(in: directory)
        let store = DownloadStore(
            baseDirectory: directory,
            indexPersistence: .init(atomicWrite: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }))
        let session = BackgroundDownloadSession(
            store: store, protocolClasses: [], releaseBackgroundCompletion: { _ in })
        defer { session.invalidateInjectedSessionForTesting() }
        let failed = await withCheckedContinuation { continuation in
            session.activateAfterResettingUnsupportedStore { continuation.resume(returning: $0) }
        }
        guard case .failed = failed else {
            Issue.record("Expected the unsupported reset to fail after constructing the transport")
            return
        }

        session.noteBackgroundCompletionHandlerStored(identifier: BackgroundDownloadSession.identifier)
        session.beginBackgroundCompletionOperationForTesting()
        session.releaseBackgroundCompletionAfterStartupFailure()

        let held = session.diagnosticSnapshot(includePendingTempCleanupBytes: false)
        #expect(held.pendingBackgroundCompletionOperationCount == 1)
        #expect(held.backgroundCompletionHandlerCount == 1)

        session.endBackgroundCompletionOperationForTesting()
        let drained = session.diagnosticSnapshot(includePendingTempCleanupBytes: false)
        #expect(drained.pendingBackgroundCompletionOperationCount == 0)
        #expect(drained.backgroundCompletionHandlerCount == 0)
    }

    // MARK: - Fixtures

    /// Queued appends and retries must not outlive the test's URLSession.
    private func waitForSessionWorkToDrain(
        _ session: BackgroundDownloadSession, ratingKey: String
    ) async {
        for _ in 0..<300 where session.ownsInProgressStaticRangeWork(ratingKey: ratingKey) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func withRangeSession(
        _ body: (BackgroundDownloadSession, DownloadStore, HeldRangeRequests) async throws -> Void
    ) async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let requests = HeldRangeRequests()
        HeldRangeRequestURLProtocol.configure(requests)
        defer { HeldRangeRequestURLProtocol.configure(nil) }
        let store = DownloadStore(baseDirectory: directory)
        let session = BackgroundDownloadSession(
            store: store, protocolClasses: [HeldRangeRequestURLProtocol.self])
        defer { session.invalidateInjectedSessionForTesting() }
        let activated = await withCheckedContinuation { continuation in
            session.activateCurrentStore { continuation.resume(returning: $0) }
        }
        #expect(activated == .activated(cancelledTaskCount: 0))
        try await body(session, store, requests)
    }

    private func seedStaticRow(
        _ ratingKey: String, bytes: Int = trainBytes, in store: DownloadStore
    ) throws -> DownloadAttemptKey {
        let attemptID = try #require(DownloadAttemptID(rawValue: "\(ratingKey)-attempt"))
        let key = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptID)
        let record = DownloadRecord(
            ratingKey: ratingKey, attemptID: attemptID, title: "Range",
            localURL: store.destinationURL(ratingKey: ratingKey, ext: "mp4"), status: .downloading,
            metadata: OfflineMetadata(
                ratingKey: ratingKey, title: "Range", type: "movie",
                sourcePartSize: bytes,
                backendKind: .plex,
                resumeMode: .staticByteRange))
        #expect(store.createAttemptOwnedRecord(record, attemptID: attemptID) == .committed(key))
        return key
    }

    private func startTrain(
        _ session: BackgroundDownloadSession, key: DownloadAttemptKey, bytes: Int = trainBytes
    ) throws {
        try session.start(
            ratingKey: key.ratingKey,
            from: URL(string: "https://example.invalid/\(key.ratingKey).mp4")!,
            expectedBytes: bytes,
            byteRangeCheckpoint: true)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("range-ownership-\(UUID().uuidString)", isDirectory: true)
        let directory = parent.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeUnsupportedIndex(in directory: URL) throws {
        let row: [String: Any] = [
            "ratingKey": "plex:legacy", "title": "Legacy", "relativePath": "legacy.mp4",
            "bytes": 10, "progress": 0.5, "status": "paused",
            "metadata": ["ratingKey": "plex:legacy", "title": "Legacy", "type": "movie"],
        ]
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "rows": [row]])
            .write(to: directory.appendingPathComponent("index.json"), options: .atomic)
    }
}

private final class OwnershipObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool?] = []

    func append(_ value: Bool?) { lock.withLock { values.append(value) } }

    func waitForCount(_ count: Int) async -> [Bool?] {
        for _ in 0..<300 {
            let snapshot = lock.withLock { values }
            if snapshot.count >= count { return snapshot }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return lock.withLock { values }
    }
}

private final class HeldRangeRequest: @unchecked Sendable {
    let id = UUID()
    let url: URL?
    private weak var owner: URLProtocol?

    init(owner: URLProtocol) {
        self.owner = owner
        self.url = owner.request.url
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

private final class HeldRangeRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var started: [HeldRangeRequest] = []
    private var stopped: Set<UUID> = []

    var count: Int { get async { lock.withLock { started.count } } }

    func record(_ request: HeldRangeRequest) { lock.withLock { started.append(request) } }
    func recordStop(_ id: UUID) { _ = lock.withLock { stopped.insert(id) } }

    func waitForCount(_ count: Int) async -> [HeldRangeRequest] {
        for _ in 0..<300 {
            let snapshot = lock.withLock { started }
            if snapshot.count >= count { return snapshot }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return lock.withLock { started }
    }

    func waitUntilStopped(_ request: HeldRangeRequest) async -> Bool {
        for _ in 0..<300 {
            if lock.withLock({ stopped.contains(request.id) }) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return lock.withLock { stopped.contains(request.id) }
    }
}

private final class HeldRangeRequestURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var configured: HeldRangeRequests?
    private var held: HeldRangeRequest?

    static func configure(_ requests: HeldRangeRequests?) {
        lock.withLock { configured = requests }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = HeldRangeRequest(owner: self)
        held = request
        Self.lock.withLock { Self.configured }?.record(request)
    }

    override func stopLoading() {
        guard let held else { return }
        Self.lock.withLock { Self.configured }?.recordStop(held.id)
    }
}
#endif
