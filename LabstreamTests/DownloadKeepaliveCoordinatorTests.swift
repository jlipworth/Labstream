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

    /// B60 / IC-4: a queued row whose exact attempt has no tracked transfer must not get a
    /// keepalive from reconcile, for either backend.
    @Test(arguments: [DownloadBackendKind.jellyfin, .emby]) @MainActor
    func reconcileStartsKeepaliveOnlyForTrackedTransfer(backend: DownloadBackendKind) throws {
        let fixture = try Fixture("tracking-gate-\(backend.rawValue)")
        defer { fixture.remove() }
        fixture.signIn(backend)
        let coordinator = fixture.coordinator
        let record = Self.keepaliveRecord(backend: backend, attempt: "attempt-A")
        let attempt = try #require(record.attemptID.map {
            DownloadAttemptKey(ratingKey: record.ratingKey, attemptID: $0)
        })
        defer { coordinator.cancel(attempt) }

        coordinator.reconcile(records: [record])
        #expect(coordinator.activeCount(for: backend) == 0)
        #expect(fixture.trackingQueries.contains(attempt))

        fixture.trackedAttempts.insert(attempt)
        coordinator.reconcile(records: [record])
        #expect(coordinator.activeCount(for: backend) == 1)
    }

    /// The gate is exact-attempt: tracking a replacement attempt does not start one for the old.
    @Test @MainActor
    func reconcileGateIsExactAttempt() throws {
        let fixture = try Fixture("tracking-gate-exact")
        defer { fixture.remove() }
        fixture.signIn(.jellyfin)
        let coordinator = fixture.coordinator
        let stale = Self.keepaliveRecord(backend: .jellyfin, attempt: "attempt-A")
        fixture.trackedAttempts.insert(key("attempt-B"))
        defer { coordinator.cancel(key("attempt-A")); coordinator.cancel(key("attempt-B")) }

        coordinator.reconcile(records: [stale])
        #expect(coordinator.activeCount(for: .jellyfin) == 0)
    }

    private static func keepaliveRecord(backend: DownloadBackendKind,
                                        attempt: String) -> DownloadRecord {
        let ratingKey = DownloadRecordIdentity.recordKey(for: "item", backend: backend)
        let lane: DownloadLane = backend == .emby ? .compatibleRemux : .optimize
        let metadata = OfflineMetadata(ratingKey: ratingKey,
                                       title: "Title",
                                       type: "movie",
                                       duration: 12_345,
                                       backendKind: backend,
                                       mediaSourceID: "source",
                                       playSessionID: "session",
                                       downloadLane: lane,
                                       resumeMode: .liveForwardOnly)
        return DownloadRecord(ratingKey: ratingKey,
                              attemptID: DownloadAttemptID(rawValue: attempt)!,
                              title: "Title",
                              localURL: URL(fileURLWithPath: "/tmp/labstream-keepalive-gate.mp4"),
                              status: .queued,
                              metadata: metadata)
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let appModel: AppModel
        let coordinator: DownloadKeepaliveCoordinator
        private let tracking = TrackingProbe()
        var trackedAttempts: Set<DownloadAttemptKey> {
            get { tracking.tracked }
            set { tracking.tracked = newValue }
        }
        var trackingQueries: Set<DownloadAttemptKey> { tracking.queries }

        init(_ label: String) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("DownloadKeepaliveCoordinatorTests-\(label)-\(UUID().uuidString)",
                                        isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let store = DownloadStore(baseDirectory: directory)
            let appModel = AppModel(identity: PlatformClientIdentity.make(
                clientIdentifier: "keepalive-coordinator-tests"))
            self.appModel = appModel
            let tracking = self.tracking
            coordinator = DownloadKeepaliveCoordinator(appModel: appModel, store: store,
                                                       isTrackingTransfer: { tracking.query($0) })
        }

        func signIn(_ backend: DownloadBackendKind) {
            switch backend {
            case .jellyfin:
                appModel.jellyfinServerBaseURL = URL(string: "https://jellyfin.example.test")!
                appModel.jellyfinAccessToken = "token"
                appModel.jellyfinUserID = "user"
            case .emby:
                appModel.embyServerBaseURL = URL(string: "https://emby.example.test")!
                appModel.embyAccessToken = "token"
                appModel.embyUserID = "user"
            case .plex:
                break
            }
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

/// Injected B60 transfer-tracking seam: records every exact-attempt query.
@MainActor
private final class TrackingProbe {
    var tracked: Set<DownloadAttemptKey> = []
    private(set) var queries: Set<DownloadAttemptKey> = []

    func query(_ key: DownloadAttemptKey) -> Bool {
        queries.insert(key)
        return tracked.contains(key)
    }
}

private final class HeldKeepaliveTask: @unchecked Sendable {
    private let lock = NSLock()
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

    var cancelled: Bool { lock.withLock { didCancel } }

    func task() -> Task<Void, Never> {
        Task { [self] in
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
