#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

@Suite(.serialized)
@MainActor
struct ServerPrepRunnerIntegrationTests {
    // Pins 18, 20: use the real Plex executor, including a duplicate's second metadata read.
    @Test(arguments: [false, true])
    func plexAdoptsWithoutCreatingAnotherRender(duplicate: Bool) async throws {
        let fixture = try await PrepRunnerFixture()
        defer { fixture.close() }
        fixture.wire.withValue { $0.plexOutput = !duplicate; $0.createStatus = 400 }
        let key = try await fixture.seed(.plex)
        fixture.startPlex(key)
        try #require(await fixture.wait { fixture.store.metadata(for: key.ratingKey)?.serverPreparedVersion == true })
        #expect(fixture.wire.value.creates == (duplicate ? 1 : 0))
        #expect(fixture.store.metadata(for: key.ratingKey)?.sourcePartID == 2)
        #expect(fixture.store.metadata(for: key.ratingKey)?.sourcePartSize == 64)
        if duplicate { #expect(fixture.wire.value.dispatchWasDurable) }
    }

    // Pin 19 and amendment 11: unavailable must not become absence, even past the grace.
    @Test(arguments: [false, true])
    func plexUnavailableQueueKeepsInspecting(expired: Bool) async throws {
        let fixture = try await PrepRunnerFixture()
        defer { fixture.close() }
        fixture.wire.withValue { $0.queueStatus = 503 }
        let key = try await fixture.seed(.plex, active: false, dispatchedAt: expired ? Date().timeIntervalSince1970 - 181 : nil)
        fixture.manager.resumePendingServerPrepDownloads()
        try #require(await fixture.wait { fixture.wire.value.queueReads >= 3 })
        #expect(fixture.wire.value.creates == 0)
        #expect(fixture.store.record(for: key)?.status == .queued)
    }

    @Test(arguments: [false, true])
    func plexUnavailableMetadataCannotCreateOrFailGrace(expired: Bool) async throws {
        let fixture = try await PrepRunnerFixture()
        defer { fixture.close() }
        fixture.wire.withValue { $0.metadataStatus = 503 }
        let key = try await fixture.seed(.plex, active: false,
                                   dispatchedAt: expired ? Date().timeIntervalSince1970 - 181 : nil)
        fixture.manager.resumePendingServerPrepDownloads()
        try #require(await fixture.wait { fixture.wire.value.queueReads >= 3 })
        #expect(fixture.wire.value.creates == 0)
        #expect(fixture.store.record(for: key)?.status == .queued)
    }

    @Test func plexRelaunchInsideCreateGraceDoesNotPostOrResetClock() async throws {
        let fixture = try await PrepRunnerFixture()
        defer { fixture.close() }
        let dispatched = Date().timeIntervalSince1970 - 60
        let key = try await fixture.seed(.plex, active: false, dispatchedAt: dispatched)
        fixture.manager.resumePendingServerPrepDownloads()
        try #require(await fixture.wait { fixture.wire.value.queueReads >= 3 })
        #expect(fixture.wire.value.creates == 0)
        #expect(fixture.store.metadata(for: key.ratingKey)?.plexOptimizeCreateDispatchedAtEpochSeconds == dispatched)
        let reopened = DownloadStore(baseDirectory: fixture.directory)
        #expect(reopened.metadata(for: key.ratingKey)?.plexOptimizeCreateDispatchedAtEpochSeconds == dispatched)
    }

    @Test func plexProvenMissingCreateFailsAfterGrace() async throws {
        let fixture = try await PrepRunnerFixture()
        defer { fixture.close() }
        let key = try await fixture.seed(.plex, active: false, dispatchedAt: Date().timeIntervalSince1970 - 181)
        fixture.manager.resumePendingServerPrepDownloads()
        try #require(await fixture.wait { fixture.store.record(for: key)?.status == .failed })
        #expect(fixture.wire.value.creates == 0)
        #expect(fixture.store.lifecycleState(for: key)?.history.lastFailure == .server)
    }

    @Test func plexCreateFailureIsImmediateAndDispatchPrecedesRequest() async throws {
        let fixture = try await PrepRunnerFixture()
        defer { fixture.close() }
        fixture.wire.withValue { $0.createStatus = 500 }
        let key = try await fixture.seed(.plex)
        fixture.startPlex(key)
        try #require(await fixture.wait { fixture.store.record(for: key)?.status == .failed })
        #expect(fixture.wire.value.creates == 1)
        #expect(fixture.wire.value.dispatchWasDurable)
        #expect(fixture.store.lifecycleState(for: key)?.history.lastFailure == .server)
    }

    // Pin 21: refresh the lane while a real poller is attached, then expose its rendered Part.
    @Test func plexHandoffUsesObservedLiveLane() async throws {
        let fixture = try await PrepRunnerFixture()
        defer { fixture.close() }
        fixture.wire.withValue { $0.queuePresent = true }
        let key = try await fixture.seed(.plex)
        fixture.startPlex(key)
        try #require(await fixture.wait { fixture.wire.value.queueReads >= 1 })
        fixture.model.serverToken = "renewed-fixture"
        fixture.wire.withValue { $0.plexOutput = true }
        try #require(await fixture.wait { !fixture.transfers.value.isEmpty })
        let request = try #require(fixture.transfers.value.first)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first { $0.name == "X-Plex-Token" }?.value == "renewed-fixture")
        #expect(request.url?.path == "/library/parts/2/file.mp4")
    }

    // Pin 22: render stays pending; start must return while its registered task is still alive.
    @Test(arguments: [DownloadBackendKind.plex, .emby])
    func freshStartReturnsBeforeRendering(backend: DownloadBackendKind) async throws {
        let fixture = try await PrepRunnerFixture()
        defer { fixture.close() }
        fixture.wire.withValue { $0.queuePresent = true }
        let key = try await fixture.seed(backend)
        let returned = TestLockedBox(false)
        let start = Task {
            if backend == .plex {
                await fixture.manager.triggerOptimizeAndDownload(item: fixture.item, targetName: fixture.target,
                    metadata: fixture.store.metadata(for: key.ratingKey)!, session: fixture.plexLane, attemptKey: key)
            } else {
                await fixture.manager.triggerConvertAndDownload(item: fixture.item, targetName: fixture.target,
                    metadata: fixture.store.metadata(for: key.ratingKey)!, session: fixture.embyLane, attemptKey: key)
            }
            returned.withValue { $0 = true }
            fixture.events.signal()
        }
        defer { start.cancel() }
        #expect(await fixture.wait { returned.value })
        #expect(fixture.manager.activeJobs.contains(key.ratingKey))
    }

    // #414: a finished render past the 24-hour render deadline (it waited for a transfer slot,
    // then the app relaunched) is adopted, not failed as timed out.
    @Test func plexRelaunchAdoptsAFinishedRenderPastTheDeadline() async throws {
        let fixture = try await PrepRunnerFixture()
        defer { fixture.close() }
        fixture.wire.withValue { $0.plexOutput = true }
        let key = try await fixture.seed(.plex, active: false,
                                         startedAt: Date().timeIntervalSince1970 - 48 * 3_600)
        fixture.manager.resumePendingServerPrepDownloads()
        try #require(await fixture.wait { !fixture.transfers.value.isEmpty })
        #expect(fixture.store.record(for: key)?.status != .failed)
        #expect(fixture.store.metadata(for: key.ratingKey)?.serverPreparedVersion == true)
    }

    // #414: with every static slot busy, a finished render keeps its prep slot and reads ready;
    // its transfer starts only once a slot frees, and a delete during the wait starts nothing.
    @Test(arguments: [DownloadBackendKind.plex, .emby], [false, true])
    func finishedRenderWaitsForATransferSlot(backend: DownloadBackendKind, deleteWhileWaiting: Bool) async throws {
        let fixture = try await PrepRunnerFixture()
        defer { fixture.close() }
        let staticCap = try #require(fixture.manager.admission.limits.maximumByLane[.staticFile])
        let generations = (0..<staticCap).map {
            ("static-\($0)", fixture.manager.admission.beginSupervision("static-\($0)", lane: .staticFile, origin: .user))
        }
        fixture.wire.withValue { $0.plexOutput = true; $0.completeConversion = true }
        let key = try await fixture.seed(backend)
        backend == .plex ? fixture.startPlex(key) : fixture.startEmby(key)
        try #require(await fixture.wait { fixture.manager.staticHandoffWaiters[key.ratingKey] != nil })
        #expect(fixture.manager.optimizeState[key.ratingKey] == DownloadRowStatusCaptionPolicy.serverPrepReadyState)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(fixture.transfers.value.isEmpty)
        if deleteWhileWaiting {
            let poller = try #require(fixture.manager.serverPrepPollerTaskForTesting(for: key))
            fixture.manager.delete(ratingKey: key.ratingKey)
            try #require(await fixture.wait { fixture.store.record(for: key) == nil })
            for (id, generation) in generations { _ = fixture.manager.admission.endSupervision(id, generation: generation) }
            await poller.value // Join the cancelled producer before asserting no late transfer.
            #expect(fixture.manager.staticHandoffWaiters.isEmpty)
            #expect(fixture.transfers.value.isEmpty)
        } else {
            _ = fixture.manager.admission.endSupervision(generations[0].0, generation: generations[0].1)
            try #require(await fixture.wait { !fixture.transfers.value.isEmpty })
            #expect(fixture.manager.staticHandoffWaiters.isEmpty)
            try #require(await fixture.wait { fixture.manager.staticHandoffReservations.isEmpty })
            #expect(fixture.store.metadata(for: key.ratingKey)?.resolvedResumeMode(ratingKey: key.ratingKey) == .staticByteRange)
        }
        #expect(fixture.manager.optimizeState[key.ratingKey] != DownloadRowStatusCaptionPolicy.serverPrepReadyState)
    }

    enum Handoff: CaseIterable { case freshReuse, refreshedReuse, resumeReuse, completed }

    // Pin 23: each branch reaches an actual static background request from its registered task.
    @Test(arguments: Handoff.allCases)
    func embyHandoffsDoNotCancelThemselves(branch: Handoff) async throws {
        let fixture = try await PrepRunnerFixture()
        defer { fixture.close() }
        fixture.wire.withValue {
            $0.embyReuseAfterRead = branch == .freshReuse || branch == .resumeReuse ? 1
                : (branch == .refreshedReuse ? 2 : Int.max)
            $0.completeConversion = branch == .completed
        }
        let key = try await fixture.seed(.emby, active: branch != .resumeReuse, jobID: branch == .resumeReuse ? 7 : nil)
        if branch == .resumeReuse {
            fixture.manager.resumePendingServerPrepDownloads()
        } else {
            fixture.startEmby(key)
        }
        try #require(await fixture.wait { !fixture.transfers.value.isEmpty })
        #expect(fixture.store.metadata(for: key.ratingKey)?.mediaSourceID == "converted")
        #expect(fixture.store.metadata(for: key.ratingKey)?.resolvedResumeMode(ratingKey: key.ratingKey) == .staticByteRange)
        #expect(fixture.wire.value.negotiations == 1)
    }

    // Pins 24/25: cancellation fences the static handoff; global queue pause parks Convert too.
    @Test(arguments: [false, true])
    func embyDeleteAndPauseAllDuringFreshPolling(pauseAll: Bool) async throws {
        let fixture = try await PrepRunnerFixture()
        defer { fixture.close() }
        let key = try await fixture.seed(.emby)
        fixture.startEmby(key)
        try #require(await fixture.wait { fixture.wire.value.jobReads >= 1 })
        if pauseAll {
            // Exercise the production pause, including persistence, then restore the shared
            // preference in this MainActor turn. Other managers must not inherit this gate.
            let defaults = UserDefaults.standard
            let prior = defaults.object(forKey: "downloads.queuePaused")
            fixture.manager.pauseQueue()
            #expect(defaults.bool(forKey: "downloads.queuePaused"))
            if let prior { defaults.set(prior, forKey: "downloads.queuePaused") }
            else { defaults.removeObject(forKey: "downloads.queuePaused") }
            #expect(fixture.manager.isQueuePaused)
            #expect(fixture.store.record(for: key.ratingKey)?.status == .paused)
            #expect(fixture.manager.serverPrepPollerTaskForTesting(for: key) == nil)
            #expect(fixture.transfers.value.isEmpty)
        } else {
            let poller = try #require(fixture.manager.serverPrepPollerTaskForTesting(for: key))
            fixture.manager.delete(ratingKey: key.ratingKey)
            #expect(poller.isCancelled)
            try #require(await fixture.wait { fixture.store.record(for: key) == nil })
            let reads = fixture.wire.value.jobReads
            fixture.wire.withValue { $0.completeConversion = true }
            await poller.value // Join the cancelled producer before asserting no late request.
            #expect(fixture.wire.value.jobReads == reads)
            #expect(fixture.wire.value.negotiations == 0)
        }
        #expect(fixture.transfers.value.isEmpty)
    }
}

@MainActor
private final class PrepRunnerFixture {
    struct Wire {
        var plexOutput = false
        var metadataStatus = 200
        var queuePresent = false
        var queueStatus = 200
        var createStatus = 200
        var creates = 0
        var queueReads = 0
        var dispatchWasDurable = false
        var embyReads = 0
        var embyReuseAfterRead = Int.max
        var completeConversion = false
        var jobReads = 0
        var negotiations = 0
    }
    let directory: URL
    let events = TestEvents()
    let wire: TestLockedBox<Wire>
    let transfers: TestLockedBox<[URLRequest]>
    let stub: TestURLProtocolStub
    let transport: URLSession
    let model: AppModel
    let store: DownloadStore
    let background: BackgroundDownloadSession
    let manager: DownloadManager
    let item: MediaItem
    var entryTasks: [Task<Void, Never>] = []
    let target = "1080p 8 Mbps"
    let plexLane: BackendSession
    let embyLane: BackendSession

