#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

@Suite("Queued download posters", .serialized)
@MainActor
struct DownloadQueuedPosterTests {
    enum Entry: CaseIterable { case individual, season, restored }

    @Test(arguments: [DownloadBackendKind.plex, .jellyfin, .emby], Entry.allCases)
    func posterArrivesBeforeAdmission(backend: DownloadBackendKind, entry: Entry) async throws {
        try await exercise(backend: backend, entry: entry, deleteBeforeResponse: false)
    }

    @Test(arguments: [DownloadBackendKind.plex, .jellyfin, .emby])
    func deleteFencesHeldResponse(backend: DownloadBackendKind) async throws {
        try await exercise(backend: backend, entry: .individual, deleteBeforeResponse: true)
    }

    private func exercise(backend: DownloadBackendKind, entry: Entry,
                          deleteBeforeResponse: Bool) async throws {
        let f = try await P7PlaybackFixture(status: .failed)
        let model = f.manager.appModel
        let server = URL(string: "https://media.example.invalid")!
        model.token = "fixture-token"
        model.serverToken = "fixture-token"
        model.serverBaseURL = server
        model.jellyfinServerBaseURL = server
        model.jellyfinAccessToken = "fixture-token"
        model.jellyfinUserID = "fixture-user"
        model.embyServerBaseURL = server
        model.embyAccessToken = "fixture-token"
        model.embyUserID = "fixture-user"
        f.manager.setQueuePausedForTesting(false)
        // Fill every lane without starting a transfer or making a server-preparation request.
        for index in 0..<5 {
            _ = f.manager.admission.beginSupervision("occupant-\(index)", lane: .staticFile, origin: .user)
        }
        let entered = P6Acknowledgement<Bool>()
        let release = DispatchSemaphore(value: 0)
        let requested = TestLockedBox<[String]>([])
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let stub = TestURLProtocolStub { request in
            requested.withValue { $0.append(request.url!.path) }
            entered.signal(true)
            _ = release.wait(timeout: .now() + 15)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, png)
        }
        let transport = URLSession(configuration: stub.configuration)
        defer { release.signal(); transport.invalidateAndCancel() }
        f.manager.optionalSideAssetSessionForTesting = transport
        let thumb = backend == .plex ? "/library/metadata/fixture/thumb" : "\(backend.rawValue)://item/fixture/Primary"
        let item = MediaItem(ratingKey: "queued-fixture", title: "Fixture", type: "movie", thumb: thumb)
        let plan = SeasonEpisodeDownloadPlan(item: item, backend: backend, choice: .original,
            mediaIndex: 0, partIndex: 0, audioStreamIndex: nil, mediaSourceIDOverride: nil,
            estimatedBytes: nil, shouldStart: true)
        switch entry {
        case .individual:
            await f.manager.requestDownload(item, backend: backend, choice: .original,
                mediaIndex: 0, partIndex: 0, audioStreamIndex: nil)
        case .season:
            let result = await f.manager.commitSeasonPlan(.init(newPlans: [plan], retryAttempts: []))
            #expect(result.succeeded)
        case .restored:
            // A persisted planned row reaches the backend-ready scan without an enqueue call.
            let seed = try #require(f.manager.plannedSeedRecord(for: plan))
            _ = await f.store.createAttemptOwnedRecordAsync(seed, attemptID: seed.attemptID!)
            f.manager.rehydrateMissingOptionalSideAssetsForCompletedRows(reason: "backend_ready")
        }
        let id = DownloadRecordIdentity.recordKey(for: item.ratingKey, backend: backend)
        let row = try #require(f.store.record(for: id))
        let key = try #require(f.manager.attemptKey(for: row))
        #expect(row.lifecycle == .planned)
        #expect(f.manager.admission.supervised[id] == nil)
        #expect(await entered.wait(seconds: 5) == true, "Poster must dispatch while all admission slots are occupied")
        if deleteBeforeResponse { f.manager.delete(ratingKey: id) }
        release.signal()
        try #require(await p6AwaitTask(Task { await f.manager.downloadWorkRegistry.waitForSideCacheForTesting(for: key) }))
        await f.manager.drainManagerOperationsForTesting()
        await f.store.drainArtifactWorkerForP6Testing()
        let poster = f.store.posterDestinationURL(ratingKey: id)
        if deleteBeforeResponse {
            #expect(f.store.record(for: id) == nil)
            #expect(!FileManager.default.fileExists(atPath: poster.path))
        } else {
            let updated = try #require(f.store.record(for: key))
            #expect(updated.posterURL == poster)
            #expect(updated.sideAssetBytes == png.count)
            #expect(updated.metadata?.posterGeneration == 1)
            #expect(updated.metadata?.sideAssetBundleOwner?.attemptID == key.attemptID.rawValue)
            #expect(updated.lifecycle == .planned)
            // The on-disk index and cached file remain usable by a newly loaded store.
            await f.store.drainArtifactWorkerForP6Testing()
            let relaunched = DownloadStore(baseDirectory: f.files.directory)
            #expect(relaunched.record(for: id)?.posterURL == poster)
        }
        #expect(requested.value.count == 1, "Only the poster may fetch before admission")
        try #require(await p6AwaitTask(f.manager.completedSideAssetInventoryWorker))
        await f.finish()
    }
}
#endif
