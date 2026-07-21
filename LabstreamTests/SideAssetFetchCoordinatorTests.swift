import Foundation
import PMSKit
import XCTest
@testable import Labstream

final class SideAssetFetchCoordinatorTests: XCTestCase {
    func testRequestGatewayPacesPlayerChapterBurstByOrigin() async throws {
        let clock = AdvancingSideAssetClock()
        let recorder = SideAssetStartRecorder(clock: clock)
        let coordinator = SideAssetFetchCoordinator(
            policy: .init(maximumRequestStartsPerSecond: 2, maximumConcurrentRequests: 2),
            clock: clock.dependency
        )
        let owner = SideAssetOwner(rawValue: "player-chapter-thumbnails")

        let tasks = (0..<48).map { index in
            Task {
                var request = URLRequest(url: URL(string: "https://emby.example/emby/Items/50388/Images/Chapter/\(index)")!)
                request.setValue("secret", forHTTPHeaderField: "X-Emby-Token")
                return try await coordinator.fetch(request: request, owner: owner) {
                    await recorder.record(owner: owner.rawValue)
                }
            }
        }
        for task in tasks { _ = try await task.value }

        let admissions = await coordinator.recordedAdmissionsForTesting()
        XCTAssertEqual(admissions.count, 48)
        XCTAssertTrue(zip(admissions, admissions.dropFirst()).allSatisfy {
            $1.timeNanoseconds - $0.timeNanoseconds >= 500_000_000
        })
    }

    func testTwoDownloadIncidentIsGloballyPacedAndFair() async throws {
        let clock = AdvancingSideAssetClock()
        let recorder = SideAssetStartRecorder(clock: clock)
        let coordinator = SideAssetFetchCoordinator(
            policy: .init(maximumRequestStartsPerSecond: 2, maximumConcurrentRequests: 2),
            clock: clock.dependency
        )
        let origin = SideAssetOrigin(rawValue: "origin")
        let first = SideAssetOwner(rawValue: "first")
        let second = SideAssetOwner(rawValue: "second")
        await coordinator.setParked(true, for: first)
        await coordinator.setParked(true, for: second)

        var tasks: [Task<Data, any Error>] = []
        for index in 0..<32 {
            tasks.append(Task {
                try await coordinator.fetch(
                    origin: origin,
                    owner: first,
                    requestKey: .init(rawValue: "first-\(index)")
                ) { await recorder.record(owner: "first") }
            })
            await Task.yield()
        }
        for index in 0..<52 {
            tasks.append(Task {
                try await coordinator.fetch(
                    origin: origin,
                    owner: second,
                    requestKey: .init(rawValue: "second-\(index)")
                ) { await recorder.record(owner: "second") }
            })
            await Task.yield()
        }

        let countWhileParked = await recorder.count
        XCTAssertEqual(countWhileParked, 0)
        await coordinator.setParked(false, for: first)
        await coordinator.setParked(false, for: second)
        for task in tasks { _ = try await task.value }

        let admissions = await coordinator.recordedAdmissionsForTesting()
        XCTAssertEqual(admissions.count, 84)
        XCTAssertTrue(zip(admissions, admissions.dropFirst()).allSatisfy {
            $1.timeNanoseconds - $0.timeNanoseconds >= 500_000_000
        })
        XCTAssertEqual(Array(admissions.prefix(64).map(\.owner.rawValue)),
                       (0..<64).map { $0.isMultiple(of: 2) ? "first" : "second" })
    }

