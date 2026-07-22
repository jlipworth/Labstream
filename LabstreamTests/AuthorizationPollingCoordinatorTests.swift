import Foundation
import Testing
@testable import Labstream

@MainActor
struct AuthorizationPollingCoordinatorTests {
    @Test func staleFinishAndCancelCannotClearReplacementPoll() {
        var coordinator = AuthorizationPollingCoordinator()
        let firstOwner = UUID()
        let secondOwner = UUID()
        let firstTask = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        let secondTask = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }

        coordinator.install(ownerID: firstOwner,
                            plexPINIDs: [1, 2],
                            task: firstTask)
        #expect(coordinator.ownsPlexPINs([1, 2], ownerID: firstOwner))

        coordinator.install(ownerID: secondOwner,
                            plexPINIDs: [3, 4],
                            task: secondTask)

        #expect(firstTask.isCancelled)
        let staleFinish = coordinator.finish(ownerID: firstOwner)
        let staleCancel = coordinator.cancel(ownerID: firstOwner)
        #expect(!staleFinish)
        #expect(!staleCancel)
        #expect(coordinator.ownsPlexPINs([3, 4], ownerID: secondOwner))
        #expect(!coordinator.isIdle)

        let replacementFinish = coordinator.finish(ownerID: secondOwner)
        #expect(replacementFinish)
        #expect(coordinator.isIdle)
        secondTask.cancel()
    }

    @Test func exactOwnerCancelCancelsTaskAndClearsPINMetadata() {
        var coordinator = AuthorizationPollingCoordinator()
        let owner = UUID()
        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        coordinator.install(ownerID: owner, plexPINIDs: [7, 8], task: task)

        let didCancel = coordinator.cancel(ownerID: owner)
        #expect(didCancel)
        #expect(task.isCancelled)
        #expect(coordinator.isIdle)
        #expect(!coordinator.ownsPlexPINs([7, 8], ownerID: owner))
    }
}
