import Foundation
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
