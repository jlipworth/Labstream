#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

@MainActor
struct SeasonPlannerIntegrationTests {
    enum Change: CaseIterable { case deleteCurrent, deleteCurrentError, deleteLater, pauseCurrent, unchanged }

    @Test(arguments: Change.allCases)
    func persistedSeasonAdmissionHonorsDeletionDuringRealMetadataRequest(change: Change) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("season-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = "\(UUID().uuidString.lowercased()).season.test.invalid"
        let gate = SeasonMetadataGate()
        SeasonMetadataProtocol.register(host: host, gate: gate)
        defer { SeasonMetadataProtocol.unregister(host: host) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SeasonMetadataProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }
        let identity = PlatformClientIdentity.make(clientIdentifier: "season-integration")
        let model = AppModel(identity: identity, token: "fixture-token",
                             client: PlexClient(session: transport, identity: identity))
        model.serverToken = "fixture-token"
        model.serverBaseURL = URL(string: "https://\(host)")
        let store = DownloadStore(baseDirectory: directory)
        let session = BackgroundDownloadSession(store: store, protocolClasses: [SeasonMetadataProtocol.self])
        let manager = DownloadManager(appModel: model, store: store, session: session,
                                      registerForBackgroundEvents: false)
        defer {
            manager.seasonPlannerAdmissionTask?.cancel()
            session.invalidateInjectedSessionForTesting()
        }
        try #require(await waitUntil { manager.startupRecoveryState == .ready })
        let ids = change == .deleteLater ? ["episode-1", "episode-2"] : ["episode-1"]
        let plans = try ids.map { id in
            SeasonEpisodeDownloadPlan(
                item: try JSONDecoder().decode(MediaItem.self, from: SeasonMetadataGate.itemData(id)),
                backend: .plex, choice: .existingVersion, mediaIndex: 0, partIndex: 0,
                audioStreamIndex: nil, mediaSourceIDOverride: nil, estimatedBytes: 100, shouldStart: true)
        }
        let result = await manager.commitSeasonPlan(.init(newPlans: plans, retryAttempts: []))
        #expect(result.succeeded)
        #expect(result.added == ids.count)
        // Every admitted row refreshes concurrently (#362): both static episodes fit the
        // two-row static lane, so both metadata requests are in flight at once.
        try #require(await waitUntil { gate.heldIDs.count == ids.count })
        let first = try #require(gate.heldID)
        let original = try #require(store.record(for: first)?.attemptID)
        let deleted: String?
        switch change {
        case .deleteCurrent, .deleteCurrentError: deleted = first
        case .deleteLater: deleted = try #require(ids.first { $0 != first })
        default: deleted = nil
        }
        if let deleted {
            manager.delete(ratingKey: deleted)
            try #require(await waitUntil {
                store.record(for: deleted) == nil && !store.isDeletionPending(ratingKey: deleted)
            })
            // Row removal precedes the artifact worker's terminal index commit. In-memory
            // absence is not a durability barrier; await the already-submitted revision
            // before asking a fresh store to prove deletion survived reopening.
            let deletionTicket = store.currentPersistenceTicket()
            let flush = await store.flushPersistence(through: deletionTicket, timeout: 10)
            guard case .committed(let revision) = flush else {
                Issue.record("Deletion snapshot did not commit: \(flush)")
                return
            }
            #expect(revision >= deletionTicket.revision)
            // A newly opened index must agree before the suspended response is released.
            #expect(DownloadStore(baseDirectory: directory).record(for: deleted) == nil)
        }
        if change == .pauseCurrent {
            let row = OfflineDownloadRowActionIdentity(ratingKey: first, attemptID: original)
            #expect(manager.pause(row))
            #expect(store.record(for: first)?.status == .paused)
        }
        gate.releaseMetadata(id: first, failing: change == .deleteCurrentError)
        if change == .deleteLater, let deleted {
            // The deleted row's refresh was already in flight; its late response must be revoked.
            gate.releaseMetadata(id: deleted, failing: false)
        }
        try #require(await waitUntil {
            manager.seasonPlannerAdmissionTask == nil && manager.seasonPlannerAdmittingKeys.isEmpty
        })
        if change == .unchanged || change == .deleteLater {
            try #require(await waitUntil { gate.transferPaths.count == 1 })
            #expect(store.record(for: first)?.attemptID != original)
            #expect(Set(gate.metadataIDs) == Set(ids))
            #expect(gate.transferPaths == ["/library/parts/\(first)/file.mp4"])
        } else {
            #expect(gate.transferPaths.isEmpty)
            #expect(manager.activeJobs.isEmpty)
            #expect(gate.metadataIDs == [first])
            if change == .pauseCurrent {
                #expect(store.record(for: first)?.attemptID == original)
                #expect(store.record(for: first)?.status == .paused)
            }
        }
        if let deleted {
            #expect(store.record(for: deleted) == nil)
            #expect(DownloadStore(baseDirectory: directory).record(for: deleted) == nil)
            #expect(!manager.activeJobs.contains(deleted))
        }
        #expect(gate.unexpectedPaths.isEmpty) // No backend negotiation or auxiliary fetch.
        for row in store.records { manager.delete(ratingKey: row.ratingKey) }
        try #require(await waitUntil { store.records.isEmpty })
    }

    /// #362: a long-running admitted start (an Emby Convert or Plex optimize chain does not return
    /// until the server job finishes) must not hold back other admitted rows, and in-flight starts
    /// must still count against lane caps across repeated admission passes.
    @Test func seasonAdmissionStartsRowsConcurrentlyWithinLaneCaps() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("season-concurrency-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = "\(UUID().uuidString.lowercased()).season.test.invalid"
        let gate = SeasonMetadataGate()
        SeasonMetadataProtocol.register(host: host, gate: gate)
        defer { SeasonMetadataProtocol.unregister(host: host) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SeasonMetadataProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }
        let identity = PlatformClientIdentity.make(clientIdentifier: "season-concurrency")
        let model = AppModel(identity: identity, token: "fixture-token",
                             client: PlexClient(session: transport, identity: identity))
        model.serverToken = "fixture-token"
        model.serverBaseURL = URL(string: "https://\(host)")
        let store = DownloadStore(baseDirectory: directory)
        let session = BackgroundDownloadSession(store: store, protocolClasses: [SeasonMetadataProtocol.self])
        let manager = DownloadManager(appModel: model, store: store, session: session,
                                      registerForBackgroundEvents: false)
        defer {
            manager.seasonPlannerAdmissionTask?.cancel()
            session.invalidateInjectedSessionForTesting()
        }
        try #require(await waitUntil { manager.startupRecoveryState == .ready })
        let ids = ["episode-1", "episode-2", "episode-3"]
        let plans = try ids.map { id in
            SeasonEpisodeDownloadPlan(
                item: try JSONDecoder().decode(MediaItem.self, from: SeasonMetadataGate.itemData(id)),
                backend: .plex, choice: .existingVersion, mediaIndex: 0, partIndex: 0,
                audioStreamIndex: nil, mediaSourceIDOverride: nil, estimatedBytes: 100, shouldStart: true)
        }
        let result = await manager.commitSeasonPlan(.init(newPlans: plans, retryAttempts: []))
        #expect(result.succeeded)
        #expect(result.added == ids.count)

        // The static lane admits two rows at once; their starts run concurrently.
        try #require(await waitUntil { gate.heldIDs.count == 2 })
        let held = gate.heldIDs
        let stuck = held[0]
        let moving = held[1]
        // Outlast at least one more 2-second admission pass: in-flight starts occupy the lane, so
        // the third row is not admitted while both starts are still running.
        try await Task.sleep(for: .milliseconds(2_500))
        #expect(gate.metadataIDs.count == 2)

        // A start that never returns (standing in for a server-prep chain) does not block the
        // other admitted row from reaching its transfer.
        gate.releaseMetadata(id: moving, failing: false)
        try #require(await waitUntil { gate.transferPaths == ["/library/parts/\(moving)/file.mp4"] })
        #expect(gate.heldIDs == [stuck])
        #expect(manager.seasonPlannerAdmittingKeys == [stuck])
        // Both static slots remain occupied (one transferring, one still starting).
        #expect(gate.metadataIDs.count == 2)

        gate.releaseMetadata(id: stuck, failing: false)
        try #require(await waitUntil { gate.transferPaths.count == 2 })
        try #require(await waitUntil { manager.seasonPlannerAdmittingKeys.isEmpty })
        #expect(gate.unexpectedPaths.isEmpty)
        for row in store.records { manager.delete(ratingKey: row.ratingKey) }
        try #require(await waitUntil { store.records.isEmpty })
        // Release any metadata request admitted during teardown so no URLProtocol stays pending.
        while gate.heldID != nil { gate.releaseMetadata(failing: true) }
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

/// Holds actual Plex metadata responses at URLSession's transport boundary, one per episode, so
/// concurrent admissions can be observed and released independently. Transfer requests are
/// observed but kept pending, so tests never need network or media decoding.
private final class SeasonMetadataGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [(id: String, request: SeasonMetadataProtocol)] = []
    private var metadata: [String] = []
    private var transfers: [String] = []
    private var unexpected: [String] = []
    /// The first still-held metadata request, in arrival order.
    var heldID: String? { lock.withLock { held.first?.id } }
    var heldIDs: [String] { lock.withLock { held.map(\.id) } }
    var metadataIDs: [String] { lock.withLock { metadata } }
    var transferPaths: [String] { lock.withLock { transfers } }
    var unexpectedPaths: [String] { lock.withLock { unexpected } }

    func receive(_ request: SeasonMetadataProtocol) {
        let path = request.request.url!.path
        lock.withLock {
            if path.hasPrefix("/library/metadata/") {
                let id = request.request.url!.lastPathComponent
                metadata.append(id)
                held.append((id, request))
            } else if path.hasPrefix("/library/parts/") {
                transfers.append(path)
            } else {
                unexpected.append(path)
            }
        }
    }
    /// Release one held metadata request (the oldest when `id` is nil).
    func releaseMetadata(id: String? = nil, failing: Bool) {
        let request: SeasonMetadataProtocol? = lock.withLock {
            let index: Int?
            if let id {
                index = held.firstIndex { $0.id == id }
            } else {
                index = held.isEmpty ? nil : 0
            }
            guard let index else { return nil }
            return held.remove(at: index).request
        }
        guard let request, let url = request.request.url else { return }
        if failing {
            request.client?.urlProtocol(request, didFailWithError: URLError(.cannotParseResponse))
            return
        }
        let item = Self.itemData(url.lastPathComponent)
        let data = Data("{\"MediaContainer\":{\"Metadata\":[".utf8) + item + Data("]}}".utf8)
        request.client?.urlProtocol(request, didReceive: HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        request.client?.urlProtocol(request, didLoad: data)
        request.client?.urlProtocolDidFinishLoading(request)
    }
    static func itemData(_ id: String) -> Data {
        Data("""
        {"ratingKey":"\(id)","key":"/library/metadata/\(id)","title":"Episode fixture","type":"episode",
         "Media":[{"id":1,"container":"mp4","Part":[{"id":11,"key":"/library/parts/\(id)/file.mp4","container":"mp4","size":100}]}]}
        """.utf8)
    }
}

private final class SeasonMetadataProtocol: URLProtocol, @unchecked Sendable {
    private static let gates = TestLockedBox<[String: SeasonMetadataGate]>([:])
    static func register(host: String, gate: SeasonMetadataGate) { gates.withValue { $0[host] = gate } }
    static func unregister(host: String) { gates.withValue { $0.removeValue(forKey: host) } }
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".season.test.invalid") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let host = request.url?.host, let gate = Self.gates.value[host] else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        gate.receive(self)
    }
    override func stopLoading() {}
}
#endif
