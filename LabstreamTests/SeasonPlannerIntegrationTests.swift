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
        try #require(await waitUntil { gate.heldID != nil })
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
            // A newly opened index must agree before the suspended response is released.
            #expect(DownloadStore(baseDirectory: directory).record(for: deleted) == nil)
        }
        if change == .pauseCurrent {
            let row = OfflineDownloadRowActionIdentity(ratingKey: first, attemptID: original)
            #expect(manager.pause(row))
            #expect(store.record(for: first)?.status == .paused)
        }
        gate.releaseMetadata(failing: change == .deleteCurrentError)
        try #require(await waitUntil { manager.seasonPlannerAdmissionTask == nil })
        if change == .unchanged || change == .deleteLater {
            try #require(await waitUntil { gate.transferPaths.count == 1 })
            #expect(store.record(for: first)?.attemptID != original)
            #expect(gate.metadataIDs == [first])
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

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

/// Holds an actual Plex metadata response at URLSession's transport boundary. Transfer
/// requests are observed but kept pending, so tests never need network or media decoding.
private final class SeasonMetadataGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held: SeasonMetadataProtocol?
    private var metadata: [String] = []
    private var transfers: [String] = []
    private var unexpected: [String] = []
    var heldID: String? { lock.withLock { held?.request.url?.lastPathComponent } }
    var metadataIDs: [String] { lock.withLock { metadata } }
    var transferPaths: [String] { lock.withLock { transfers } }
    var unexpectedPaths: [String] { lock.withLock { unexpected } }

    func receive(_ request: SeasonMetadataProtocol) {
        let path = request.request.url!.path
        lock.withLock {
            if path.hasPrefix("/library/metadata/") {
                metadata.append(request.request.url!.lastPathComponent)
                held = request
            } else if path.hasPrefix("/library/parts/") {
                transfers.append(path)
            } else {
                unexpected.append(path)
            }
        }
    }
    func releaseMetadata(failing: Bool) {
        let request = lock.withLock { let value = held; held = nil; return value }
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
