#if !os(tvOS)
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
    var key: DownloadAttemptKey { .init(ratingKey: record.ratingKey, attemptID: record.attemptID!) }

    init(status: DownloadStatus = .unverified, position: Int = 30_000,
         index: DownloadStore.IndexPersistence = .live) async throws {
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
        store = files.store(index: index)
        session = BackgroundDownloadSession(store: store, protocolClasses: [])
        manager = DownloadManager(appModel: AppModel(identity: PlatformClientIdentity.make(
            clientIdentifier: "p7-fixture")), store: store, session: session,
            registerForBackgroundEvents: false)
        try #require(await manager.awaitStartupRecoveryForTesting())
    }

    func libraryController(_ row: DownloadRecord? = nil) -> PlaybackController {
        OfflineLibraryView.makeOfflinePlayer(record: row ?? record, manager: manager,
                                             onClose: {}).makeControllerForP7Testing()
    }

    func detailRequest() -> DetailView.LocalPlaybackRequest {
        DetailView.LocalPlaybackRequest(url: record.localURL,
            item: record.metadata!.makeMediaItem(), trickPlayURL: nil, trickPlayKind: nil,
            posterURL: nil, artworkSource: nil, chapterImageURLs: [:], offlineChapters: [],
            offlineTextSubtitles: [], downloadRatingKey: record.ratingKey)
    }

    func detailController() -> PlaybackController {
        DetailView.makeLocalPlayer(request: detailRequest(), onClose: {}).makeControllerForP7Testing()
    }

    func finish() async {
        await manager.drainManagerOperationsForTesting()
        await store.drainArtifactWorkerForP6Testing()
        session.invalidateInjectedSessionForTesting()
    }
}

@Suite("P7 exact offline playback pins", .serialized)
@MainActor
struct P7OfflinePlaybackTests {
    @Test func detailProgressSavesLocalPosition() async throws {
        let f = try await P7PlaybackFixture()
        // Exercise Detail's actual CustomPlayerView -> controller factory -> progress callback.
        let controller = f.detailController()
        controller.recordLocalPlaybackPosition(60_000)
        await f.manager.drainManagerOperationsForTesting()
        withKnownIssue("P7 red pin: 01") {
            #expect(f.store.record(for: f.key)?.metadata?.localPlaybackPositionMs == 60_000)
        }
        await f.finish()
    }

    @Test(arguments: [false, true])
    func actualPlayingAtZeroVerifiesWithoutProgress(fromDetail: Bool) async throws {
        let f = try await P7PlaybackFixture(position: 0)
        let controller = fromDetail ? f.detailController() : f.libraryController()
        controller.observeTimeControlStatus(.playing)
        await f.manager.drainManagerOperationsForTesting()
        withKnownIssue("P7 red pin: 01-observed") {
            #expect(f.store.record(for: f.key)?.status == .complete)
        }
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
        let old = f.libraryController()
        hold.arm()
        old.recordLocalPlaybackPosition(40_000)
        _ = await hold.acknowledgement.wait()
        var reopened = f.record
        reopened.metadata?.localPlaybackPositionMs = 91_000
        let newer = f.libraryController(reopened)
        newer.recordLocalPlaybackPosition(91_000)
        old.stop()
        hold.release.signal()
        await f.manager.drainManagerOperationsForTesting()
        withKnownIssue("P7 red pin: 02-session") {
            #expect(f.store.record(for: f.key)?.metadata?.localPlaybackPositionMs == 91_000)
        }
        await f.finish()
    }

    @Test func replacedAttemptRejectsOldPlayerClose() async throws {
        let f = try await P7PlaybackFixture(status: .complete)
        let old = f.libraryController()
        var replacement = f.files.record("b", status: .unverified, filename: "replacement.mp4")
        replacement.metadata?.duration = 600_000
        replacement.metadata?.localPlaybackPositionMs = 91_000
        try Data([1]).write(to: replacement.localURL)
        let submission = f.store.submitAttemptOwnedRecord(replacement,
            attemptID: replacement.attemptID!, replacing: f.key.attemptID)
        _ = await f.store.resolve(submission, deadline: .after(5))
        old.stop()
        await f.manager.drainManagerOperationsForTesting()
        withKnownIssue("P7 red pin: 02") {
            #expect(f.store.record(for: replacement.ratingKey)?.metadata?.localPlaybackPositionMs == 91_000)
            #expect(f.store.record(for: replacement.ratingKey)?.status == .unverified)
        }
        await f.finish()
    }

