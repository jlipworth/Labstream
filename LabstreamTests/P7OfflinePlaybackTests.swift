#if !os(tvOS)
import AVFoundation
import Foundation
import PMSKit
import Synchronization
import Testing
@testable import Labstream

/// Credential-free local files and the real manager/store/controller path. No player is started.
@MainActor
final class P7PlaybackFixture {
    let files: P6Fixture
    let store: DownloadStore
    let session: BackgroundDownloadSession
    let manager: DownloadManager
    let record: DownloadRecord
    let requests = TestLockedBox(0)
    let networkStub: TestURLProtocolStub
    let transport: URLSession
    var key: DownloadAttemptKey { .init(ratingKey: record.ratingKey, attemptID: record.attemptID!) }

    init(status: DownloadStatus = .unverified, position: Int = 30_000,
         index: DownloadStore.IndexPersistence = .live,
         cleanupPersistence: DownloadCleanupIntentJournal.Persistence = .live,
         fileManager: FileManager = .default) async throws {
        files = try P6Fixture()
        let fixtureFiles = files
        let row = try await Task.detached {
            let seed = fixtureFiles.store()
            var row = fixtureFiles.record(status: status)
            row.metadata?.duration = 600_000
            row.metadata?.localPlaybackPositionMs = position
            try Data([1, 2, 3]).write(to: row.localURL)
            try #require(seed.createAttemptOwnedRecord(row, attemptID: row.attemptID!) == .committed(
                .init(ratingKey: row.ratingKey, attemptID: row.attemptID!)))
            return row
        }.value
        record = row
        store = DownloadStore(baseDirectory: files.directory, fileManager: fileManager, indexPersistence: index)
        session = BackgroundDownloadSession(store: store, protocolClasses: [])
        let requests = self.requests
        networkStub = TestURLProtocolStub { _ in
            requests.withValue { $0 += 1 }
            throw URLError(.notConnectedToInternet)
        }
        transport = URLSession(configuration: networkStub.configuration)
        let identity = PlatformClientIdentity.make(clientIdentifier: "p7-fixture")
        manager = DownloadManager(appModel: AppModel(identity: identity,
            client: PlexClient(session: transport, identity: identity)), store: store, session: session,
            cleanupIntentJournal: DownloadCleanupIntentJournal(directory: store.durableCleanupAuthorityDirectory,
                persistence: cleanupPersistence), sideAssetFetchCoordinator: SideAssetFetchCoordinator(),
            registerForBackgroundEvents: false)
        manager.embyConvertSession = transport
        try #require(await manager.awaitStartupRecoveryForTesting())
    }

    func libraryLaunch(rewind: Int = 0, orientation: () async -> Void = {}) async throws -> OfflinePlaybackLaunch {
        try await OfflineLibraryPlaybackPresentation(factory: OfflineLibraryView.defaultLaunchFactory(manager))
            .launch(for: identity, resumeRewindSeconds: rewind, orientation: orientation).get()
    }

    func libraryController() async throws -> PlaybackController {
        OfflineLibraryView.makeOfflinePlayer(launch: try await libraryLaunch(),
                                             onClose: {}).makeControllerForP7Testing()
    }

    var identity: OfflineDownloadRowActionIdentity {
        .init(ratingKey: record.ratingKey, attemptID: record.attemptID)
    }

    func launch(_ row: DownloadRecord? = nil, rewind: Int = 0) async throws -> OfflinePlaybackLaunch {
        let row = row ?? record
        let factory = manager.offlinePlaybackLaunchFactory
        return try await factory.makeLaunch(for: .init(ratingKey: row.ratingKey, attemptID: row.attemptID),
            request: factory.beginPresentationRequest(), resumeRewindSeconds: rewind).get()
    }

    func launchController(_ row: DownloadRecord? = nil) async throws -> PlaybackController {
        CustomPlayerView(offlineLaunch: try await launch(row), onClose: {}).makeControllerForP7Testing()
    }

    func detailLaunch(rewind: Int = 0) async throws -> OfflinePlaybackLaunch {
        var admitted: OfflinePlaybackLaunch?
        await DetailView.presentLocalRequest(identity, manager: manager,
            request: manager.offlinePlaybackLaunchFactory.beginPresentationRequest(),
            resumeRewindSeconds: rewind, orientation: {}, present: { admitted = $0.launch })
        return try #require(admitted)
    }

    func detailController() async throws -> PlaybackController {
        DetailView.makeLocalPlayer(request: .init(launch: try await detailLaunch()),
                                   onClose: {}).makeControllerForP7Testing()
    }

    func finish() async {
        await manager.drainManagerOperationsForTesting()
        await store.drainArtifactWorkerForP6Testing()
        session.invalidateInjectedSessionForTesting()
        transport.invalidateAndCancel()
    }
}