    func testConcurrencyIsBoundedAcrossOwnersAtOneOrigin() async throws {
        let clock = AdvancingSideAssetClock()
        let gate = SideAssetGate()
        let recorder = SideAssetStartRecorder(clock: clock)
        let coordinator = SideAssetFetchCoordinator(
            policy: .init(maximumRequestStartsPerSecond: 100, maximumConcurrentRequests: 2),
            clock: clock.dependency
        )
        let tasks = (0..<5).map { index in
            Task {
                try await coordinator.fetch(
                    origin: .init(rawValue: "origin"),
                    owner: .init(rawValue: "owner-\(index % 2)"),
                    requestKey: .init(rawValue: "request-\(index)")
                ) {
                    await recorder.begin(owner: "owner")
                    await gate.wait()
                    await recorder.end()
                    return Data([1])
                }
            }
        }
        await waitUntil { await recorder.count == 2 }
        let maximumWhileBlocked = await recorder.maximumActive
        XCTAssertEqual(maximumWhileBlocked, 2)
        await gate.releaseAll()
        for task in tasks { _ = try await task.value }
        let finalMaximum = await recorder.maximumActive
        XCTAssertEqual(finalMaximum, 2)
    }

    func testIdenticalInFlightRequestIsCoalesced() async throws {
        let clock = AdvancingSideAssetClock()
        let gate = SideAssetGate()
        let calls = SideAssetCounter()
        let coordinator = SideAssetFetchCoordinator(clock: clock.dependency)
        let origin = SideAssetOrigin(rawValue: "origin")
        let request = SideAssetRequestKey(rawValue: "same")
        let first = Task {
            try await coordinator.fetch(origin: origin, owner: .init(rawValue: "a"), requestKey: request) {
                await calls.increment()
                await gate.wait()
                return Data([7])
            }
        }
        await waitUntil { await calls.value == 1 }
        let second = Task {
            try await coordinator.fetch(origin: origin, owner: .init(rawValue: "b"), requestKey: request) {
                XCTFail("coalesced operation must not run")
                return Data()
            }
        }
        await waitUntil {
            await coordinator.waiterCountForTesting(origin: origin, requestKey: request) == 2
        }
        await gate.releaseAll()
        let firstData = try await first.value
        let secondData = try await second.value
        let callCount = await calls.value
        XCTAssertEqual(firstData, Data([7]))
        XCTAssertEqual(secondData, Data([7]))
        XCTAssertEqual(callCount, 1)
    }

    func testTaskCancellationWinsWhenSuccessfulCompletionRacesCancellation() async {
        // The operation deliberately ignores cooperative cancellation and returns success at the
        // same boundary where the caller is cancelled. Actor serialization prevents a double
        // resume, while fetch's post-resume check makes the externally observed result stable
        // regardless of whether completion or cancelWaiter reaches the coordinator first.
        for iteration in 0..<100 {
            let clock = AdvancingSideAssetClock()
            let gate = SideAssetGate()
            let calls = SideAssetCounter()
            let coordinator = SideAssetFetchCoordinator(clock: clock.dependency)
            let task = Task {
                try await coordinator.fetch(
                    origin: .init(rawValue: "origin"),
                    owner: .init(rawValue: "owner"),
                    requestKey: .init(rawValue: "race-\(iteration)")
                ) {
                    await calls.increment()
                    await gate.wait()
                    return Data([7])
                }
            }

            await waitUntil { await calls.value == 1 }
            task.cancel()
            await gate.releaseAll()

            do {
                _ = try await task.value
                XCTFail("cancelled waiter must not observe a successful completion")
            } catch is CancellationError {
                // Expected.
            } catch {
                XCTFail("expected CancellationError, got \(error)")
            }
            let indexedWaiters = await coordinator.waiterJobIndexCountForTesting()
            XCTAssertEqual(indexedWaiters, 0)
        }
    }

