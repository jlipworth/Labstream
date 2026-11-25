#if !os(tvOS)
import Foundation
import PMSKit
import Synchronization
import Testing
@testable import Labstream

/// The recovery races an independent review found in the fixes for #472, #474, #475 and #476.
/// Each test drives the production session or store through the exact ordering the review
/// described, with the real delegate callbacks, leases and reconcile.
@Suite("Download recovery races", .downloadTestFiles, .serialized)
struct DownloadRecoveryRaceTests {
    private let body = Data(repeating: 7, count: 64 * 1_024)

    // MARK: 1. Duplicate publication of one captured body

    /// The delegate moves a finished forward-only body to its capture path. Launch recovery
    /// looks for a body there. Recovery arriving between the move and the delegate's claim used
    /// to claim the body itself and queue a publication; the delegate then queued a second one,
    /// which cleared the working path the first had just filled and failed the row.
    @Test("A recovery pass that arrives while the delegate captures a body queues no second publication")
    func recoveryDuringCaptureDoesNotPublishTwice() async throws {
        let fixture = try P6Fixture()
        let store = fixture.store()
        let key = try fixture.seed(store, mode: .liveForwardOnly, ratingKey: "jellyfin:fixture")
        let requests = HeldRangeRequests()
        RecoveryRaceURLProtocol.configure(requests)
        defer { RecoveryRaceURLProtocol.configure(nil) }
        let session = BackgroundDownloadSession(store: store, protocolClasses: [RecoveryRaceURLProtocol.self])
        defer { session.invalidateInjectedSessionForTesting() }
        try prepare(session, fixture)
        await activate(session)
        let finalizers = FinalizerRequests()
        session.onFinalizerRequest = { finalizers.append($0) }
        defer { finalizers.all.forEach { session.abandonFinalizerRequest($0) } }

        let recovered = RecoveryResult()
        session.opaqueBodyDidReachStashForTesting = { [weak session] in
            // Launch recovery, exactly where the capture is visible and the delegate has not
            // queued its publication yet.
            recovered.set(session?.finalizeCompletedStaticRangeFile(
                ratingKey: key.ratingKey, validationLabel: "forward_only_recovered"))
        }
        try session.start(ratingKey: key.ratingKey,
                          with: URLRequest(url: URL(string: "https://example.invalid/stream")!),
                          byteRangeCheckpoint: false)
        let request = try #require(await requests.waitForCount(1).first)
        request.finish(status: 200, body: body, headers: [
            "Content-Type": "video/mp4", "Content-Length": "\(body.count)",
        ])

        try #require(await wait { finalizers.count >= 1 })
        await session.drainRangeIOForTesting()
        #expect(recovered.value == true, "recovery sees the body as already owned")
        #expect(finalizers.count == 1, "one publication, so one finalization")
        let working = try #require(store.attemptWorkingFileURL(for: key))
        #expect((try? Data(contentsOf: working)) == body, "the published body is still there")
        #expect(store.lifecycleState(for: key)?.lifecycle == .finalizing)
        #expect(store.record(for: key)?.status != .failed)
        #expect(await wait { session.opaquePublicationOwnerForTesting(key) == nil })
        #expect(session.claimedRangeBodiesForTesting().isEmpty)
    }