@Suite("P7 exact offline playback pins", .serialized)
@MainActor
struct P7OfflinePlaybackTests {
    @Test func detailProgressSavesLocalPosition() async throws {
        let f = try await P7PlaybackFixture()
        // Exercise Detail's actual CustomPlayerView -> controller factory -> progress callback.
        let controller = try await f.detailController()
        controller.recordLocalPlaybackPosition(60_000)
        await f.manager.drainManagerOperationsForTesting()
        #expect(f.store.record(for: f.key)?.metadata?.localPlaybackPositionMs == 60_000)
        await f.finish()
    }

    @Test(arguments: [false, true])
    func actualPlayingAtZeroVerifiesWithoutProgress(fromDetail: Bool) async throws {
        let f = try await P7PlaybackFixture(position: 0)
        let controller = try await (fromDetail ? f.detailController() : f.libraryController())
        controller.observeTimeControlStatus(.playing)
        await f.manager.drainManagerOperationsForTesting()
        #expect(f.store.record(for: f.key)?.status == .complete)
        controller.stop()
        await f.finish()
    }

    @Test func oldSessionCloseCannotOverwriteReopenAfterHeldCommit() async throws {
        let hold = P6Hold()
        let f = try await P7PlaybackFixture(status: .complete, index: .init { data, url in
            hold.hit()
            try DownloadIndexFileCommitter().commit(data, to: url)
        })
        defer { hold.release.signal() }
        let old = try await f.launchController()
        hold.arm()
        old.recordLocalPlaybackPosition(40_000)
        _ = await hold.acknowledgement.wait()
        var reopened = f.record
        reopened.metadata?.localPlaybackPositionMs = 91_000
        let newer = try await f.launchController(reopened)
        newer.recordLocalPlaybackPosition(91_000)
        old.stop()
        hold.release.signal()
        await f.manager.drainManagerOperationsForTesting()
        #expect(f.store.record(for: f.key)?.metadata?.localPlaybackPositionMs == 91_000)
        await f.finish()
    }

    @Test func replacedAttemptRejectsOldPlayerClose() async throws {
        let f = try await P7PlaybackFixture(status: .complete)
        let old = try await f.launchController()
        var replacement = f.files.record("b", status: .unverified, filename: "replacement.mp4")
        replacement.metadata?.duration = 600_000
        replacement.metadata?.localPlaybackPositionMs = 91_000
        try Data([1]).write(to: replacement.localURL)
        let submission = f.store.submitAttemptOwnedRecord(replacement,
            attemptID: replacement.attemptID!, replacing: f.key.attemptID)
        _ = await f.store.resolve(submission, deadline: .after(5))
        old.recordLocalPlaybackPosition(120_000)
        old.observeTimeControlStatus(.playing)
        old.stop()
        await f.manager.drainManagerOperationsForTesting()
        #expect(f.store.record(for: replacement.ratingKey)?.metadata?.localPlaybackPositionMs == 91_000)
        #expect(f.store.record(for: replacement.ratingKey)?.status == .unverified)
        await f.finish()
    }

    @Test func startupCloseDoesNotVerifySavedOffset() async throws {
        let f = try await P7PlaybackFixture()
        try await f.launchController().stop()
        await f.manager.drainManagerOperationsForTesting()
        #expect(f.store.record(for: f.key)?.status == .unverified)
        await f.finish()
    }

