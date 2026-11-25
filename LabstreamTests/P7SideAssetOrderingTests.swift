#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

@Suite("P7 ordered side work", .downloadTestFiles, .serialized)
@MainActor
struct P7SideAssetOrderingTests {
    @Test(arguments: [false, true], [false, true])
    func lateParkCannotOvertakeResumeOrCancel(fetchEntry: Bool, cancel: Bool) async throws {
        let f = try await P7PlaybackFixture(status: .complete)
        let owner = DownloadManager.sideAssetOwner(for: f.key)
        let entered = P6Acknowledgement<Bool>()
        let release = P6Acknowledgement<Bool>()
        let oldDelivered = P6Acknowledgement<Bool>()
        let newDelivered = P6Acknowledgement<Bool>()
        f.manager.optionalSideAssetControlWillDeliver = { command, candidate, isFetch in
            if candidate == owner, command == .park(true), isFetch == fetchEntry {
                entered.signal(true)
                _ = await release.wait()
            }
        }
        f.manager.optionalSideAssetControlDidDeliver = { command, candidate, _ in
            if candidate == owner {
                if command == .park(true) { oldDelivered.signal(true) }
                else { newDelivered.signal(true) }
            }
        }
        var fetch: Task<Data, any Error>?
        if fetchEntry {
            f.manager.setQueuePausedForTesting(true)
            let source = try #require(f.store.sideAssetSourceIdentity(for: f.key))
            fetch = Task { try await f.manager.fetchOptionalSideAsset(
                URLRequest(url: URL(string: "https://media.invalid/fixture")!),
                // Not the poster: its fetch has its own owner that a pause never parks.
                for: f.key, source: source, kind: .chapterImages) }
        } else {
            f.manager.setOptionalSideAssetHydrationParked(true, for: f.key)
        }
        _ = await entered.wait()
        if cancel { f.manager.cancelOptionalSideAssetHydration(for: f.key) }
        else {
            f.manager.setQueuePausedForTesting(false)
            f.manager.setOptionalSideAssetHydrationParked(false, for: f.key)
        }
        _ = await newDelivered.wait()
        // Another exact owner does not wait on the held owner's command.
        let other = SideAssetOwner(rawValue: "unrelated")
        await f.manager.sideAssetFetchCoordinator.setParked(false, for: other)
        let otherData = try await f.manager.sideAssetFetchCoordinator.fetch(
            origin: .init(rawValue: "fixture-origin"), owner: other,
            requestKey: .init(rawValue: "fixture-request")) { Data([1]) }
        #expect(otherData == Data([1]))
        release.signal(true)
        _ = await oldDelivered.wait()
        let parked = await f.manager.sideAssetFetchCoordinator.isParkedForP7Testing(owner)
        do { #expect(!parked) }
        fetch?.cancel()
        await f.manager.sideAssetFetchCoordinator.cancel(owner: owner)
        if let fetch { _ = await fetch.result }
        f.manager.optionalSideAssetControlWillDeliver = nil
        f.manager.optionalSideAssetControlDidDeliver = nil
        await f.finish()
    }
    @Test func posterFetchIsNotParkedByAPausedQueue() async throws {
        let f = try await P7PlaybackFixture(status: .complete)
        let attemptOwner = DownloadManager.sideAssetOwner(for: f.key)
        let posterOwner = DownloadManager.posterSideAssetOwner(for: f.key)
        let parkedAttempt = P6Acknowledgement<Bool>()
        f.manager.optionalSideAssetControlDidDeliver = { command, candidate, _ in
            if candidate == attemptOwner, command == .park(true) { parkedAttempt.signal(true) }
        }
        f.manager.setQueuePausedForTesting(true)
        let source = try #require(f.store.sideAssetSourceIdentity(for: f.key))
        let poster = Task { try await f.manager.fetchOptionalSideAsset(
            URLRequest(url: URL(string: "https://media.invalid/poster")!),
            for: f.key, source: source, kind: .poster) }
        // The poster request reaches the transport (and fails on the invalid host) while paused.
        _ = await poster.result
        var posterParked = await f.manager.sideAssetFetchCoordinator.isParkedForP7Testing(posterOwner)
        #expect(!posterParked)
        // Any other payload of the same attempt is still parked by the pause.
        let chapters = Task { try await f.manager.fetchOptionalSideAsset(
            URLRequest(url: URL(string: "https://media.invalid/chapter")!),
            for: f.key, source: source, kind: .chapterImages) }
        _ = await parkedAttempt.wait()
        let attemptParked = await f.manager.sideAssetFetchCoordinator.isParkedForP7Testing(attemptOwner)
        #expect(attemptParked)
        posterParked = await f.manager.sideAssetFetchCoordinator.isParkedForP7Testing(posterOwner)
        #expect(!posterParked)
        chapters.cancel()
        await f.manager.sideAssetFetchCoordinator.cancel(owner: attemptOwner)
        _ = await chapters.result
        f.manager.setQueuePausedForTesting(false)
        f.manager.optionalSideAssetControlDidDeliver = nil
        await f.finish()
    }

    /// #482 (TLA+ S1): a cancel that keeps the row and attempt closes the poster's owner too. A
    /// later poster fetch must reopen it rather than throw `CancellationError` uncharged for the
    /// rest of the launch.
    @Test func posterFetchReopensAnOwnerAKeptAttemptCancelClosed() async throws {
        let f = try await P7PlaybackFixture(status: .complete)
        let posterOwner = DownloadManager.posterSideAssetOwner(for: f.key)
        let cancelled = P6Acknowledgement<Bool>()
        let registered = P6Acknowledgement<Bool>()
        f.manager.optionalSideAssetControlDidDeliver = { command, candidate, isFetch in
            guard candidate == posterOwner else { return }
            if command == .cancel { cancelled.signal(true) }
            if command == .park(false), isFetch { registered.signal(true) }
        }
        f.manager.cancelOptionalSideAssetHydration(for: f.key)
        #expect(await cancelled.wait(seconds: 10) == true)
        let source = try #require(f.store.sideAssetSourceIdentity(for: f.key))
        let poster = Task { try await f.manager.fetchOptionalSideAsset(
            URLRequest(url: URL(string: "https://media.invalid/poster")!),
            for: f.key, source: source, kind: .poster) }
        #expect(await registered.wait(seconds: 10) == true)
        // The request reaches the transport (and fails on the invalid host); it is not refused
        // at the coordinator's entry by the cancelled owner.
        if case .failure(let error) = await poster.result {
            #expect(!(error is CancellationError))
        }
        f.manager.optionalSideAssetControlDidDeliver = nil
        await f.finish()
    }

    /// #483 (TLA+ S2): behind Pause All a completed row's fetch entry parks the attempt's owner.
    /// Resume All must unpark it: the row's tasks stay registered, so the repair pass starts
    /// nothing that would.
    @Test func resumeAllUnparksACompletedRowParkedBehindPauseAll() async throws {
        let f = try await P7PlaybackFixture(status: .complete)
        let owner = DownloadManager.sideAssetOwner(for: f.key)
        let parked = P6Acknowledgement<Bool>()
        let unparked = P6Acknowledgement<Bool>()
        f.manager.optionalSideAssetControlDidDeliver = { command, candidate, isFetch in
            guard candidate == owner else { return }
            if command == .park(true), isFetch { parked.signal(true) }
            // Only Resume All's own command, not a fetch entry of a new repair task.
            if command == .park(false), !isFetch { unparked.signal(true) }
        }
        f.manager.setQueuePausedForTesting(true)
        let source = try #require(f.store.sideAssetSourceIdentity(for: f.key))
        let chapters = Task { try await f.manager.fetchOptionalSideAsset(
            URLRequest(url: URL(string: "https://media.invalid/chapter")!),
            for: f.key, source: source, kind: .chapterImages) }
        #expect(await parked.wait(seconds: 10) == true)
        let parkedBehindPause = await f.manager.sideAssetFetchCoordinator.isParkedForP7Testing(owner)
        #expect(parkedBehindPause)
        f.manager.resumeQueue()
        #expect(await unparked.wait(seconds: 10) == true)
        let stillParked = await f.manager.sideAssetFetchCoordinator.isParkedForP7Testing(owner)
        #expect(!stillParked)
        chapters.cancel()
        await f.manager.sideAssetFetchCoordinator.cancel(owner: owner)
        _ = await chapters.result
        f.manager.optionalSideAssetControlDidDeliver = nil
        await f.finish()
    }

    @Test func cancellationFencesOldRegistrationButAllowsLaterRepairPass() async throws {
        let coordinator = SideAssetFetchCoordinator()
        let owner = SideAssetOwner(rawValue: "fixture-owner")
        await coordinator.applyDownloadControl(.cancel, owner: owner, version: 2)
        await coordinator.applyDownloadControl(.park(true), owner: owner, version: 1, registration: true)
        await coordinator.applyDownloadControl(.park(false), owner: owner, version: 3)
        await #expect(throws: CancellationError.self) {
            try await coordinator.fetch(origin: .init(rawValue: "fixture-origin"), owner: owner,
                requestKey: .init(rawValue: "cancelled")) { Data([1]) }
        }
        // Completion releases optional work too; a later foreground repair is a new admission.
        await coordinator.applyDownloadControl(.park(false), owner: owner, version: 4, registration: true)
        #expect(try await coordinator.fetch(origin: .init(rawValue: "fixture-origin"), owner: owner,
            requestKey: .init(rawValue: "repair")) { Data([2]) } == Data([2]))
    }

}
#endif