    init() async throws {
        let events = self.events
        wire = TestLockedBox(Wire(), didChange: { events.signal() })
        transfers = TestLockedBox([], didChange: { events.signal() })
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("prep-runner-\(UUID().uuidString)")
        let base = URL(string: "https://\(UUID().uuidString.lowercased()).prep.test.invalid")!
        plexLane = BackendSession(kind: .plex, baseURL: base, token: "initial-fixture", serverID: nil)
        embyLane = BackendSession(kind: .emby, baseURL: base, token: "fixture", userID: "fixture-user", serverID: "fixture-server")
        let wire = self.wire
        let directory = self.directory
        stub = TestURLProtocolStub { request in
            let path = request.url!.path
            let method = request.httpMethod ?? "GET"
            var status = 200
            var body = "{}"
            wire.withValue { state in
                if path == "/library/metadata/item" {
                    status = state.metadataStatus
                    body = Self.plexMetadata(output: state.plexOutput)
                } else if path == "/playlists" {
                    body = #"{"MediaContainer":{"Metadata":[{"key":"/playlists/9/items","playlistType":"42"}]}}"#
                } else if path == "/playlists/9/items", method == "PUT" || method == "POST" {
                    state.creates += 1
                    state.dispatchWasDurable = DownloadStore(baseDirectory: directory)
                        .metadata(for: "item")?.plexOptimizeCreateDispatchedAtEpochSeconds != nil
                    status = state.createStatus
                    if status == 400 { state.plexOutput = true }
                } else if path == "/playlists/9/items" {
                    state.queueReads += 1
                    status = state.queueStatus
                    body = state.queuePresent
                        ? #"{"MediaContainer":{"Item":[{"title":"fixture-queue","Status":{"state":"waiting"}}]}}"#
                        : #"{"MediaContainer":{"Item":[]}}"#
                } else if path.hasSuffix("/PlaybackInfo") {
                    let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                    let payload = Self.requestBody(request)
                    let selected = (payload?["MediaSourceId"] as? String)
                        ?? query?.first { $0.name.lowercased() == "mediasourceid" }?.value
                    if selected == "converted" { state.negotiations += 1 }
                    state.embyReads += 1
                    body = Self.embyPlayback(output: selected == "converted" || state.embyReads >= state.embyReuseAfterRead
                        || (state.completeConversion && state.jobReads > 0))
                } else if path.hasSuffix("/Sync/Jobs"), method == "POST" {
                    body = #"{"Job":{"Id":7,"Status":"Queued"}}"#
                } else if path.hasSuffix("/Sync/Jobs") {
                    body = #"{"Items":[],"TotalRecordCount":0}"#
                } else if path.hasSuffix("/Sync/Jobs/7") {
                    if method == "GET" { state.jobReads += 1 }
                    body = state.completeConversion ? #"{"Id":7,"Status":"Completed"}"# : #"{"Id":7,"Status":"Converting"}"#
                } else if path == "/library/sections" {
                    body = #"{"MediaContainer":{"Directory":[{"key":"1","uuid":"fixture-section","title":"Fixture","type":"movie","Location":[]}]}}"#
                } else {
                    body = #"{"MediaContainer":{}}"#
                }
            }
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!, Data(body.utf8))
        }
        transport = URLSession(configuration: stub.configuration)
        let identity = PlatformClientIdentity.make(clientIdentifier: "prep-runner-fixture")
        model = AppModel(identity: identity, token: "fixture", client: PlexClient(session: transport, identity: identity))
        model.serverBaseURL = base
        model.serverToken = plexLane.token
        model.embyServerBaseURL = base
        model.embyAccessToken = embyLane.token
        model.embyUserID = embyLane.userID
        model.embyServerID = embyLane.serverID
        store = DownloadStore(baseDirectory: directory, indexPersistence: .init { data, url in
            try DownloadIndexFileCommitter().commit(data, to: url)
            events.signal()
        })
        let transfers = self.transfers
        PrepRunnerStaticProtocol.routes.withValue { $0[base.host!] = transfers }
        background = BackgroundDownloadSession(store: store, protocolClasses: [PrepRunnerStaticProtocol.self])
        manager = DownloadManager(appModel: model, store: store, session: background, registerForBackgroundEvents: false)
        manager.setQueuePausedForTesting(false)
        manager.optimizePollInterval = 0.01
        manager.embyConvertPollInterval = 0.01
        manager.embyConvertSession = transport
        item = try JSONDecoder().decode(MediaItem.self, from: Data(Self.plexItem(output: false).utf8))
        try #require(await manager.awaitStartupRecoveryForTesting())
        // Cleanup execution has its own integration suite; keep these prep pins off the network.
        await manager.cleanupRunner?.waitUntilIdle()
        manager.cleanupRunner = nil
    }