    @Test func heldCommitCoalescesPendingSamplesAndRetainsClose() async throws {
        let hold = P6Hold()
        let writes = Mutex(0)
        let f = try await P7PlaybackFixture(status: .complete, index: .init { data, url in
            hold.hit()
            writes.withLock { $0 += 1 }
            try DownloadIndexFileCommitter().commit(data, to: url)
        })
        defer { hold.release.signal() }
        writes.withLock { $0 = 0 }
        hold.arm()
        let controller = try await f.launchController()
        controller.recordLocalPlaybackPosition(1_000)
        _ = await hold.acknowledgement.wait()
        for position in 2...20 {
            for _ in 0..<2 {
                controller.recordLocalPlaybackPosition(position * 1_000)
            }
        }
        // The controller's terminal sample is queued behind the held save.
        controller.stop()
        hold.release.signal()
        await f.manager.drainManagerOperationsForTesting()
        #expect(writes.withLock { $0 } <= 2)
        #expect(f.store.record(for: f.key)?.metadata?.localPlaybackPositionMs == 30_000)
        await f.finish()
    }

    @Test func launchRejectsMissingFileAndNonterminalAttempt() async throws {
        let f = try await P7PlaybackFixture(status: .complete)
        try FileManager.default.removeItem(at: f.record.localURL)
        let factory = f.manager.offlinePlaybackLaunchFactory
        let missing = await factory.makeLaunch(for: f.identity,
            request: factory.beginPresentationRequest(), resumeRewindSeconds: 0)
        if case .failure(.missingFile) = missing {} else { Issue.record("Expected missing-file rejection") }
        await f.finish()

        let queued = try await P7PlaybackFixture(status: .paused)
        let rejected = await queued.manager.offlinePlaybackLaunchFactory.makeLaunch(for: queued.identity,
            request: queued.manager.beginPresentationRequest(), resumeRewindSeconds: 0)
        if case .failure(.nonterminal) = rejected {} else { Issue.record("Expected nonterminal rejection") }
        await queued.finish()
    }

    @Test func persistenceFailureIsTypedAndCloseIsNonblocking() async throws {
        let failing = Mutex(false)
        let f = try await P7PlaybackFixture(status: .complete, index: .init { data, url in
            if failing.withLock({ $0 }) { throw CocoaError(.fileWriteOutOfSpace) }
            try DownloadIndexFileCommitter().commit(data, to: url)
        })
        let launch = try await f.launch()
        let sink = try #require(launch.events as? BoundOfflinePlaybackEventSink)
        failing.withLock { $0 = true }
        sink.close(finalSample: .init(positionMs: 45_000, durationMs: nil))
        // MainActor reaches this immediately; no synchronous close flush.
        #expect(sink.lastPersistenceResult == nil)
        await sink.worker?.value
        if case .persistenceFailed = sink.lastPersistenceResult {} else {
            Issue.record("Expected a typed persistence failure")
        }
        failing.withLock { $0 = false }
        await f.finish()
    }

    @Test func launchUsesMetadataBackendAndLocalResumeOnce() async throws {
        let f = try await P7PlaybackFixture(status: .complete)
        _ = await f.store.updateMetadataAsync(for: f.key) { metadata in
            metadata.backendKind = .emby
            metadata.viewOffset = 120_000
            metadata.localPlaybackPositionMs = 30_000
        }
        let launch = try await f.launch(rewind: 10)
        #expect(launch.backend == .emby)
        #expect(launch.item.viewOffset == 20_000)
        if case .embyBIF = launch.preview {} else { Issue.record("Expected metadata-owned preview kind") }
        await f.finish()
    }

    @Test(arguments: [5_000, 30_000, 599_000])
    func libraryAndDetailApplySameRewind(position: Int) async throws {
        let f = try await P7PlaybackFixture(status: .complete, position: position)
        let detail = try await f.detailLaunch(rewind: 10)
        let library = try await f.libraryLaunch(rewind: 10)
        #expect(library.item.viewOffset == detail.item.viewOffset)
        #expect(library.item.viewOffset == (position == 599_000 ? 0 : max(0, position - 10_000)))
        await f.finish()
    }