    func testWaiterJobIndexTracksCoalescedCancellationAndCompletion() async throws {
        let clock = AdvancingSideAssetClock()
        let gate = SideAssetGate()
        let calls = SideAssetCounter()
        let coordinator = SideAssetFetchCoordinator(clock: clock.dependency)
        let origin = SideAssetOrigin(rawValue: "origin")
        let request = SideAssetRequestKey(rawValue: "shared-index")

        let cancelled = Task {
            try await coordinator.fetch(
                origin: origin, owner: .init(rawValue: "cancelled"), requestKey: request
            ) {
                await calls.increment()
                await gate.wait()
                return Data([3])
            }
        }
        await waitUntil { await calls.value == 1 }
        let survivor = Task {
            try await coordinator.fetch(
                origin: origin, owner: .init(rawValue: "survivor"), requestKey: request
            ) {
                XCTFail("coalesced operation must not run")
                return Data()
            }
        }
        await waitUntil {
            await coordinator.waiterJobIndexCountForTesting() == 2
        }

        cancelled.cancel()
        await waitUntil {
            await coordinator.waiterJobIndexCountForTesting() == 1
        }
        do {
            _ = try await cancelled.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}

        await gate.releaseAll()
        let survivorData = try await survivor.value
        XCTAssertEqual(survivorData, Data([3]))
        let finalIndexCount = await coordinator.waiterJobIndexCountForTesting()
        XCTAssertEqual(finalIndexCount, 0)
    }

    func testExistingNonemptyFileBypassesNetwork() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([4, 2]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let calls = SideAssetCounter()
        let coordinator = SideAssetFetchCoordinator(clock: AdvancingSideAssetClock().dependency)
        let data = try await coordinator.fetch(
            origin: .init(rawValue: "origin"),
            owner: .init(rawValue: "owner"),
            requestKey: .init(rawValue: "request"),
            existingFile: file
        ) {
            await calls.increment()
            return Data([9])
        }
        XCTAssertEqual(data, Data([4, 2]))
        let callCount = await calls.value
        XCTAssertEqual(callCount, 0)
    }

