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