    func seed(_ backend: DownloadBackendKind, active: Bool = true,
              dispatchedAt: Double? = nil, jobID: Int? = nil,
              startedAt: Double? = nil) async throws -> DownloadAttemptKey {
        let lane = backend == .plex ? plexLane : embyLane
        let key = DownloadAttemptKey(ratingKey: backend == .plex ? "item" : "emby:item", attemptID: .init(uuid: UUID()))
        var metadata = DownloadOfflineMetadataBuilder.metadata(from: item, resolutionLabel: "1080p",
            mediaIndex: 0, partIndex: 0, optimizeTargetName: target,
            optimizeQueueTitle: backend == .plex ? "fixture-queue" : nil, session: lane,
            mediaSourceID: backend == .emby ? "source" : nil, downloadLane: .optimize)
        metadata.resumeMode = .serverPrepThenStatic
        metadata.optimizeBaselinePartIDs = [1]
        metadata.plexOptimizeCreateDispatchedAtEpochSeconds = dispatchedAt
        if let startedAt { metadata.plexOptimizeStartedAtEpochSeconds = startedAt }
        metadata.embyConvertJobID = jobID
        metadata.embyConvertSnapshotIDs = ["source"]
        let row = DownloadRecord(ratingKey: key.ratingKey, attemptID: key.attemptID, title: "Fixture",
            localURL: store.destinationURL(ratingKey: key.ratingKey, ext: "mp4"), bytes: 0,
            status: backend == .plex ? .queued : .preparing, metadata: metadata)
        try #require(await store.createAttemptOwnedRecordAsync(row, attemptID: key.attemptID) == .committed(key))
        if active { manager.activeJobs.insert(key.ratingKey); manager.inFlightAttempts.acquire(key) }
        return key
    }