    func testParkPreventsStartUntilResumeAndCancelRemovesQueuedOwnerWork() async throws {
        let clock = AdvancingSideAssetClock()
        let calls = SideAssetCounter()
        let coordinator = SideAssetFetchCoordinator(clock: clock.dependency)
        let owner = SideAssetOwner(rawValue: "owner")
        await coordinator.setParked(true, for: owner)
        let resumed = Task {
            try await coordinator.fetch(
                origin: .init(rawValue: "origin"), owner: owner, requestKey: .init(rawValue: "resume")
            ) {
                await calls.increment()
                return Data([1])
            }
        }
        await Task.yield()
        let countWhileParked = await calls.value
        XCTAssertEqual(countWhileParked, 0)
        await coordinator.setParked(false, for: owner)
        let resumedData = try await resumed.value
        XCTAssertEqual(resumedData, Data([1]))

        await coordinator.setParked(true, for: owner)
        let cancelled = Task {
            try await coordinator.fetch(
                origin: .init(rawValue: "origin"), owner: owner, requestKey: .init(rawValue: "cancel")
            ) { XCTFail("cancelled queued work must not start"); return Data() }
        }
        await Task.yield()
        await coordinator.cancel(owner: owner)
        do {
            _ = try await cancelled.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
    }

    func testParkedCoalescedOwnerDoesNotBlockActiveOwnerOrCancelSharedRequest() async throws {
        let clock = AdvancingSideAssetClock()
        let gate = SideAssetGate()
        let calls = SideAssetCounter()
        let coordinator = SideAssetFetchCoordinator(clock: clock.dependency)
        let parked = SideAssetOwner(rawValue: "parked")
        let active = SideAssetOwner(rawValue: "active")
        let request = SideAssetRequestKey(rawValue: "shared")
        await coordinator.setParked(true, for: parked)
        let first = Task {
            try await coordinator.fetch(
                origin: .init(rawValue: "origin"), owner: parked, requestKey: request
            ) {
                await calls.increment()
                await gate.wait()
                return Data([8])
            }
        }
        await Task.yield()
        let second = Task {
            try await coordinator.fetch(
                origin: .init(rawValue: "origin"), owner: active, requestKey: request
            ) { XCTFail("coalesced operation must not run"); return Data() }
        }
        await waitUntil { await calls.value == 1 }
        await coordinator.cancel(owner: parked)
        await gate.releaseAll()
        do {
            _ = try await first.value
            XCTFail("parked owner's waiter should be cancelled")
        } catch is CancellationError {}
        let secondData = try await second.value
        XCTAssertEqual(secondData, Data([8]))
        let callCount = await calls.value
        XCTAssertEqual(callCount, 1)
    }

    func testDifferentOriginsProgressIndependently() async throws {
        let clock = AdvancingSideAssetClock()
        let gate = SideAssetGate()
        let recorder = SideAssetStartRecorder(clock: clock)
        let coordinator = SideAssetFetchCoordinator(
            policy: .init(maximumRequestStartsPerSecond: 1, maximumConcurrentRequests: 1),
            clock: clock.dependency
        )
        let tasks = ["a", "b"].map { origin in
            Task {
                try await coordinator.fetch(
                    origin: .init(rawValue: origin), owner: .init(rawValue: origin),
                    requestKey: .init(rawValue: origin)
                ) {
                    await recorder.begin(owner: origin)
                    await gate.wait()
                    await recorder.end()
                    return Data([1])
                }
            }
        }
        await waitUntil { await recorder.count == 2 }
        let maximumActive = await recorder.maximumActive
        XCTAssertEqual(maximumActive, 2)
        await gate.releaseAll()
        for task in tasks { _ = try await task.value }
    }

    private func waitUntil(_ predicate: @escaping () async -> Bool) async {
        for _ in 0..<1_000 {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("condition was not reached")
    }
}

private final class AdvancingSideAssetClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    var now: UInt64 { lock.withLock { value } }

    var dependency: SideAssetCoordinatorClock {
        SideAssetCoordinatorClock(
            nowNanoseconds: { [self] in now },
            sleepUntilNanoseconds: { [self] deadline in
                lock.withLock { value = max(value, deadline) }
                await Task.yield()
            }
        )
    }
}

private actor SideAssetStartRecorder {
    struct Start: Equatable { let owner: String; let time: UInt64 }
    private let clock: AdvancingSideAssetClock
    private(set) var starts: [Start] = []
    private(set) var active = 0
    private(set) var maximumActive = 0
    var count: Int { starts.count }

    init(clock: AdvancingSideAssetClock) { self.clock = clock }

    func record(owner: String) -> Data {
        starts.append(.init(owner: owner, time: clock.now))
        return Data([1])
    }

    func begin(owner: String) {
        starts.append(.init(owner: owner, time: clock.now))
        active += 1
        maximumActive = max(maximumActive, active)
    }

    func end() { active -= 1 }
}

private actor SideAssetGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !open else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func releaseAll() {
        open = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor SideAssetCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

final class CompletedRowSideAssetRehydrateBudgetTests: XCTestCase {
    func testGivesUpPerRowKindAfterMaxAttemptsPerLaunch() {
        var budget = CompletedRowSideAssetRehydrateBudget()
        let max = CompletedRowSideAssetRehydrateBudget.maxAttemptsPerLaunch

        for _ in 0..<max {
            XCTAssertTrue(budget.canOffer(ratingKey: "row", kind: .poster))
            budget.recordAttempt(ratingKey: "row", kind: .poster)
        }
        // Exhausted: the permanently-missing poster stops being offered this launch.
        XCTAssertFalse(budget.canOffer(ratingKey: "row", kind: .poster))
    }

    func testGiveUpIsScopedToRowAndKind() {
        var budget = CompletedRowSideAssetRehydrateBudget()
        for _ in 0..<CompletedRowSideAssetRehydrateBudget.maxAttemptsPerLaunch {
            budget.recordAttempt(ratingKey: "row", kind: .poster)
        }
        XCTAssertFalse(budget.canOffer(ratingKey: "row", kind: .poster))
        // A different kind on the same row and the same kind on a different row keep their budget.
        XCTAssertTrue(budget.canOffer(ratingKey: "row", kind: .chapterImages))
        XCTAssertTrue(budget.canOffer(ratingKey: "other", kind: .poster))
    }
}

/// Pins WHEN the completed-row rehydrate scan charges the per-launch budget: only for passes that
/// actually dispatch fetch work. A trigger while the row's backend has no live session must not
/// burn the budget (previously each such pass charged every offerable kind while
/// `rehydrateMissingOptionalSideAssets` early-returned without fetching, so the asset could never
/// rehydrate once its backend became active again).
@MainActor
final class CompletedRowSideAssetRehydrateBudgetChargingTests: XCTestCase {
    func testTriggersWithoutLiveBackendSessionDoNotConsumeBudget() throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }

        // No Plex session configured on the AppModel: rehydrate cannot dispatch anything.
        for _ in 0..<(CompletedRowSideAssetRehydrateBudget.maxAttemptsPerLaunch * 2) {
            harness.manager.rehydrateMissingOptionalSideAssetsForCompletedRows(reason: "test_no_session")
        }
        XCTAssertTrue(harness.manager.completedRowSideAssetRehydrateBudget.canOffer(
            ratingKey: harness.ratingKey, kind: .poster))
    }

