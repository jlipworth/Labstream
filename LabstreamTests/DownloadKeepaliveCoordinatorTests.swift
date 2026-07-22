import Foundation
import PMSKit
import Testing
@testable import Labstream

#if !os(tvOS)
@Suite("Download keepalive coordinator")
struct DownloadKeepaliveCoordinatorTests {
    @Test @MainActor
    func cancellingExactAttemptDoesNotCancelReplacementForSameRatingKey() async throws {
        let fixture = try Fixture("exact-cancel")
        defer { fixture.remove() }
        let coordinator = fixture.coordinator
        let attemptA = key("attempt-A")
        let attemptB = key("attempt-B")
        let heldA = HeldKeepaliveTask()
        let heldB = HeldKeepaliveTask()

        coordinator.registerTaskForTesting(heldA.task(), for: attemptA, backend: .jellyfin)
        coordinator.registerTaskForTesting(heldB.task(), for: attemptB, backend: .jellyfin)
        #expect(await waitUntil { heldA.started && heldB.started })

        coordinator.cancel(attemptA)

        #expect(await waitUntil { heldA.cancelled })
        #expect(!heldB.cancelled)
        #expect(coordinator.activeCount(for: .jellyfin) == 1)
        coordinator.cancel(attemptB)
        #expect(await waitUntil { heldB.cancelled })
    }

    @Test @MainActor
    func staleGenerationCannotRemoveReplacementTask() async throws {
        let fixture = try Fixture("generation-cas")
        defer { fixture.remove() }
        let coordinator = fixture.coordinator
        let attempt = key("attempt-A")
        let oldTask = HeldKeepaliveTask()
        let replacementTask = HeldKeepaliveTask()
        let oldGeneration = try #require(coordinator.registerTaskForTesting(
            oldTask.task(), for: attempt, backend: .jellyfin))
        #expect(await waitUntil { oldTask.started })
        let replacementHandle = replacementTask.task()
        let replacementGeneration = try #require(coordinator.registerTaskForTesting(
            replacementHandle, for: attempt, backend: .jellyfin))
        #expect(await waitUntil { oldTask.cancelled && replacementTask.started })

        coordinator.removeTaskForTesting(
            for: attempt, backend: .jellyfin, completingGeneration: oldGeneration)

        #expect(coordinator.activeCount(for: .jellyfin) == 1)
        coordinator.removeTaskForTesting(
            for: attempt, backend: .jellyfin, completingGeneration: replacementGeneration)
        #expect(coordinator.activeCount(for: .jellyfin) == 0)
        replacementHandle.cancel()
        #expect(await waitUntil { replacementTask.cancelled })
    }

    @Test @MainActor
    func backendTaskRegistriesRemainIndependent() async throws {
        let fixture = try Fixture("backend-slots")
        defer { fixture.remove() }
        let coordinator = fixture.coordinator
        let attempt = key("attempt-A")
        let jellyfin = HeldKeepaliveTask()
        let emby = HeldKeepaliveTask()

        coordinator.registerTaskForTesting(jellyfin.task(), for: attempt, backend: .jellyfin)
        coordinator.registerTaskForTesting(emby.task(), for: attempt, backend: .emby)
        #expect(await waitUntil { jellyfin.started && emby.started })
        #expect(coordinator.activeCount(for: .jellyfin) == 1)
        #expect(coordinator.activeCount(for: .emby) == 1)
        #expect(coordinator.activeCount(for: .plex) == 0)

        coordinator.cancel(attempt)
        #expect(await waitUntil { jellyfin.cancelled && emby.cancelled })
        #expect(coordinator.activeCount(for: .jellyfin) == 0)
        #expect(coordinator.activeCount(for: .emby) == 0)
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let coordinator: DownloadKeepaliveCoordinator

        init(_ label: String) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("DownloadKeepaliveCoordinatorTests-\(label)-\(UUID().uuidString)",
                                        isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let store = DownloadStore(baseDirectory: directory)
            let appModel = AppModel(identity: PlatformClientIdentity.make(
                clientIdentifier: "keepalive-coordinator-tests"))
            coordinator = DownloadKeepaliveCoordinator(appModel: appModel, store: store)
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func key(_ attempt: String) -> DownloadAttemptKey {
        DownloadAttemptKey(
            ratingKey: "jellyfin:item",
            attemptID: DownloadAttemptID(rawValue: attempt)!)
    }

    private func waitUntil(
        attempts: Int = 100,
        _ predicate: @escaping @Sendable () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }
}

private final class HeldKeepaliveTask: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var didCancel = false

    var started: Bool { lock.withLock { didStart } }
    var cancelled: Bool { lock.withLock { didCancel } }

    func task() -> Task<Void, Never> {
        Task { [self] in
            lock.withLock { didStart = true }
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                lock.withLock { didCancel = true }
            }
        }
    }
}
#endif