    /// Two publications of one captured body, queued one behind the other. The working path's
    /// lease serializes them. The second finds the capture already moved; it used to clear the
    /// working path first and only then notice, deleting the only copy.
    @Test("A second publication of an already published body leaves it alone")
    func twoCompetingPublishersKeepTheBody() async throws {
        let fixture = try P6Fixture()
        let store = fixture.store()
        let key = try fixture.seed(store, mode: .liveForwardOnly, ratingKey: "jellyfin:fixture")
        let session = BackgroundDownloadSession(store: store, protocolClasses: [])
        defer { session.invalidateInjectedSessionForTesting() }
        try prepare(session, fixture)
        await activate(session)
        let finalizers = FinalizerRequests()
        session.onFinalizerRequest = { finalizers.append($0) }
        defer { finalizers.all.forEach { session.abandonFinalizerRequest($0) } }
        let capture = try #require(store.forwardOnlyCapturedBodyURL(for: key))
        try body.write(to: capture)
        let working = try #require(store.attemptWorkingFileURL(for: key))

        session.holdRangeIOForTesting()
        var held = true
        defer { if held { session.releaseRangeIOForTesting() } }
        #expect(session.finalizeCompletedStaticRangeFile(
            ratingKey: key.ratingKey, validationLabel: "forward_only_recovered"))
        session.queueCompetingOpaquePublicationForTesting(key)
        held = false
        session.releaseRangeIOForTesting()
        await session.drainRangeIOForTesting()

        #expect(!FileManager.default.fileExists(atPath: capture.path))
        #expect((try? Data(contentsOf: working)) == body, "the second publisher did not delete it")
        #expect(store.record(for: key)?.status != .failed)
        #expect(store.lifecycleState(for: key)?.lifecycle == .finalizing)
        #expect(finalizers.count == 1)
        #expect(session.opaquePublicationOwnerForTesting(key) == nil)
        #expect(session.claimedRangeBodiesForTesting().isEmpty)
    }

    // MARK: 2. A queued progress callback under a pause

    /// Every declared byte of the only segment has arrived and the task has not finished yet.
    /// The user pauses, which installs the halt. The task's last progress callback then runs
    /// before its finish callback. It used to drop the task's tracking and mark it superseded,
    /// so the finish callback dropped the body, also after the pause's task listing had
    /// already decided to leave the finished task tracked.
    @Test("The last progress of a finished task under a pause does not drop its body")
    func finalProgressBetweenPauseAndFinishKeepsTheBody() async throws {
        let bytes = 256 * 1_024
        let payload = Data(repeating: 9, count: bytes)
        let fixture = try P6Fixture()
        let store = fixture.store()
        var row = fixture.record()
        row.metadata?.sourcePartSize = bytes
        let key = DownloadAttemptKey(ratingKey: row.ratingKey, attemptID: try #require(row.attemptID))
        try #require(store.createAttemptOwnedRecord(row, attemptID: key.attemptID) == .committed(key))
        let requests = PartialRequests()
        PartialBodyURLProtocol.configure(requests)
        defer { PartialBodyURLProtocol.configure(nil) }
        let session = BackgroundDownloadSession(store: store, protocolClasses: [PartialBodyURLProtocol.self])
        defer { session.cancel(ratingKey: key.ratingKey); session.invalidateInjectedSessionForTesting() }
        try prepare(session, fixture)
        await activate(session)
        try session.start(ratingKey: key.ratingKey, from: URL(string: "https://example.invalid/body")!,
                          expectedBytes: bytes, byteRangeCheckpoint: true)
        let request = try #require(await requests.waitForFirst())
        let task = try #require(await session.healthTasksForTesting().first as? URLSessionDownloadTask)

        // The whole response body arrives; the transfer is not finished yet.
        request.respond(status: 206, body: payload, headers: [
            "Content-Range": "bytes 0-\(bytes - 1)/\(bytes)", "Content-Length": "\(bytes)",
            "Content-Type": "video/mp4",
        ])
        try #require(await wait { task.countOfBytesReceived >= Int64(bytes) })

        session.pause(ratingKey: key.ratingKey)
        // The last progress callback, after the halt and before the finish callback.
        session.urlSession(URLSession.shared, downloadTask: task, didWriteData: Int64(bytes),
                           totalBytesWritten: Int64(bytes), totalBytesExpectedToWrite: Int64(bytes))
        request.complete()

        let working = try #require(store.attemptWorkingFileURL(for: key))
        try #require(await wait {
            (try? FileManager.default.attributesOfItem(atPath: working.path)[.size] as? Int) == bytes
        }, "the finished body was written behind the pause")
        #expect((try? Data(contentsOf: working)) == payload)
        #expect(await wait { store.record(for: key)?.status == .paused })
        #expect(await wait { session.claimedRangeBodiesForTesting().isEmpty })
    }

    // MARK: 3. A lease wait that runs out

    /// The working path stays leased past the publication's deadline. The publication used to
    /// leave with its claim and nothing queued: every later recovery pass saw the claim,
    /// reported success and scheduled nothing, so the row stayed finalizing until relaunch.
    /// Now the publication is parked, and each of three things runs it again.
    @Test("A publication that times out on the working path's lease runs again",
          arguments: ["lease_release", "recovery_pass", "backstop"])
    func leaseTimeoutDoesNotStrandTheBody(wake: String) async throws {
        let fixture = try P6Fixture()
        let store = fixture.store()
        let key = try fixture.seed(store, mode: .liveForwardOnly, ratingKey: "jellyfin:fixture")
        let session = BackgroundDownloadSession(
            store: store, protocolClasses: [],
            wakeBudget: .init(wholeWake: 25, operation: 1, persistenceReserve: 5))
        defer { session.invalidateInjectedSessionForTesting() }
        try prepare(session, fixture)
        session.parkedOpaquePublicationBackstop = wake == "backstop" ? 0.2 : 3_600
        if wake != "lease_release" {
            // No wake from the release: another reservation of the path ended without one.
            store.setPathLeaseReleaseHandler { _ in }
        }
        await activate(session)
        let finalizers = FinalizerRequests()
        session.onFinalizerRequest = { finalizers.append($0) }
        defer { finalizers.all.forEach { session.abandonFinalizerRequest($0) } }
        let capture = try #require(store.forwardOnlyCapturedBodyURL(for: key))
        try body.write(to: capture)
        let working = try #require(store.attemptWorkingFileURL(for: key))
        guard case .acquired(let lease) = store.tryAcquirePathLease(
            for: key, relativePaths: [working.lastPathComponent], purpose: .reconcile) else {
            Issue.record("The fixture could not lease the working path"); return
        }
        var leased = true
        defer { if leased { store.releasePathLease(lease) } }
        let parked = P6Acknowledgement<Bool>()
        session.opaquePublicationDidParkForTesting = { parked.signal(true) }

        #expect(session.finalizeCompletedStaticRangeFile(
            ratingKey: key.ratingKey, validationLabel: "forward_only_recovered"))
        try #require(await parked.wait(seconds: 10) == true, "the lease wait ran out")
        if wake != "backstop" {
            #expect(session.opaquePublicationOwnerForTesting(key) == .parkedRetry,
                    "the claim belongs to a retry, not to nobody")
        }
        #expect(FileManager.default.fileExists(atPath: capture.path))
        #expect(finalizers.count == 0)

        leased = false
        store.releasePathLease(lease)
        if wake == "recovery_pass" {
            #expect(session.finalizeCompletedStaticRangeFile(
                ratingKey: key.ratingKey, validationLabel: "forward_only_recovered"))
        }

        try #require(await wait { finalizers.count == 1 }, "the parked publication ran")
        await session.drainRangeIOForTesting()
        #expect((try? Data(contentsOf: working)) == body)
        #expect(!FileManager.default.fileExists(atPath: capture.path))
        #expect(store.lifecycleState(for: key)?.lifecycle == .finalizing)
        #expect(session.opaquePublicationOwnerForTesting(key) == nil)
        #expect(session.claimedRangeBodiesForTesting().isEmpty)
    }

    // MARK: 4. A row that changes during the foreground task listing

    /// Foreground reconcile chooses its rows, then lists the tasks, then decides. A paused
    /// forward-only row with no retry request is in the snapshot. While the listing runs the
    /// user taps Resume: the retry is granted and the row is `admitted` before its task
    /// exists. Reconcile used to read that newer row and requeue it (`planned`,
    /// `seasonPlanned`) under its supervised start.
    @Test("Foreground reconcile leaves a row that changed after its snapshot")
    func foregroundReconcileSkipsARowResumedDuringTheListing() throws {
        let fixture = try P6Fixture()
        let store = fixture.store()
        let resumed = try seedForwardOnly(fixture, store, "resumed", status: .paused)
        let untouched = try seedForwardOnly(fixture, store, "untouched", status: .downloading)
        let keys: Set<String> = [resumed.ratingKey, untouched.ratingKey]

        // recoverStaticRangeTransfersAfterForeground: the snapshot, before `getAllTasks`.
        let observed = store.reconcileRowObservations()
        #expect(Set(observed.keys) == keys)

        // The user's Resume lands while the listing runs.
        guard case .accepted = store.submitLifecycleEvent(.retry(.freshAttempt), for: resumed) else {
            Issue.record("Expected the retry to apply"); return
        }
        #expect(store.lifecycleState(for: resumed)?.lifecycle == .admitted)

        store.reconcileOnWorker(liveRatingKeys: [], snapshotRatingKeys: keys, observedRows: observed)

        #expect(store.lifecycleState(for: resumed)?.lifecycle == .admitted,
                "the supervised retry's row is not requeued")
        #expect(store.lifecycleState(for: resumed)?.history.admissionIntent == nil)
        // A row nobody touched is still judged: with no task, body or checkpoint it fails.
        #expect(store.record(for: untouched)?.status == .failed)

        // Startup reconcile carries no observations (admission is closed, no start runs) and
        // requeues the same admitted row, as Admission-A1 specifies.
        store.reconcileOnWorker(liveRatingKeys: [], snapshotRatingKeys: keys)
        #expect(store.lifecycleState(for: resumed)?.lifecycle == .planned)
        #expect(store.lifecycleState(for: resumed)?.history.admissionIntent == .seasonPlanned)
    }

    /// The generation, not the lifecycle, is compared: a row that leaves a state and returns
    /// to it during the listing was still changed by someone who knows more than the snapshot.
    @Test("Foreground reconcile leaves a row that changed and changed back")
    func foregroundReconcileSkipsARowThatReturnedToItsState() throws {
        let fixture = try P6Fixture()
        let store = fixture.store()
        let key = try seedForwardOnly(fixture, store, "aba", status: .paused)
        guard case .accepted = store.submitLifecycleEvent(.retry(.freshAttempt), for: key) else {
            Issue.record("Expected the retry to apply"); return
        }
        let observed = store.reconcileRowObservations()
        // Pause, then Resume again: `admitted` once more, by a newer supervised start.
        guard case .accepted = store.submitLifecycleEvent(.pause(.user), for: key),
              case .accepted = store.submitLifecycleEvent(.retry(.freshAttempt), for: key) else {
            Issue.record("Expected the pause and the retry to apply"); return
        }
        store.reconcileOnWorker(liveRatingKeys: [], snapshotRatingKeys: [key.ratingKey],
                                observedRows: observed)
        #expect(store.lifecycleState(for: key)?.lifecycle == .admitted)
    }

    // MARK: Fixture

    /// A forward-only row with its own attempt and file name, so one store can hold several.
    private func seedForwardOnly(_ fixture: P6Fixture, _ store: DownloadStore, _ name: String,
                                 status: DownloadStatus) throws -> DownloadAttemptKey {
        let record = fixture.record(name, status: status, mode: .liveForwardOnly,
                                    ratingKey: "jellyfin:\(name)", filename: "\(name).mp4")
        let key = DownloadAttemptKey(ratingKey: record.ratingKey,
                                     attemptID: try #require(record.attemptID))
        try #require(store.createAttemptOwnedRecord(record, attemptID: key.attemptID) == .committed(key))
        return key
    }

    private func prepare(_ session: BackgroundDownloadSession, _ fixture: P6Fixture) throws {
        let temps = fixture.directory.appendingPathComponent("NetworkTemps")
        try FileManager.default.createDirectory(at: temps, withIntermediateDirectories: true)
        session.rangeBodyDirectoryForTesting = temps
        session.availableStorageBytesForTesting = Int64.max
    }

    private func activate(_ session: BackgroundDownloadSession) async {
        _ = await withCheckedContinuation { continuation in
            session.activateCurrentStore { continuation.resume(returning: $0) }
        }
    }

    private func wait(isolation: isolated (any Actor)? = #isolation, _ predicate: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
}

private final class RecoveryResult: @unchecked Sendable {
    private let storage = Mutex<Bool?>(nil)
    func set(_ value: Bool?) { storage.withLock { $0 = value } }
    var value: Bool? { storage.withLock { $0 } }
}

private final class FinalizerRequests: @unchecked Sendable {
    private let requests = Mutex<[BackgroundDownloadSession.FinalizerRequest]>([])
    func append(_ request: BackgroundDownloadSession.FinalizerRequest) { requests.withLock { $0.append(request) } }
    var count: Int { requests.withLock { $0.count } }
    var all: [BackgroundDownloadSession.FinalizerRequest] { requests.withLock { $0 } }
}

/// Holds every request until the test finishes it.
private final class RecoveryRaceURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var configured: HeldRangeRequests?
    private var held: HeldRangeRequest?

    static func configure(_ requests: HeldRangeRequests?) { lock.withLock { configured = requests } }

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

/// A held request whose response body can arrive without the transfer finishing.
private final class PartialRequest: @unchecked Sendable {
    private weak var owner: URLProtocol?
    init(owner: URLProtocol) { self.owner = owner }

    func respond(status: Int, body: Data, headers: [String: String]) {
        guard let owner, let url = owner.request.url, let client = owner.client,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: headers) else { return }
        client.urlProtocol(owner, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(owner, didLoad: body)
    }

    func complete() {
        guard let owner else { return }
        owner.client?.urlProtocolDidFinishLoading(owner)
    }
}

private final class PartialRequests: @unchecked Sendable {
    private let started = Mutex<[PartialRequest]>([])
    func record(_ request: PartialRequest) { started.withLock { $0.append(request) } }
    func waitForFirst() async -> PartialRequest? {
        for _ in 0..<300 {
            if let first = started.withLock({ $0.first }) { return first }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return started.withLock { $0.first }
    }
}

private final class PartialBodyURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var configured: PartialRequests?
    private var held: PartialRequest?

    static func configure(_ requests: PartialRequests?) { lock.withLock { configured = requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let request = PartialRequest(owner: self)
        held = request
        Self.lock.withLock { Self.configured }?.record(request)
    }
    override func stopLoading() {}
}
#endif
