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
        defer { coordinator.cancel(attemptA); coordinator.cancel(attemptB) }

        coordinator.registerTaskForTesting(heldA.task(), for: attemptA, backend: .jellyfin)
        coordinator.registerTaskForTesting(heldB.task(), for: attemptB, backend: .jellyfin)
        #expect(await heldA.waitUntilStarted())
        #expect(await heldB.waitUntilStarted())

        coordinator.cancel(attemptA)

        #expect(await heldA.waitUntilFinished())
        #expect(heldA.cancelled)
        #expect(!heldB.cancelled)
        #expect(coordinator.activeCount(for: .jellyfin) == 1)
        coordinator.cancel(attemptB)
        #expect(await heldB.waitUntilFinished())
        #expect(heldB.cancelled)
    }

    @Test @MainActor
    func staleGenerationCannotRemoveReplacementTask() async throws {
        let fixture = try Fixture("generation-cas")
        defer { fixture.remove() }
        let coordinator = fixture.coordinator
        let attempt = key("attempt-A")
        let oldTask = HeldKeepaliveTask()
        let replacementTask = HeldKeepaliveTask()
        defer { coordinator.cancel(attempt) }
        let oldGeneration = try #require(coordinator.registerTaskForTesting(
            oldTask.task(), for: attempt, backend: .jellyfin))
        #expect(await oldTask.waitUntilStarted())
        let replacementHandle = replacementTask.task()
        let replacementGeneration = try #require(coordinator.registerTaskForTesting(
            replacementHandle, for: attempt, backend: .jellyfin))
        #expect(await oldTask.waitUntilFinished())
        #expect(await replacementTask.waitUntilStarted())
        #expect(oldTask.cancelled)

        coordinator.removeTaskForTesting(
            for: attempt, backend: .jellyfin, completingGeneration: oldGeneration)

        #expect(coordinator.activeCount(for: .jellyfin) == 1)
        coordinator.removeTaskForTesting(
            for: attempt, backend: .jellyfin, completingGeneration: replacementGeneration)
        #expect(coordinator.activeCount(for: .jellyfin) == 0)
        replacementHandle.cancel()
        #expect(await replacementTask.waitUntilFinished())
        #expect(replacementTask.cancelled)
    }

    @Test @MainActor
    func backendTaskRegistriesRemainIndependent() async throws {
        let fixture = try Fixture("backend-slots")
        defer { fixture.remove() }
        let coordinator = fixture.coordinator
        let attempt = key("attempt-A")
        let jellyfin = HeldKeepaliveTask()
        let emby = HeldKeepaliveTask()
        defer { coordinator.cancel(attempt) }

        coordinator.registerTaskForTesting(jellyfin.task(), for: attempt, backend: .jellyfin)
        coordinator.registerTaskForTesting(emby.task(), for: attempt, backend: .emby)
        #expect(await jellyfin.waitUntilStarted())
        #expect(await emby.waitUntilStarted())
        #expect(coordinator.activeCount(for: .jellyfin) == 1)
        #expect(coordinator.activeCount(for: .emby) == 1)
        #expect(coordinator.activeCount(for: .plex) == 0)

        coordinator.cancel(attempt)
        #expect(await jellyfin.waitUntilFinished())
        #expect(await emby.waitUntilFinished())
        #expect(jellyfin.cancelled && emby.cancelled)
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


}

private final class HeldKeepaliveTask: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var didCancel = false
    private let startedEvent = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let finishedEvent = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

    func waitUntilStarted() async -> Bool { await waitForEvent(startedEvent.stream) }

    func waitUntilFinished() async -> Bool { await waitForEvent(finishedEvent.stream) }

    /// Completion signals establish ordering; this deadline only bounds a broken fixture.
    private func waitForEvent(_ stream: AsyncStream<Void>) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in stream { return true }
                return false
            }
            group.addTask {
                do { try await Task.sleep(for: .seconds(30)) } catch { return false }
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    var started: Bool { lock.withLock { didStart } }
    var cancelled: Bool { lock.withLock { didCancel } }

    func task() -> Task<Void, Never> {
        Task { [self] in
            lock.withLock { didStart = true }
            startedEvent.continuation.yield(())
            startedEvent.continuation.finish()
            defer {
                finishedEvent.continuation.yield(())
                finishedEvent.continuation.finish()
            }
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                lock.withLock { didCancel = true }
            }
        }
    }
}
#endif
