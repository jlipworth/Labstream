#if !os(tvOS)
import Foundation
import PMSKit
import Synchronization
import Testing
@testable import Labstream

@Suite("P6 review regression pins", .serialized)
struct P6ReviewRegressionTests {
    @Test("cleanup journal failure and held index commit leave MainActor responsive", arguments: [false, true])
    func cleanupRecoveryHeartbeat(relaunch: Bool) async throws {
        let fixture = try P6Fixture()
        let initial = fixture.store()
        var row = fixture.record(status: .failed, mode: .serverPrepThenStatic, ratingKey: "emby:fixture")
        row.metadata?.backendKind = .emby
        row.metadata?.backendBaseURLString = "https://example.invalid"
        row.metadata?.backendServerID = "fixture-server"
        row.metadata?.backendUserID = "fixture-user"
        row.metadata?.playSessionID = "fixture-session"
        let key = DownloadAttemptKey(ratingKey: row.ratingKey, attemptID: row.attemptID!)
        try #require(initial.createAttemptOwnedRecord(row, attemptID: key.attemptID) == .committed(key))
        let intent = try #require(DurableDownloadCleanupIntent(
            attemptKey: key, backend: .emby,
            server: .init(baseURL: URL(string: "https://example.invalid")!, serverID: "fixture-server", userID: "fixture-user")!,
            operation: .activeEncoding(playSessionID: "fixture-session")))
        if relaunch { try #require(initial.markDeletionPending(for: key, cleanupIntents: [intent]) == .applied) }
        let hold = P6Hold()
        let journalEntered = P6Acknowledgement<Bool>()
        let journal = DownloadCleanupIntentJournal(directory: fixture.directory, persistence: .init(
            read: DownloadCleanupIntentJournal.Persistence.live.read,
            encode: { try JSONEncoder().encode($0) },
            commit: { _, _ in journalEntered.signal(true); throw CocoaError(.fileWriteUnknown) }))
        let store = fixture.store(index: .init { data, url in
            hold.hit()
            try DownloadIndexFileCommitter().commit(data, to: url)
        })
        let pair = await MainActor.run {
            let session = BackgroundDownloadSession(store: store, protocolClasses: [])
            return (DownloadManager(appModel: AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "cleanup-pin")),
                store: store, session: session, cleanupIntentJournal: journal, registerForBackgroundEvents: false), session)
        }
        defer { hold.release.signal(); pair.1.invalidateInjectedSessionForTesting() }
        if relaunch {
            // Initial recovery can beat test arming; explicitly repeat the same production sweep.
            try #require(await pair.0.awaitStartupRecoveryForTesting())
        }
        hold.arm()
        Task { @MainActor in
            if relaunch { pair.0.teardownOrphanedEncodersOnLaunch() }
            else { pair.0.delete(ratingKey: key.ratingKey) }
        }
        try #require(await journalEntered.wait())
        try #require(await hold.acknowledgement.wait())
        let heartbeat = P6HeldProgress()
        Task { @MainActor in heartbeat.acknowledge(hold) }
        #expect(await heartbeat.wait())
        #expect(store.isDeletionPending(for: key))
        hold.release.signal()
    }

    @Test("startup completing after wake expiry cannot authorize probes or refill")
    func lateStartupRespectsExpiredWake() async throws {
        let fixture = try P6Fixture()
        let initial = fixture.store()
        let key = try fixture.seed(initial, status: .unverified)
        try Data([1, 2, 3]).write(to: initial.record(for: key)!.localURL)
        let hold = P6Hold()
        hold.arm()
        let store = DownloadStore(baseDirectory: fixture.directory, startupOnWorker: true,
            startupRepairWillBegin: { hold.hit() })
        defer { hold.release.signal() }
        try #require(await hold.acknowledgement.wait())
        let clock = P6WakeClock()
        let fired = Mutex(0)
        let handlerDelivered = DispatchSemaphore(value: 0)
        let refills = Mutex(0)
        let activationDecision = P6Acknowledgement<Bool>()
        let pair = await MainActor.run {
            let registry = BackgroundDownloadCompletionRegistry(clockHooks: clock.hooks)
            registry.store(identifier: BackgroundDownloadSession.identifier) { fired.withLock { $0 += 1 }; handlerDelivered.signal() }
            let session = BackgroundDownloadSession(store: store, protocolClasses: [], wakeClockHooks: clock.hooks,
                releaseBackgroundCompletion: { registry.fireCompletions(in: $0) })
            let manager = DownloadManager(appModel: AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "late-startup")),
                store: store, session: session, backgroundCompletionRegistry: registry)
            manager.startupActivationDecisionForTesting = { activationDecision.signal(true) }
            return (manager, session)
        }
        defer { pair.1.invalidateInjectedSessionForTesting() }
        try clock.requireWakeTimers()
        clock.advance(to: 26)
        try #require(await p6Signal(handlerDelivered))
        #expect(fired.withLock { $0 } == 1)
        hold.release.signal()
        let submission = try #require(store.initialStartupSubmission)
        guard case .observed(.current) = await store.resolve(submission, deadline: .after(2)) else {
            Issue.record("startup repair did not complete"); return
        }
        // Join the manager's initial repair waiter and deferred activation turn by observing
        // startup submission; expiry must keep transport dormant even after repair is durable.
        try #require(await activationDecision.wait())
        await MainActor.run {
            #expect(!pair.1.startupAdmissionIsActiveForTesting)
            #expect(pair.0.startupActivationSubmissionCountForTesting == 0)
        }
        #expect(pair.1.revalidateCompletedDownload(ratingKey: key.ratingKey, validationLabel: "late_startup") == .deferredForBackgroundWake)
        let refillRow = fixture.record("refill", ratingKey: "plex:refill", filename: "refill.mp4")
        let refillKey = DownloadAttemptKey(ratingKey: refillRow.ratingKey, attemptID: refillRow.attemptID!)
        try #require(store.createAttemptOwnedRecord(refillRow, attemptID: refillKey.attemptID) == .committed(refillKey))
        try #require(store.attemptWorkingFileURL(for: refillKey) != nil)
        pair.1.onRangeRequestNeeded = { _, _, _ in refills.withLock { $0 += 1 } }
        pair.1.continueRangeAfterBodyForTesting(refillKey, partialSize: 3)
        #expect(refills.withLock { $0 } == 0)
        await MainActor.run { pair.0.noteAppSceneRecovery(.aggregateSceneBecameActive) }
        try #require(await pair.0.awaitStartupRecoveryForTesting())
        pair.1.continueRangeAfterBodyForTesting(refillKey, partialSize: 3)
        #expect(refills.withLock { $0 } == 1)
    }
}
#endif