    @Test func startupCloseDoesNotVerifySavedOffset() async throws {
        let f = try await P7PlaybackFixture()
        f.libraryController().stop()
        await f.manager.drainManagerOperationsForTesting()
        withKnownIssue("P7 red pin: 03") {
            #expect(f.store.record(for: f.key)?.status == .unverified)
        }
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
        f.manager.updateLocalPlaybackPosition(ratingKey: f.key.ratingKey, positionMs: 1_000, durationMs: 600_000)
        _ = await hold.acknowledgement.wait()
        for position in 2...20 {
            for _ in 0..<2 {
                f.manager.updateLocalPlaybackPosition(ratingKey: f.key.ratingKey,
                    positionMs: position * 1_000, durationMs: 600_000)
            }
        }
        // The controller's terminal sample is queued behind the held save.
        f.libraryController().stop()
        hold.release.signal()
        await f.manager.drainManagerOperationsForTesting()
        withKnownIssue("P7 red pin: 05") {
            #expect(writes.withLock { $0 } <= 2)
        }
        #expect(f.store.record(for: f.key)?.metadata?.localPlaybackPositionMs == 30_000)
        await f.finish()
    }

    @Test(arguments: [5_000, 30_000, 599_000])
    func libraryAndDetailApplySameRewind(position: Int) async throws {
        let f = try await P7PlaybackFixture(status: .complete, position: position)
        let detail = DetailPlaybackLauncher.itemWithResumeRewind(
            f.record.metadata!.makeMediaItem(), resumeRewindSeconds: 10)
        let library = OfflineLibraryView.offlineItem(from: f.record)
        if position == 599_000 {
            // Existing near-end reset is retained, rather than an unexpected passing known issue.
            #expect(library.viewOffset == detail.viewOffset)
        } else {
            withKnownIssue("P7 red pin: 06") { #expect(library.viewOffset == detail.viewOffset) }
        }
        await f.finish()
    }

    @Test func presentationRequestGenerationRejectsOlderTask() async throws {
        let f = try await P7PlaybackFixture(status: .complete)
        let entered = P6Acknowledgement<Bool>()
        let release = P6Acknowledgement<Bool>()
        let oldRequest = f.detailRequest()
        let newRequest = f.detailRequest()
        var starts: [UUID] = []
        let old = Task { @MainActor in
            await DetailView.presentLocalRequest(oldRequest, orientation: {
                entered.signal(true)
                _ = await release.wait()
            }, present: { starts.append($0.id) })
        }
        _ = await entered.wait()
        await DetailView.presentLocalRequest(newRequest, orientation: {},
            present: { starts.append($0.id) })
        release.signal(true)
        await old.value
        withKnownIssue("P7 red pin: presentation-generation") {
            #expect(starts == [newRequest.id])
        }
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
                await DetailView.presentLocalRequest(f.detailRequest(), orientation: orientation,
                    present: { _ in presented = true })
            } else {
                await OfflineLibraryView.presentOfflineRecord(f.record, orientation: orientation,
                    present: { _ in presented = true })
            }
        }
        _ = await entered.wait()
        let replacement = f.files.record("b", status: .complete, filename: "replacement.mp4")
        try Data([1]).write(to: replacement.localURL)
        _ = await f.store.resolve(f.store.submitAttemptOwnedRecord(replacement,
            attemptID: replacement.attemptID!, replacing: f.key.attemptID), deadline: .after(5))
        release.signal(true)
        await presentation.value
        withKnownIssue("P7 red pin: orientation") { #expect(!presented) }
        await f.finish()
    }
}
#endif