    @Test(arguments: [DownloadBackendKind.plex, .jellyfin, .emby], [false, true])
    func joinedSurfacesLaunchLocalWithoutNetwork(backend: DownloadBackendKind, fromDetail: Bool) async throws {
        let f = try await P7PlaybackFixture(status: .complete)
        // Deliberately conflicts with the fixture's plex-prefixed key. No authenticated lane exists.
        _ = await f.store.updateMetadataAsync(for: f.key) { $0.backendKind = backend }
        let launch = try await (fromDetail ? f.detailLaunch(rewind: 10) : f.libraryLaunch(rewind: 10))
        #expect(launch.backend == backend)
        switch (backend, launch.preview) {
        case (.plex, .plexBIF), (.jellyfin, .jellyfinTiles), (.emby, .embyBIF): break
        default: Issue.record("Surface selected preview by key prefix")
        }
        let controller = (fromDetail
            ? DetailView.makeLocalPlayer(request: .init(launch: launch), onClose: {})
            : OfflineLibraryView.makeOfflinePlayer(launch: launch, onClose: {})).makeControllerForP7Testing()
        #expect(controller.item.viewOffset == 20_000)
        controller.start()
        let asset = try #require(controller.player.currentItem?.asset as? AVURLAsset)
        #expect(asset.url == f.record.localURL)
        controller.recordLocalPlaybackPosition(45_000)
        controller.observeTimeControlStatus(.playing)
        controller.stop()
        await f.manager.drainManagerOperationsForTesting()
        #expect(f.store.record(for: f.key)?.metadata?.localPlaybackPositionMs == 20_000)
        #expect(f.requests.value == 0)
        await f.finish()
    }

    @Test(arguments: [false, true])
    func joinedSurfacesRejectRemovedLocalSource(fromDetail: Bool) async throws {
        let f = try await P7PlaybackFixture(status: .complete)
        try FileManager.default.removeItem(at: f.record.localURL)
        if fromDetail {
            var presented = false
            await DetailView.presentLocalRequest(f.identity, manager: f.manager,
                request: f.manager.beginPresentationRequest(), orientation: {}, present: { _ in presented = true })
            #expect(!presented)
        } else {
            let result = await OfflineLibraryPlaybackPresentation(factory: f.manager.offlinePlaybackLaunchFactory)
                .launch(for: f.identity, resumeRewindSeconds: 0, orientation: {})
            if case .failure(.missingFile) = result {} else { Issue.record("Missing local source admitted") }
        }
        #expect(f.requests.value == 0)
        await f.finish()
    }

    @Test func presentationRequestGenerationRejectsOlderTask() async throws {
        let f = try await P7PlaybackFixture(status: .complete)
        let entered = P6Acknowledgement<Bool>()
        let release = P6Acknowledgement<Bool>()
        let factory = f.manager.offlinePlaybackLaunchFactory
        let oldRequest = factory.beginPresentationRequest()
        var starts: [UInt64] = []
        let old = Task { @MainActor in
            await DetailView.presentLocalRequest(f.identity, manager: f.manager, request: oldRequest, orientation: {
                entered.signal(true)
                _ = await release.wait()
            }, present: { starts.append($0.launch.presentationRequest.generation) })
        }
        _ = await entered.wait()
        let newRequest = factory.beginPresentationRequest()
        await DetailView.presentLocalRequest(f.identity, manager: f.manager, request: newRequest, orientation: {},
            present: { starts.append($0.launch.presentationRequest.generation) })
        release.signal(true)
        await old.value
        #expect(starts == [newRequest.generation])
        await f.finish()
    }

    @Test(arguments: [false, true])
    func orientationCannotPresentReplacedAttempt(fromDetail: Bool) async throws {
        let f = try await P7PlaybackFixture(status: .complete)
        let entered = P6Acknowledgement<Bool>()
        let release = P6Acknowledgement<Bool>()
        var presented = false
        let orientation = {
            entered.signal(true)
            _ = await release.wait()
        }
        let presentation = Task { @MainActor in
            if fromDetail {
                await DetailView.presentLocalRequest(f.identity, manager: f.manager,
                    request: f.manager.offlinePlaybackLaunchFactory.beginPresentationRequest(), orientation: orientation,
                    present: { _ in presented = true })
            } else {
                let result = await OfflineLibraryPlaybackPresentation(factory: f.manager.offlinePlaybackLaunchFactory)
                    .launch(for: f.identity, resumeRewindSeconds: 0, orientation: orientation)
                if case .success = result { presented = true }
            }
        }
        _ = await entered.wait()
        let replacement = f.files.record("b", status: .complete, filename: "replacement.mp4")
        try Data([1]).write(to: replacement.localURL)
        _ = await f.store.resolve(f.store.submitAttemptOwnedRecord(replacement,
            attemptID: replacement.attemptID!, replacing: f.key.attemptID), deadline: .after(5))
        release.signal(true)
        await presentation.value
        #expect(!presented)
        await f.finish()
    }
}
#endif
