#if !os(tvOS)
import Foundation
import PMSKit
import Synchronization
import Testing
@testable import Labstream

@Suite("Async download index startup", .serialized)
struct AsyncDownloadIndexStartupTests {
    enum Fixture: CaseIterable, Sendable {
        case empty, current, unreadable, readFailure, unsupported, newer
    }

    @Test(arguments: Fixture.allCases) @MainActor
    func heldIndexReadLeavesLaunchResponsiveAndClosed(
        fixture: Fixture
    ) async throws {
        let f = try P6Fixture()
        let index = f.directory.appendingPathComponent("index.json")
        let row = f.record(status: .complete)
        switch fixture {
        case .current:
            let seed = f.store()
            try #require(seed.createAttemptOwnedRecord(row, attemptID: row.attemptID!)
                == .committed(.init(ratingKey: row.ratingKey, attemptID: row.attemptID!)))
            try Data([1]).write(to: row.localURL)
        case .empty, .readFailure: try Data(#"{"schemaVersion":5,"rows":[]}"#.utf8).write(to: index)
        case .unreadable: try Data("invalid".utf8).write(to: index)
        case .unsupported: try Data(#"{"schemaVersion":2,"rows":[]}"#.utf8).write(to: index)
        case .newer: try Data(#"{"schemaVersion":99,"rows":[]}"#.utf8).write(to: index)
        }
        let original = try Data(contentsOf: index)
        let orphan = f.directory.appendingPathComponent(
            ".attempt-stage-v1-\(String(repeating: "a", count: 64)).stage")
        try Data([2]).write(to: orphan)
        let gate = StartupIndexReadGate()
        defer { gate.release.signal() }
        let reads = Mutex(0)
        let decodes = Mutex(0)
        let writes = Mutex(0)
        let registry = BackgroundDownloadCompletionRegistry()
        var completions = 0
        registry.store(identifier: BackgroundDownloadSession.identifier, completion: { completions += 1 })
        // Exercise the manager's production construction edge, with only filesystem/index seams.
        let manager = DownloadManager(appModel: AppModel(identity: PlatformClientIdentity.make(
            clientIdentifier: "async-index-fixture")), storeConstruction: {
                DownloadStore(baseDirectory: f.directory, indexPersistence: .init(read: { url in
                    reads.withLock { $0 += 1 }
                    gate.hold()
                    if fixture == .readFailure { throw CocoaError(.fileReadNoPermission) }
                    return try Data(contentsOf: url)
                }, didDecode: { decodes.withLock { $0 += 1 } }, atomicWrite: { data, url in
                    writes.withLock { $0 += 1 }
                    try DownloadIndexFileCommitter().commit(data, to: url)
                }), startupOnWorker: true)
            }, sessionConstruction: { store in
                let session = BackgroundDownloadSession(store: store, protocolClasses: [],
                    releaseBackgroundCompletion: { registry.fireCompletions(in: $0) })
                session.rangeBodyDirectoryForTesting = f.directory
                return session
            }, backgroundCompletionRegistry: registry)
        defer { manager.session.invalidateInjectedSessionForTesting() }
        let store = manager.store
        try #require(await p6Signal(gate.entered))
        #expect(gate.isHeld, "Store and manager init must return before the index read completes")
        #expect(store.startupIndexProbe != .current && store.startupIndexProbe != .missing)
        #expect(store.startupIndexAdmission() != .current)
        #expect(!store.startChainAdmits(ratingKey: row.ratingKey, attemptID: row.attemptID!, expectedPreviousOwner: nil))
        #expect(store.cleanupDisposition(for: .init(ratingKey: row.ratingKey, attemptID: row.attemptID!)) == .unknown)
        #expect(manager.startupRecoveryState == .preparing)
        #expect(!manager.admission.recoveryComplete)
        #expect(manager.records.isEmpty)
        #expect(manager.offlineLibrarySnapshot.rows.isEmpty)
        #expect(manager.offlineAvailabilityIsResolving)
        manager.refreshOfflineAvailability(force: true)
        #expect(manager.offlineAvailabilityCache.value.scan == .unresolved)
        #expect(!manager.hasPlayableOfflineContent)
        #expect(manager.startupActivationSubmissionCountForTesting == 0)
        #expect(manager.session.diagnosticSnapshot(includePendingTempCleanupBytes: false).backgroundCompletionHandlerCount == 1)
        var heartbeat = 0
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(10))
            if gate.isHeld { heartbeat += 1 }
        }
        #expect(heartbeat == 3, "MainActor keeps running during the held index read")
        // Before loading, neither an explicit sweep nor a write-capable entry point may guess
        // that the empty row map means durable absence.
        _ = store.sweepUnreferencedAttemptStaging()
        #expect(FileManager.default.fileExists(atPath: orphan.path))
        if gate.isHeld {
            let added = f.record("early", status: .paused, ratingKey: "plex:early", filename: "early.mp4")
            #expect(store.createAttemptOwnedRecord(added, attemptID: added.attemptID!)
                != .committed(.init(ratingKey: added.ratingKey, attemptID: added.attemptID!)))
            store.upsert(added)
            _ = store.stampSchemaV5()
        }
        #expect(writes.withLock { $0 } == 0)
        #expect(decodes.withLock { $0 } == 0)
        #expect(try Data(contentsOf: index) == original)
        gate.release.signal()
        let submission = try #require(store.initialStartupSubmission)
        let result = await store.resolve(submission, deadline: .after(5))
        switch fixture {
        case .empty, .current:
            #expect(result == .observed(.current))
            #expect(store.startupIndexAdmission() == .current)
            #expect(store.records.map(\.ratingKey) == (fixture == .current ? [row.ratingKey] : []))
            #expect(decodes.withLock { $0 } == 1)
        case .unreadable, .readFailure, .newer:
            #expect(result == .observed(.unreadableIndex))
            #expect(store.startupIndexAdmission() == .unreadableIndex)
            #expect(store.records.isEmpty)
            #expect(decodes.withLock { $0 } == 0)
        case .unsupported:
            #expect(result == .observed(.requiresDestructiveReset(schemaVersion: 2)))
            #expect(decodes.withLock { $0 } == 0)
        }
        #expect(reads.withLock { $0 } == 1)
        // Observe the production terminal acknowledgement rather than racing a loaded executor
        // with a polling deadline. The manager's own startup deadline remains bounded.
        let ready = await manager.awaitStartupRecoveryForTesting()
        if fixture == .current || fixture == .empty {
            #expect(ready)
            #expect(manager.startupRecoveryState == .ready)
            await manager.offlineAvailabilityCache.worker?.value
            #expect(manager.hasPlayableOfflineContent == (fixture == .current))
        } else if fixture != .unsupported {
            #expect(!ready)
            #expect(try Data(contentsOf: index) == original)
        }
        _ = completions
    }

    @MainActor
    private func assertUnexpiredWakePublishesLateSuccess() async throws {
        let f = try P6Fixture()
        let row = f.record(status: .complete)
        let seed = f.store()
        try #require(seed.createAttemptOwnedRecord(row, attemptID: row.attemptID!)
            == .committed(.init(ratingKey: row.ratingKey, attemptID: row.attemptID!)))
        try Data([1]).write(to: row.localURL)
        let gate = StartupIndexReadGate()
        defer { gate.release.signal() }
        let store = DownloadStore(baseDirectory: f.directory, startupOnWorker: true,
            startupRepairWillBegin: { gate.hold() })
        try #require(await p6Signal(gate.entered))
        let session = BackgroundDownloadSession(store: store, protocolClasses: [])
        defer { session.invalidateInjectedSessionForTesting() }
        let manager = DownloadManager(appModel: AppModel(identity: PlatformClientIdentity.make(
            clientIdentifier: "deadline-fixture")), store: store, session: session,
            registerForBackgroundEvents: false, startupIndexDeadline: { .after(0) })
        #expect(await manager.awaitStartupRecoveryForTesting() == false)
        guard case .blocked = manager.startupRecoveryState else {
            Issue.record("The injected deadline must block the held startup")
            return
        }
        #expect(manager.offlineAvailabilityCache.value.scan == .resolved(hasPlayableFile: false))
        #expect(manager.offlineAvailabilityCache.value.indexAccess == .unreadable)
        // ContentView uses this exact gate after a transient session-restore failure.
        // The sign-in/retry controls must be reachable instead of the restoring splash.
        let restoreOutcome = SessionRestoreOutcome.temporarilyUnavailable
        #expect(BrowseUIGate.state(isBrowseReady: false,
            isRestoring: restoreOutcome == .temporarilyUnavailable && manager.offlineAvailabilityIsResolving,
            isSwitchingBackend: false, hasEverBeenBrowseReady: false,
            canOpenOffline: OfflineLaunchAvailability.admitsOfflineLaunch(restoreOutcome: restoreOutcome,
                hasPlayableDownload: manager.hasPlayableOfflineContent)) == .login)
        #expect(!manager.hasPlayableOfflineContent)
        gate.release.signal()
        _ = await store.resolve(try #require(store.initialStartupSubmission), deadline: .after(5))
        await manager.startupIndexObservationTask?.value
        #expect(await manager.awaitStartupRecoveryForTesting())
        await manager.offlineAvailabilityCache.worker?.value
        #expect(manager.startupRecoveryState == .ready)
        #expect(manager.hasPlayableOfflineContent)
        #expect(manager.records.map(\.ratingKey) == [row.ratingKey])
    }

    enum LateLoadAuthorization: CaseIterable, Sendable {
        case unexpired, foreground, newWake
    }

    @Test("Late readable startup publishes independently of wake authorization",
          arguments: LateLoadAuthorization.allCases) @MainActor
    func lateReadableStartupAfterExpiredWakePublishesBeforeAuthorizedRecovery(
        authorization: LateLoadAuthorization
    ) async throws {
        // Keep all late-load publication cases under one serialized fixture boundary.
        if authorization == .unexpired {
            try await assertUnexpiredWakePublishesLateSuccess()
        } else {
            try await assertExpiredWakePublishesBeforeAuthorizedRecovery(newWake: authorization == .newWake)
        }
    }

    @MainActor
    private func assertExpiredWakePublishesBeforeAuthorizedRecovery(newWake: Bool) async throws {
        let f = try P6Fixture()
        let seed = f.store()
        let key = try f.seed(seed, status: .unverified)
        try Data([1, 2, 3]).write(to: seed.record(for: key)!.localURL)
        let gate = StartupIndexReadGate()
        defer { gate.release.signal() }
        let store = DownloadStore(baseDirectory: f.directory, startupOnWorker: true,
            startupRepairWillBegin: { gate.hold() })
        try #require(await p6Signal(gate.entered))
        let clock = P6WakeClock()
        let released = P6Acknowledgement<Bool>()
        let constructions = Mutex(0)
        let probes = Mutex(0)
        let refills = Mutex(0)
        let registry = BackgroundDownloadCompletionRegistry(clockHooks: clock.hooks)
        let session = BackgroundDownloadSession(store: store, protocolClasses: [],
            playbackValidator: { _, _ in
                probes.withLock { $0 += 1 }
                return .init(played: true, reason: "played", durationMs: nil, detail: nil)
            },
            wakeClockHooks: clock.hooks,
            transportWillConstruct: { constructions.withLock { $0 += 1 } },
            releaseBackgroundCompletion: { registry.fireCompletions(in: $0) })
        defer { session.invalidateInjectedSessionForTesting() }
        registry.register(session)
        registry.store(identifier: BackgroundDownloadSession.identifier) { released.signal(true) }
        try clock.requireWakeTimers()
        clock.advance(to: 26)
        try #require(await released.wait(seconds: 5) == true)
        #expect(session.startupAuthorizationExpired)
        // Expire the initial-load wait only after the 25-second wake. The injected deadline
        // and wake clock avoid real sleeps while the same physical index load remains held.
        clock.advance(to: 30)
        let manager = DownloadManager(appModel: AppModel(identity: PlatformClientIdentity.make(
            clientIdentifier: "expired-wake-index-fixture")), store: store, session: session,
            backgroundCompletionRegistry: registry, registerForBackgroundEvents: false,
            startupIndexDeadline: { .after(0) })
        #expect(await manager.awaitStartupRecoveryForTesting() == false)
        guard case .blocked = manager.startupRecoveryState else {
            Issue.record("The initial-load deadline must block startup after wake expiry"); return
        }
        #expect(manager.records.isEmpty)
        #expect(!manager.hasPlayableOfflineContent)
        gate.release.signal()
        await manager.startupIndexObservationTask?.value
        await manager.offlineAvailabilityCache.worker?.value
        #expect(manager.records.map(\.ratingKey) == [key.ratingKey])
        #expect(manager.offlineLibrarySnapshot.rows.map(\.id) == [key.ratingKey])
        #expect(manager.hasPlayableOfflineContent)
        #expect(!manager.offlineAvailabilityIsResolving)
        #expect(manager.offlineIndexAccess == .admissionBlockedReadable)
        #expect(!manager.admission.recoveryComplete)
        #expect(!session.startupAdmissionIsActiveForTesting)
        #expect(manager.startupActivationSubmissionCountForTesting == 0)
        #expect(constructions.withLock { $0 } == 0)
        #expect(probes.withLock { $0 } == 0)
        #expect(session.revalidateCompletedDownload(ratingKey: key.ratingKey,
            validationLabel: "expired_wake_pin") == .deferredForBackgroundWake)
        let refill = f.record("refill", ratingKey: "plex:refill", filename: "refill.mp4")
        let refillKey = DownloadAttemptKey(ratingKey: refill.ratingKey, attemptID: refill.attemptID!)
        try #require(store.createAttemptOwnedRecord(refill, attemptID: refillKey.attemptID) == .committed(refillKey))
        try #require(store.attemptWorkingFileURL(for: refillKey) != nil)
        session.onRangeRequestNeeded = { _, _, _ in refills.withLock { $0 += 1 } }
        session.continueRangeAfterBodyForTesting(refillKey, partialSize: 3)
        #expect(refills.withLock { $0 } == 0)
        #expect(probes.withLock { $0 } == 0)
        if newWake {
            let authorized = P6Acknowledgement<Bool>()
            manager.startupActivationDecisionForTesting = { authorized.signal(true) }
            registry.store(identifier: BackgroundDownloadSession.identifier) {}
            try #require(await authorized.wait(seconds: 5) == true)
        } else {
            manager.noteAppSceneRecovery(.aggregateSceneBecameActive)
        }
        #expect(await manager.awaitStartupRecoveryForTesting())
        #expect(manager.startupRecoveryState == .ready)
        #expect(session.startupAdmissionIsActiveForTesting)
        #expect(manager.startupActivationSubmissionCountForTesting == 1)
        #expect(constructions.withLock { $0 } == 1)
        session.continueRangeAfterBodyForTesting(refillKey, partialSize: 3)
        #expect(refills.withLock { $0 } == 1)
    }

    @Test(arguments: [false, true]) @MainActor
    func lateInitialCompletionCannotOverwriteANewerReprobe(expiredWake: Bool) async throws {
        let f = try P6Fixture()
        let index = f.directory.appendingPathComponent("index.json")
        try Data("invalid".utf8).write(to: index)
        let initial = StartupIndexReadGate()
        let retry = StartupIndexReadGate()
        defer { initial.release.signal(); retry.release.signal() }
        let reads = Mutex(0)
        let store = DownloadStore(baseDirectory: f.directory, indexPersistence: .init(read: { url in
            let number = reads.withLock { $0 += 1; return $0 }
            if number == 1 { initial.hold(); return Data("invalid".utf8) }
            retry.hold()
            return try Data(contentsOf: url)
        }, atomicWrite: { data, url in
            try DownloadIndexFileCommitter().commit(data, to: url)
        }), startupOnWorker: true)
        try #require(await p6Signal(initial.entered))
        let clock = P6WakeClock()
        let session = BackgroundDownloadSession(store: store, protocolClasses: [], wakeClockHooks: clock.hooks,
            releaseBackgroundCompletion: { _ in })
        defer { session.invalidateInjectedSessionForTesting() }
        if expiredWake {
            session.noteBackgroundCompletionHandlerStored(identifier: BackgroundDownloadSession.identifier)
            try clock.requireWakeTimers()
            clock.advance(to: 30)
            #expect(session.startupAuthorizationExpired)
        }
        let manager = DownloadManager(appModel: AppModel(identity: PlatformClientIdentity.make(
            clientIdentifier: "generation-fixture")), store: store, session: session,
            registerForBackgroundEvents: false, startupIndexDeadline: { .after(0) })
        #expect(await manager.awaitStartupRecoveryForTesting() == false)
        let old = manager.startupIndexObservationTask
        manager.retryDownloadStartupRecovery()
        try Data(#"{"schemaVersion":5,"rows":[]}"#.utf8).write(to: index)
        let availabilityBeforeOldCompletion = manager.offlineAvailabilityCache.value
        initial.release.signal()
        try #require(await p6Signal(retry.entered))
        await old?.value
        #expect(manager.startupRecoveryState == .preparing)
        #expect(manager.startupActivationSubmissionCountForTesting == 0)
        #expect(manager.records.isEmpty)
        #expect(manager.offlineLibrarySnapshot.rows.isEmpty)
        #expect(manager.offlineAvailabilityCache.value == availabilityBeforeOldCompletion)
        retry.release.signal()
        if expiredWake {
            await manager.startupIndexObservationTask?.value
            #expect(!session.startupAdmissionIsActiveForTesting)
            #expect(manager.startupActivationSubmissionCountForTesting == 0)
            manager.noteAppSceneRecovery(.aggregateSceneBecameActive)
        }
        #expect(await manager.awaitStartupRecoveryForTesting())
        #expect(manager.startupRecoveryState == .ready)
    }

    @Test func offlineEmptyStateWaitsForStartupInsteadOfClaimingAnEmptyLibrary() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Labstream/Capabilities/Downloads/Core/OfflineLibraryView.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let start = try #require(text.range(of: "private func offlineRowsOrEmpty("))
        let emptyMessage = try #require(text.range(of: "\"No Offline Downloads\"", range: start.upperBound..<text.endIndex))
        let branch = text[start.upperBound..<emptyMessage.lowerBound]
        // Pin the actual empty-state branch's observation dependency and loading presentation.
        #expect(branch.contains("manager.startupRecoveryState == .preparing"))
        #expect(branch.contains("ProgressView("))
    }

    @Test @MainActor
    func missingIndexIsUnresolvedUntilWorkerFinishes() async throws {
        let f = try P6Fixture()
        let gate = StartupIndexReadGate()
        defer { gate.release.signal() }
        let writes = Mutex(0)
        let store = DownloadStore(baseDirectory: f.directory, indexPersistence: .init { data, url in
            writes.withLock { $0 += 1 }
            try DownloadIndexFileCommitter().commit(data, to: url)
        }, startupOnWorker: true, startupRepairWillBegin: { gate.hold() })
        try #require(await p6Signal(gate.entered))
        #expect(store.startupIndexProbe != .missing)
        #expect(store.startupIndexAdmission() != .current)
        let added = f.record(status: .paused)
        #expect(store.createAttemptOwnedRecord(added, attemptID: added.attemptID!)
            != .committed(.init(ratingKey: added.ratingKey, attemptID: added.attemptID!)))
        store.upsert(added)
        _ = store.stampSchemaV5()
        #expect(store.applySeasonPlanAtomically(newRecords: [f.record("season", status: .queued,
            ratingKey: "plex:season", filename: "season.mp4")], retryAttempts: []) == .staleInput)
        #expect(writes.withLock { $0 } == 0)
        #expect(!FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("index.json").path))
        gate.release.signal()
        #expect(await store.resolve(try #require(store.initialStartupSubmission), deadline: .after(5)) == .observed(.current))
        #expect(store.startupIndexProbe == .missing)
        #expect(store.records.isEmpty)
    }
}

private final class StartupIndexReadGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let held = Mutex(false)
    var isHeld: Bool { held.withLock { $0 } }
    func hold() {
        held.withLock { $0 = true }
        entered.signal()
        // Independent watchdog makes the synchronous negative control fail rather than hang.
        _ = release.wait(timeout: .now() + 10)
        held.withLock { $0 = false }
    }
}
#endif