    func testDispatchedRehydratePassesStillExhaustBudget() throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }

        // A live matching Plex session makes each pass dispatch real (failing) fetch work, so the
        // bounded-retry intent is preserved: the budget still runs out for a permanently missing asset.
        harness.model.serverBaseURL = URL(string: "https://media.example.invalid")
        harness.model.serverToken = "not-a-real-token"
        for _ in 0..<CompletedRowSideAssetRehydrateBudget.maxAttemptsPerLaunch {
            XCTAssertTrue(harness.manager.completedRowSideAssetRehydrateBudget.canOffer(
                ratingKey: harness.ratingKey, kind: .poster))
            harness.manager.rehydrateMissingOptionalSideAssetsForCompletedRows(reason: "test_failing_fetch")
        }
        XCTAssertFalse(harness.manager.completedRowSideAssetRehydrateBudget.canOffer(
            ratingKey: harness.ratingKey, kind: .poster))
    }

    private struct Harness {
        let directory: URL
        let model: AppModel
        let manager: DownloadManager
        let session: BackgroundDownloadSession
        let ratingKey: String

        func tearDown() {
            session.invalidateInjectedSessionForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// One completed Plex row whose metadata references a poster that is not on disk, so the scan
    /// always sees `.poster` as a missing offerable kind.
    private func makeHarness() throws -> Harness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rehydrate-budget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // The manager reads the persisted queue-paused flag at init; the scan is a no-op while paused.
        UserDefaults.standard.set(false, forKey: "downloads.queuePaused")

        let store = DownloadStore(baseDirectory: directory)
        let ratingKey = "12345"
        let attemptID = try XCTUnwrap(DownloadAttemptID(rawValue: "attempt-\(ratingKey)"))
        let key = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptID)
        let record = DownloadRecord(
            ratingKey: ratingKey,
            attemptID: attemptID,
            title: "Test item",
            localURL: store.destinationURL(ratingKey: ratingKey, ext: "mp4"),
            bytes: 10,
            progress: 1,
            status: .complete,
            metadata: OfflineMetadata(
                ratingKey: ratingKey,
                title: "Test item",
                type: "movie",
                thumb: "/library/metadata/12345/thumb/1",
                sourcePartSize: 100,
                backendKind: .plex,
                backendBaseURLString: "https://media.example.invalid",
                backendServerID: nil,
                backendUserID: nil,
                resumeMode: .staticByteRange))
        XCTAssertEqual(store.createAttemptOwnedRecord(record, attemptID: attemptID), .committed(key))

        let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "rehydrate-budget"))
        let session = BackgroundDownloadSession(store: store, protocolClasses: [])
        let manager = DownloadManager(appModel: model, store: store, session: session,
                                      registerForBackgroundEvents: false)
        return Harness(directory: directory, model: model, manager: manager,
                       session: session, ratingKey: ratingKey)
    }
}
