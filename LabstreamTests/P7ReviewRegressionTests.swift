#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

@Suite("P7 review regression pins", .downloadTestFiles, .serialized)
struct P7ReviewRegressionTests {
    @Test(arguments: [DownloadBackendKind.emby, .jellyfin])
    func enabledRunnerDoesNotBlockSignOutHeartbeat(backend: DownloadBackendKind) async throws {
        let hold = P6Hold()
        let completed = TestLockedBox(false)
        let live = DownloadCleanupIntentJournal.Persistence.live
        let f = try await P7PlaybackFixture(status: .paused, cleanupPersistence: .init(
            read: live.read, encode: live.encode, commit: { data, url in
                hold.hit()
                completed.withValue { $0 = true }
                try live.commit(data, url)
            }, syncDirectory: live.syncDirectory))
        defer { hold.release.signal() }
        await f.manager.cleanupRunner?.waitUntilIdle()
        _ = await f.store.updateMetadataAsync(for: f.key) {
            $0.backendKind = backend
            $0.backendBaseURLString = "https://media.invalid"
            $0.backendUserID = "fixture-user"
            $0.resumeMode = .liveForwardOnly
            $0.playSessionID = "held-session"
        }
        #expect(await f.manager.applyLifecycleEvent(.retry(.freshAttempt), for: f.key, context: "review_fixture"))
        let passStarted = DispatchSemaphore(value: 0)
        await MainActor.run {
            var dependencies = f.manager.makeCleanupRunnerDependencies()
            let barriers = dependencies.runBarriers
            dependencies.runBarriers = { deadline in passStarted.signal(); return await barriers(deadline) }
            f.manager.cleanupRunner = DownloadCleanupIntentRunner(dependencies: dependencies)
            let model = f.manager.appModel
            if backend == .emby {
                model.embyServerBaseURL = URL(string: "https://media.invalid")!
                model.embyAccessToken = "fixture"
                model.embyUserID = "fixture-user"
                f.manager.embyPlaySessionByAttempt[f.key] = "held-session"
            } else {
                model.jellyfinServerBaseURL = URL(string: "https://media.invalid")!
                model.jellyfinAccessToken = "fixture"
                model.jellyfinUserID = "fixture-user"
                f.manager.jellyfinPlaySessionByAttempt[f.key] = "held-session"
            }
            f.manager.activeJobs.insert(f.key.ratingKey)
            f.manager.inFlightAttempts.acquire(f.key)
            f.manager.refreshRecords()
            hold.arm()
            f.manager.pauseDownloadsForBackendSignOut(backend)
            model.embyAccessToken = nil
            model.jellyfinAccessToken = nil
        }
        try #require(await p6Signal(hold.entered))
        let heartbeat = DispatchSemaphore(value: 0)
        Task { @MainActor in
            #expect(f.manager.cleanupRunner != nil)
            f.manager.cleanupRunner?.enable()
        }
        try #require(await p6Signal(passStarted))
        Task { @MainActor in heartbeat.signal() }
        // This assertion runs outside MainActor; release remains possible on a broken build.
        #expect(await p6Signal(heartbeat))
        for _ in 0..<3 {
            let tick = DispatchSemaphore(value: 0)
            Task { @MainActor in tick.signal() }
            #expect(await p6Signal(tick))
        }
        #expect(!completed.value)
        #expect(await f.manager.runCleanupBarriers(deadline: .after(0.05)) == false)
        #expect(await f.manager.pendingCleanupBackends(deadline: .after(0.05)).contains(backend))
        #expect(!completed.value)
        hold.release.signal()
        await f.manager.drainManagerOperationsForTesting()
        await f.manager.cleanupRunner?.waitUntilIdle()
        await f.finish()
    }