    func startPlex(_ key: DownloadAttemptKey) {
        entryTasks.append(Task {
            await manager.triggerOptimizeAndDownload(item: item, targetName: target,
                metadata: store.metadata(for: key.ratingKey)!, session: plexLane, attemptKey: key)
        })
    }

    func startEmby(_ key: DownloadAttemptKey) {
        entryTasks.append(Task {
            await manager.triggerConvertAndDownload(item: item, targetName: target,
                metadata: store.metadata(for: key.ratingKey)!, session: embyLane, attemptKey: key)
        })
    }

    func wait(_ condition: () -> Bool) async -> Bool {
        await events.wait {
            _ = manager.records // Manager publication also acknowledges post-commit continuations.
            return condition()
        }
    }

    func close() {
        let pollers = store.records.compactMap { row -> Task<Void, Never>? in
            guard let id = row.attemptID else { return nil }
            return manager.serverPrepPollerTaskForTesting(for: .init(ratingKey: row.ratingKey, attemptID: id))
        }
        model.serverToken = nil
        model.embyAccessToken = nil
        entryTasks.forEach { $0.cancel() }
        manager.setQueuePausedForTesting(false)
        for row in store.records {
            if let id = row.attemptID { manager.releaseInFlight(for: .init(ratingKey: row.ratingKey, attemptID: id)) }
        }
        Task {
            // Do not invalidate the transport while a cancelled poller's tail still owns an await.
            for task in pollers + entryTasks { await task.value }
            background.invalidateInjectedSessionForTesting()
            transport.invalidateAndCancel()
            PrepRunnerStaticProtocol.routes.withValue { $0.removeValue(forKey: plexLane.baseURL.host!) }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    nonisolated static func requestBody(_ request: URLRequest) -> [String: Any]? {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    nonisolated static func plexItem(output: Bool) -> String {
        let rendered = output ? #",{"id":2,"width":1920,"height":1080,"container":"mp4","videoCodec":"h264","audioCodec":"aac","Part":[{"id":2,"key":"/library/parts/2/file.mp4","file":"/fixture/Plex Versions/output.mp4","container":"mp4","size":64}]}"# : ""
        return #"{"ratingKey":"item","title":"Fixture","type":"movie","librarySectionID":1,"Media":[{"id":1,"width":1920,"height":1080,"container":"mkv","Part":[{"id":1,"key":"/library/parts/1/file.mkv","container":"mkv","size":128}]}"# + rendered + "]}"
    }
    nonisolated static func plexMetadata(output: Bool) -> String {
        #"{"MediaContainer":{"Metadata":["# + plexItem(output: output) + "]}}"
    }
    nonisolated static func embyPlayback(output: Bool) -> String {
        let converted = output ? #",{"Id":"converted","Protocol":"File","Container":"mp4","VideoCodec":"h264","Width":1920,"Height":1080,"Size":64,"SupportsDirectPlay":true,"SupportsDirectStream":true,"MediaStreams":[]}"# : ""
        return #"{"PlaySessionId":"fixture-session","MediaSources":[{"Id":"source","Protocol":"File","Container":"mkv","Width":1920,"Height":1080,"MediaStreams":[]}"# + converted + "]}"
    }
}

private final class PrepRunnerStaticProtocol: URLProtocol, @unchecked Sendable {
    static let routes = TestLockedBox<[String: TestLockedBox<[URLRequest] >]>([:])
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host.map { routes.value[$0] != nil } ?? false }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let host = request.url?.host { Self.routes.value[host]?.withValue { $0.append(request) } }
        // Hold the static body so completion and media validation are outside these runner pins.
    }
    override func stopLoading() {}
}
#endif
