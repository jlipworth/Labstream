#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

@Suite("P7 ordered side work", .serialized)
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
                for: f.key, source: source, kind: .poster) }
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