    @Test(arguments: [DownloadBackendKind.emby, .jellyfin])
    @MainActor func pausedEncoderCrashWindowReplaysExactlyOnce(backend: DownloadBackendKind) async throws {
        let files = try P6Fixture()
        let commits = TestLockedBox(0)
        let seed = files.store()
        var row = files.record(status: .paused, mode: .liveForwardOnly)
        row.metadata?.backendKind = backend
        row.metadata?.backendBaseURLString = "https://media.invalid"
        row.metadata?.backendUserID = "fixture-user"
        row.metadata?.playSessionID = "orphan-session"
        #expect(await seed.createAttemptOwnedRecordAsync(row, attemptID: row.attemptID!) == .committed(
            .init(ratingKey: row.ratingKey, attemptID: row.attemptID!)))
        // Legacy opaque resume evidence keeps this paused row paused through reconcile.
        let key = DownloadAttemptKey(ratingKey: row.ratingKey, attemptID: row.attemptID!)
        _ = await seed.resolve(seed.submitResumeData(for: key, Data([1, 2, 3])), deadline: .after(5))
        // This new store models death after the paused index committed but before journal commit.
        let store = files.store()
        let live = DownloadCleanupIntentJournal.Persistence.live
        let journal = DownloadCleanupIntentJournal(directory: store.durableCleanupAuthorityDirectory,
            persistence: .init(read: live.read, encode: live.encode, commit: { data, url in
                commits.withValue { $0 += 1 }
                try live.commit(data, url)
            }, syncDirectory: live.syncDirectory))
        #expect(journal.load() == .loaded([]))
        let session = BackgroundDownloadSession(store: store, protocolClasses: [])
        defer { session.invalidateInjectedSessionForTesting() }
        let manager = DownloadTestFiles.manager(appModel: AppModel(identity: PlatformClientIdentity.make(
            clientIdentifier: "paused-recovery")), store: store, session: session,
            cleanupIntentJournal: journal, registerForBackgroundEvents: false)
        try #require(await manager.awaitStartupRecoveryForTesting())
        await manager.launchSweepJournaling?.value
        manager.teardownOrphanedEncodersOnLaunch()
        await manager.launchSweepJournaling?.value
        await manager.cleanupRunner?.waitUntilIdle()
        guard case .loaded(let intents) = journal.load() else { Issue.record("Unreadable journal"); return }
        #expect(intents.count == 1)
        #expect(intents.first?.operation == .activeEncoding(playSessionID: "orphan-session"))
        #expect(commits.value == 1)
        #expect(store.records.first?.status == .paused)
    }

    @Test(arguments: [DownloadBackendKind.emby, .plex],
          [DownloadResumeMode.serverPrepThenStatic, .staticByteRange])
    @MainActor func pausedResumableJobsKeepTheirAuthority(backend: DownloadBackendKind, mode: DownloadResumeMode) async throws {
        let files = try P6Fixture()
        let store = files.store()
        var row = files.record(status: .paused, mode: mode)
        row.metadata?.backendKind = backend
        row.metadata?.backendBaseURLString = "https://media.invalid"
        row.metadata?.backendUserID = "fixture-user"
        row.metadata?.playSessionID = "owned-session"
        if backend == .emby { row.metadata?.embyConvertJobID = 12 }
        else { row.metadata?.optimizeQueueTitle = "[Labstream fixture]" }
        let key = DownloadAttemptKey(ratingKey: row.ratingKey, attemptID: row.attemptID!)
        #expect(await store.createAttemptOwnedRecordAsync(row, attemptID: key.attemptID) == .committed(key))
        let session = BackgroundDownloadSession(store: store, protocolClasses: [])
        defer { session.invalidateInjectedSessionForTesting() }
        let manager = DownloadTestFiles.manager(appModel: AppModel(identity: PlatformClientIdentity.make(
            clientIdentifier: "prep-recovery")), store: store, session: session, registerForBackgroundEvents: false)
        try #require(await manager.awaitStartupRecoveryForTesting())
        await manager.launchSweepJournaling?.value
        await manager.cleanupRunner?.waitUntilIdle()
        #expect(manager.cleanupIntentJournal.load() == .loaded([]))
        #expect(store.record(for: key)?.status == .paused)
        #expect(store.record(for: key)?.metadata?.playSessionID == "owned-session")
        #expect(store.record(for: key)?.metadata?.embyConvertJobID == row.metadata?.embyConvertJobID)
        #expect(store.record(for: key)?.metadata?.optimizeQueueTitle == row.metadata?.optimizeQueueTitle)
    }

    @Test(arguments: [false, true], ["missing", "replaced", "superseded", "cancelled"])
    @MainActor func rejectedOrientationRestoresOnlyCurrentRequest(fromDetail: Bool, rejection: String) async throws {
        let supersedes = rejection == "superseded"
        let f = try await P7PlaybackFixture(status: .complete)
        let entered = P6Acknowledgement<Bool>()
        let release = P6Acknowledgement<Bool>()
        let library = OfflineLibraryPlaybackPresentation(factory: f.manager.offlinePlaybackLaunchFactory)
        var locked = false
        var restores = 0
        var presented = 0
        let orientation = { locked = true; entered.signal(true); _ = await release.wait() }
        let restore = { locked = false; restores += 1 }
        let old = Task { @MainActor in
            if fromDetail {
                await DetailView.presentLocalRequest(f.identity, manager: f.manager,
                    request: f.manager.beginPresentationRequest(), orientation: orientation,
                    restoreOrientation: restore, present: { _ in presented += 1 })
            } else {
                _ = await library.launch(for: f.identity, resumeRewindSeconds: 0,
                    orientation: orientation, restoreOrientation: restore)
            }
        }
        _ = await entered.wait()
        if supersedes {
            if fromDetail {
                await DetailView.presentLocalRequest(f.identity, manager: f.manager,
                    request: f.manager.beginPresentationRequest(), orientation: { locked = true },
                    restoreOrientation: restore, present: { _ in presented += 1 })
            } else {
                if case .success = await library.launch(for: f.identity, resumeRewindSeconds: 0,
                    orientation: { locked = true }, restoreOrientation: restore) { presented += 1 }
            }
        } else if rejection == "cancelled" {
            old.cancel()
        } else if rejection == "replaced" {
            let replacement = f.files.record("b", status: .complete, filename: "replacement.mp4")
            try Data([1]).write(to: replacement.localURL)
            #expect(await f.store.createAttemptOwnedRecordAsync(replacement, attemptID: replacement.attemptID!,
                replacing: f.key.attemptID) == .committed(.init(ratingKey: replacement.ratingKey,
                    attemptID: replacement.attemptID!)))
        } else {
            try FileManager.default.removeItem(at: f.record.localURL)
        }
        release.signal(true)
        await old.value
        #expect(restores == (supersedes ? 0 : 1))
        #expect(locked == supersedes)
        #expect(presented == (supersedes ? 1 : 0))
        if rejection == "cancelled" { #expect(f.manager.offlinePlaybackSinks[f.key] == nil) }
        await f.finish()
    }
}
#endif
