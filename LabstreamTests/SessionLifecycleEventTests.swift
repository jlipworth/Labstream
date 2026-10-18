#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

/// P3a session conversion pins: BackgroundDownloadSession writes lifecycle through reducer events,
/// so the durable history records why a row paused or failed — not just the derived status. Each
/// test drives the real session delegate through an injected URLProtocol that holds every request
/// until the test resolves it (modelled on the range-ownership harness).
@Suite("Session lifecycle events", .serialized)
struct SessionLifecycleEventTests {
    private static let trainBytes = 2 * StaticRangeTransferConfiguration.segmentBytes

    @Test("A user pause records the user pause cause")
    func userPauseRecordsUserCause() async throws {
        try await withRangeSession { session, store, requests in
            let key = try seedStaticRow("plex:p3a-user-pause", in: store)
            try startTrain(session, key: key)
            #expect(await requests.waitForCount(2).count == 2)

            session.pause(ratingKey: key.ratingKey)

            for _ in 0..<200 where store.lifecycleState(for: key)?.lifecycle != .paused {
                try await Task.sleep(for: .milliseconds(10))
            }
            let state = try #require(store.lifecycleState(for: key))
            #expect(state.lifecycle == .paused)
            #expect(state.history.pauseCause == .user)
            #expect(store.record(for: key)?.status == .paused)
            await waitForSessionWorkToDrain(session, ratingKey: key.ratingKey)
        }
    }

    @Test("A system-cancelled Range segment records the system-interrupted pause cause")
    func systemCancelRecordsSystemInterruptedCause() async throws {
        try await withRangeSession { session, store, requests in
            let key = try seedStaticRow("plex:p3a-system-cancel", in: store)
            try startTrain(session, key: key)
            let started = await requests.waitForCount(2)
            let cancelled = try #require(started.first)

            cancelled.fail(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: [
                NSURLErrorBackgroundTaskCancelledReasonKey:
                    NSURLErrorCancelledReasonBackgroundUpdatesDisabled,
            ]))

            for _ in 0..<200 where store.lifecycleState(for: key)?.lifecycle != .paused {
                try await Task.sleep(for: .milliseconds(10))
            }
            let state = try #require(store.lifecycleState(for: key))
            #expect(state.lifecycle == .paused)
            #expect(state.history.pauseCause == .systemInterrupted)
            #expect(store.record(for: key)?.status == .paused)
            await waitForSessionWorkToDrain(session, ratingKey: key.ratingKey)
        }
    }

    @Test("A terminal Range HTTP failure records its failure reason")
    func terminalRangeFailureRecordsReason() async throws {
        try await withRangeSession { session, store, requests in
            let key = try seedStaticRow("plex:p3a-terminal-404", in: store)
            try startTrain(session, key: key)
            let started = await requests.waitForCount(2)
            let first = try #require(started.first)

            // 404 is neither transient nor an auth rehydration status: the train fails terminally.
            first.finish(status: 404, body: Data("missing".utf8), headers: [:])

            for _ in 0..<300 where store.lifecycleState(for: key)?.lifecycle != .failed {
                try await Task.sleep(for: .milliseconds(10))
            }
            let state = try #require(store.lifecycleState(for: key))
            #expect(state.lifecycle == .failed)
            #expect(state.history.lastFailure == .sourceMissing)
            #expect(store.record(for: key)?.status == .failed)
            await waitForSessionWorkToDrain(session, ratingKey: key.ratingKey)
        }
    }

    // MARK: - Fixtures

    private func waitForSessionWorkToDrain(
        _ session: BackgroundDownloadSession, ratingKey: String
    ) async {
        for _ in 0..<300 where session.ownsInProgressStaticRangeWork(ratingKey: ratingKey) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func withRangeSession(
        _ body: (BackgroundDownloadSession, DownloadStore, LifecycleHeldRequests) async throws -> Void
    ) async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let requests = LifecycleHeldRequests()
        LifecycleHeldRequestURLProtocol.configure(requests)
        defer { LifecycleHeldRequestURLProtocol.configure(nil) }
        let store = DownloadStore(baseDirectory: directory)
        let session = BackgroundDownloadSession(
            store: store, protocolClasses: [LifecycleHeldRequestURLProtocol.self])
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
            .appendingPathComponent("session-lifecycle-\(UUID().uuidString)", isDirectory: true)
        let directory = parent.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class LifecycleHeldRequest: @unchecked Sendable {
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

private final class LifecycleHeldRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var started: [LifecycleHeldRequest] = []

    func record(_ request: LifecycleHeldRequest) { lock.withLock { started.append(request) } }

    func waitForCount(_ count: Int) async -> [LifecycleHeldRequest] {
        for _ in 0..<300 {
            let snapshot = lock.withLock { started }
            if snapshot.count >= count { return snapshot }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return lock.withLock { started }
    }
}

private final class LifecycleHeldRequestURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var configured: LifecycleHeldRequests?
    private var held: LifecycleHeldRequest?

    static func configure(_ requests: LifecycleHeldRequests?) {
        lock.withLock { configured = requests }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = LifecycleHeldRequest(owner: self)
        held = request
        Self.lock.withLock { Self.configured }?.record(request)
    }

    override func stopLoading() {}
}
#endif
