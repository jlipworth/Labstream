import Foundation
import PMSKit
import Testing
@testable import Labstream

@MainActor
struct DownloadWorkRegistryTests {
    @Test func exactCompletionCannotRemoveAnotherTokenOrAttempt() {
        let registry = DownloadWorkRegistry()
        let attemptA = key("plex:item", "attempt-A")
        let attemptB = key("plex:item", "attempt-B")
        let taskA = pendingTask()
        let taskB = pendingTask()
        defer { taskA.cancel(); taskB.cancel() }
        let tokenA = registry.register(taskA, for: attemptA, kind: .finalizer)
        let tokenB = registry.register(taskB, for: attemptB, kind: .finalizer)

        #expect(!registry.complete(key: attemptB, token: tokenA))
        #expect(registry.snapshot().totalCount == 2)
        #expect(registry.complete(key: attemptA, token: tokenA))
        #expect(!registry.complete(key: attemptA, token: tokenA))
        #expect(registry.snapshot().attempts.map(\.key) == [attemptB])
        #expect(registry.complete(key: attemptB, token: tokenB))
        #expect(registry.snapshot().totalCount == 0)
    }

    @Test func cancellationIsExactAttemptScopedAndPreservesRequiredCleanup() {
        let registry = DownloadWorkRegistry()
        let attemptA = key("emby:item", "attempt-A")
        let attemptB = key("emby:item", "attempt-B")
        let finalizer = pendingTask()
        let poster = pendingTask()
        let cleanup = pendingTask()
        let replacement = pendingTask()
        defer {
            finalizer.cancel(); poster.cancel(); cleanup.cancel(); replacement.cancel()
        }
        let finalizerToken = registry.register(finalizer, for: attemptA, kind: .finalizer)
        let posterToken = registry.register(
            poster, for: attemptA, kind: .sideCache(.poster))
        let cleanupToken = registry.register(
            cleanup, for: attemptA, kind: .requiredCleanup)
        let replacementToken = registry.register(
            replacement, for: attemptB, kind: .sideCache(.chapterImages))

        let cancelled = Set(registry.cancelCancellableWork(for: attemptA))
        #expect(cancelled == Set([finalizerToken, posterToken]))
        #expect(finalizer.isCancelled)
        #expect(poster.isCancelled)
        #expect(!cleanup.isCancelled)
        #expect(!replacement.isCancelled)
        let snapshot = registry.snapshot()
        #expect(snapshot.totalCount == 2)
        #expect(snapshot.cancellableCount == 1)
        #expect(snapshot.requiredCleanupCount == 1)
        #expect(snapshot.attempts.map(\.key) == [attemptA, attemptB])

        #expect(registry.complete(key: attemptA, token: cleanupToken))
        #expect(registry.complete(key: attemptB, token: replacementToken))
    }

    @Test func startedWorkCompareRemovesItselfAndCleanupSurvivesAttemptCancel() async {
        let registry = DownloadWorkRegistry()
        let attempt = key("jellyfin:item", "attempt-A")
        let finalizerGate = AsyncWorkGate()
        let cleanupGate = AsyncWorkGate()
        let finalizerToken = registry.start(for: attempt, kind: .finalizer) {
            await finalizerGate.wait()
        }
        let cleanupToken = registry.start(for: attempt, kind: .requiredCleanup) {
            await cleanupGate.wait()
        }
        await finalizerGate.waitUntilEntered()
        await cleanupGate.waitUntilEntered()
        #expect(registry.snapshot().totalCount == 2)

        #expect(registry.cancelCancellableWork(for: attempt) == [finalizerToken])
        let retained = registry.snapshot()
        #expect(retained.totalCount == 1)
        #expect(retained.attempts.first?.entries.first?.token == cleanupToken)
        #expect(retained.requiredCleanupCount == 1)

        await finalizerGate.open()
        await cleanupGate.open()
        await waitUntil { registry.snapshot().totalCount == 0 }
        #expect(registry.snapshot().totalCount == 0)
    }

    @Test func snapshotsHaveDeterministicAttemptAndKindOrdering() {
        let registry = DownloadWorkRegistry()
        let z = key("z:item", "attempt-Z")
        let a2 = key("a:item", "attempt-B")
        let a1 = key("a:item", "attempt-A")
        let tasks = (0..<4).map { _ in pendingTask() }
        defer { tasks.forEach { $0.cancel() } }
        _ = registry.register(tasks[0], for: z, kind: .requiredCleanup)
        _ = registry.register(tasks[1], for: a2, kind: .sideCache(.poster))
        _ = registry.register(tasks[2], for: a1, kind: .sideCache(.chapterImages))
        _ = registry.register(tasks[3], for: a1, kind: .finalizer)

        let snapshot = registry.snapshot()
        #expect(snapshot.attempts.map(\.key) == [a1, a2, z])
        #expect(snapshot.attempts[0].entries.map(\.kind)
                == [.finalizer, .sideCache(.chapterImages)])
    }

    @Test func exactFinalizerStartIfAbsentIsAtomic() async {
        let registry = DownloadWorkRegistry()
        let attempt = key("plex:finalize", "attempt-A")
        let gate = AsyncWorkGate()
        let first = registry.startIfAbsent(for: attempt, kind: .finalizer) {
            await gate.wait()
        }
        #expect(first != nil)
        #expect(registry.startIfAbsent(for: attempt, kind: .finalizer) {} == nil)
        await gate.waitUntilEntered()
        #expect(registry.snapshot().attempts.first?.entries.map(\.kind) == [.finalizer])
        await gate.open()
        await waitUntil { registry.snapshot().totalCount == 0 }
    }

    @Test func terminalReleaseCanPreserveRunningFinalizerOnly() {
        let registry = DownloadWorkRegistry()
        let attempt = key("plex:terminal", "attempt-A")
        let finalizer = pendingTask()
        let poster = pendingTask()
        defer { finalizer.cancel(); poster.cancel() }
        let finalizerToken = registry.register(finalizer, for: attempt, kind: .finalizer)
        let posterToken = registry.register(poster, for: attempt, kind: .sideCache(.poster))

        #expect(registry.cancelCancellableWork(
            for: attempt, mode: .preservingFinalizer) == [posterToken])
        #expect(!finalizer.isCancelled)
        #expect(poster.isCancelled)
        #expect(registry.snapshot().attempts.first?.entries.map(\.token) == [finalizerToken])
    }

    @Test func terminalRefreshPreservesBothPublishingAndRevalidationFinalizers() {
        let registry = DownloadWorkRegistry()
        let attempt = key("plex:terminal-revalidation", "attempt-A")
        let publishing = pendingTask()
        let revalidation = pendingTask()
        let poster = pendingTask()
        defer { publishing.cancel(); revalidation.cancel(); poster.cancel() }
        _ = registry.register(publishing, for: attempt, kind: .finalizer)
        _ = registry.register(revalidation, for: attempt, kind: .revalidationFinalizer)
        let posterToken = registry.register(poster, for: attempt, kind: .sideCache(.poster))

        #expect(registry.cancelCancellableWork(
            for: attempt, mode: .preservingFinalizer) == [posterToken])
        #expect(!publishing.isCancelled)
        #expect(!revalidation.isCancelled)
        #expect(poster.isCancelled)
    }

    @Test func inactiveCancellationTargetsRevalidationButPreservesPublishingFinalizer() {
        let registry = DownloadWorkRegistry()
        let attempt = key("plex:inactive", "attempt-A")
        let publishing = pendingTask()
        let revalidation = pendingTask()
        defer { publishing.cancel(); revalidation.cancel() }
        let publishingToken = registry.register(publishing, for: attempt, kind: .finalizer)
        let revalidationToken = registry.register(
            revalidation, for: attempt, kind: .revalidationFinalizer)

        #expect(registry.cancelRevalidationFinalizer(for: attempt) == [revalidationToken])
        #expect(revalidation.isCancelled)
        #expect(!publishing.isCancelled)
        #expect(registry.snapshot().attempts.first?.entries.map(\.token) == [publishingToken])
    }

    @Test func successfulReleasePreservesFinalizerAndSideCaches() {
        let registry = DownloadWorkRegistry()
        let attempt = key("plex:complete", "attempt-A")
        let finalizer = pendingTask()
        let poster = pendingTask()
        let cleanup = pendingTask()
        defer { finalizer.cancel(); poster.cancel(); cleanup.cancel() }
        _ = registry.register(finalizer, for: attempt, kind: .finalizer)
        _ = registry.register(poster, for: attempt, kind: .sideCache(.poster))
        _ = registry.register(cleanup, for: attempt, kind: .requiredCleanup)

        #expect(registry.cancelCancellableWork(
            for: attempt, mode: .preservingFinalizerAndSideCache).isEmpty)
        #expect(!finalizer.isCancelled)
        #expect(!poster.isCancelled)
        #expect(!cleanup.isCancelled)
        #expect(registry.snapshot().totalCount == 3)
    }

    @Test func cancelledOldSideCacheCompletionCannotRemoveReaddedAttemptsWork() async {
        let registry = DownloadWorkRegistry()
        let old = key("plex:readd", "attempt-A")
        let replacement = key("plex:readd", "attempt-B")
        let oldGate = AsyncWorkGate()
        let replacementGate = AsyncWorkGate()
        let oldToken = registry.start(for: old, kind: .sideCache(.poster)) {
            await oldGate.wait()
        }
        await oldGate.waitUntilEntered()

        #expect(registry.cancelCancellableWork(for: old) == [oldToken])
        let replacementToken = registry.start(
            for: replacement, kind: .sideCache(.poster)) {
                await replacementGate.wait()
            }
        await replacementGate.waitUntilEntered()
        await oldGate.open()
        await Task.yield()

        let afterOldCompletion = registry.snapshot()
        #expect(afterOldCompletion.attempts.map(\.key) == [replacement])
        #expect(afterOldCompletion.attempts.first?.entries.map(\.token) == [replacementToken])

        await replacementGate.open()
        await waitUntil { registry.snapshot().totalCount == 0 }
    }

    /// Exercises the exact production commit boundary shared by poster, subtitle, BIF,
    /// Jellyfin trick-play, and chapter-image tails. The old tail is deliberately allowed to
    /// ignore cooperative cancellation: delete/re-add replaces A with B while it is suspended,
    /// then releasing A must fail both the file promotion and its asset-specific metadata write.
    @Test(arguments: SuspendedSideAssetCase.allCases)
    func suspendedOldSideAssetCannotPublishIntoReaddedAttempt(
        asset: SuspendedSideAssetCase
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "download-side-tail-\(asset.rawValue)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DownloadStore(baseDirectory: directory)
        let old = key("plex:side-tail", "attempt-A")
        let replacement = key("plex:side-tail", "attempt-B")
        #expect(createRecord(store: store, key: old))
        let oldSource = try #require(store.sideAssetSourceIdentity(for: old))
        let stable = asset.destination(store: store, ratingKey: old.ratingKey)
        let staging = try #require(store.attemptStagingURL(for: old, stableURL: stable))
        try Data("old-attempt-body".utf8).write(to: staging)

        let gate = AsyncWorkGate()
        let oldTail = Task { () -> Bool in
            await gate.wait()
            guard DownloadManager.promoteSideAsset(
                store: store, key: old, expectedSource: oldSource,
                stagingURL: staging, stableURL: stable
            ) else { return false }
            return store.updateMetadata(for: old, expectedSideAssetSource: oldSource) {
                asset.publish(into: &$0, relative: stable.lastPathComponent)
            } == .applied
        }
        await gate.waitUntilEntered()

        #expect(createRecord(store: store, key: replacement, replacing: old.attemptID))
        try Data("replacement-body".utf8).write(to: stable)
        await gate.open()

        #expect(await oldTail.value == false)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(String(decoding: try Data(contentsOf: stable), as: UTF8.self)
                == "replacement-body")
        #expect(!asset.isPublished(in: store.record(for: replacement.ratingKey)?.metadata))
    }

    /// A finalizer can be inside a non-preemptible validation call when delete cancels it. The
    /// production terminal publication API must therefore reject A after B owns the row even if
    /// the old task reaches the Store after replacement.
    @Test func suspendedOldFinalizerCannotPromoteReaddedAttempt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "download-finalizer-tail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DownloadStore(baseDirectory: directory)
        let registry = DownloadWorkRegistry()
        let old = key("plex:finalizer-tail", "attempt-A")
        let replacement = key("plex:finalizer-tail", "attempt-B")
        #expect(createRecord(store: store, key: old))
        let oldWorking = try #require(store.attemptWorkingFileURL(for: old))
        try Data("old-validated-body".utf8).write(to: oldWorking)
        let gate = AsyncWorkGate()
        #expect(registry.startIfAbsent(for: old, kind: .finalizer) {
            await gate.wait()
            _ = store.promoteValidatedAttempt(for: old, terminalStatus: .complete)
        } != nil)
        await gate.waitUntilEntered()

        #expect(createRecord(store: store, key: replacement, replacing: old.attemptID))
        let stable = store.destinationURL(ratingKey: replacement.ratingKey, ext: "mp4")
        try Data("replacement-body".utf8).write(to: stable)
        await gate.open()
        await waitUntil { registry.snapshot().totalCount == 0 }

        #expect(store.record(for: replacement.ratingKey)?.attemptID == replacement.attemptID)
        #expect(store.record(for: replacement.ratingKey)?.status == .queued)
        #expect(String(decoding: try Data(contentsOf: stable), as: UTF8.self)
                == "replacement-body")
    }

    /// Required cleanup intentionally survives ordinary attempt cancellation. When its delayed
    /// response arrives after delete/re-add, the production compare-clear must target both A's
    /// attempt and A's exact server handle and leave B untouched.
    @Test func suspendedRequiredCleanupCannotClearReaddedAttemptsSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "download-cleanup-tail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DownloadStore(baseDirectory: directory)
        let registry = DownloadWorkRegistry()
        let old = key("emby:cleanup-tail", "attempt-A")
        let replacement = key("emby:cleanup-tail", "attempt-B")
        #expect(createRecord(store: store, key: old))
        #expect(store.updateMetadata(for: old) { $0.playSessionID = "session-A" } == .applied)
        let gate = AsyncWorkGate()
        let cleanupToken = registry.start(for: old, kind: .requiredCleanup) {
            await gate.wait()
            _ = store.clearPlaySessionID(for: old, expectedPlaySessionID: "session-A")
        }
        await gate.waitUntilEntered()

        #expect(registry.cancelCancellableWork(for: old).isEmpty)
        #expect(registry.snapshot().attempts.first?.entries.first?.token == cleanupToken)
        #expect(createRecord(store: store, key: replacement, replacing: old.attemptID))
        #expect(store.updateMetadata(for: replacement) { $0.playSessionID = "session-B" }
                == .applied)
        await gate.open()
        await waitUntil { registry.snapshot().totalCount == 0 }

        #expect(store.record(for: replacement.ratingKey)?.metadata?.playSessionID == "session-B")
    }

    private func key(_ ratingKey: String, _ attempt: String) -> DownloadAttemptKey {
        DownloadAttemptKey(
            ratingKey: ratingKey,
            attemptID: DownloadAttemptID(rawValue: attempt)!)
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<100 where !predicate() { await Task.yield() }
    }

    private func pendingTask() -> Task<Void, Never> {
        Task { try? await Task.sleep(for: .seconds(3_600)) }
    }

    private func createRecord(
        store: DownloadStore,
        key: DownloadAttemptKey,
        replacing: DownloadAttemptID? = nil
    ) -> Bool {
        let stable = store.destinationURL(ratingKey: key.ratingKey, ext: "mp4")
        let record = DownloadRecord(
            ratingKey: key.ratingKey,
            attemptID: key.attemptID,
            title: "Item",
            localURL: stable,
            status: .queued,
            metadata: OfflineMetadata(
                ratingKey: key.ratingKey, title: "Item", type: "movie"))
        guard case .committed(let actual) = store.createAttemptOwnedRecord(
            record, attemptID: key.attemptID, replacing: replacing
        ) else { return false }
        return actual == key
    }
}

enum SuspendedSideAssetCase: String, CaseIterable, Sendable {
    case poster
    case textSubtitles
    case plexBIF
    case embyBIF
    case jellyfinTrickPlay
    case chapterImages

    func destination(store: DownloadStore, ratingKey: String) -> URL {
        switch self {
        case .poster:
            store.posterDestinationURL(ratingKey: ratingKey)
        case .textSubtitles:
            store.textSubtitleDestinationURL(ratingKey: ratingKey, streamID: 7, ext: "vtt")
        case .plexBIF:
            store.plexBIFDestinationURL(ratingKey: ratingKey)
        case .embyBIF:
            store.embyBIFDestinationURL(ratingKey: ratingKey)
        case .jellyfinTrickPlay:
            store.jellyfinTrickPlayPlaylistDestinationURL(ratingKey: ratingKey)
        case .chapterImages:
            store.chapterImageDestinationURL(ratingKey: ratingKey, index: 0)
        }
    }

    func publish(into metadata: inout OfflineMetadata, relative: String) {
        switch self {
        case .poster:
            metadata.posterRelativePath = relative
        case .textSubtitles:
            metadata.offlineTextSubtitles = [OfflineTextSubtitleTrack(
                id: 7, displayName: "English", codec: "vtt", relativePath: relative)]
        case .plexBIF:
            metadata.plexBIFRelativePath = relative
        case .embyBIF:
            metadata.embyBIFRelativePath = relative
        case .jellyfinTrickPlay:
            metadata.jellyfinTrickPlayPlaylistRelativePath = relative
            metadata.jellyfinTrickPlayTileRelativePaths = [relative]
        case .chapterImages:
            metadata.chapterImageRelativePaths = [0: relative]
        }
    }

    func isPublished(in metadata: OfflineMetadata?) -> Bool {
        guard let metadata else { return false }
        return switch self {
        case .poster:
            metadata.posterRelativePath != nil
        case .textSubtitles:
            !(metadata.offlineTextSubtitles?.isEmpty ?? true)
        case .plexBIF:
            metadata.plexBIFRelativePath != nil
        case .embyBIF:
            metadata.embyBIFRelativePath != nil
        case .jellyfinTrickPlay:
            metadata.jellyfinTrickPlayPlaylistRelativePath != nil
                || !(metadata.jellyfinTrickPlayTileRelativePaths?.isEmpty ?? true)
        case .chapterImages:
            !(metadata.chapterImageRelativePaths?.isEmpty ?? true)
        }
    }
}

struct DownloadPlaybackValidationLimiterTests {
    @Test func cancelledWaiterIsRemovedAndDoesNotConsumePermit() async throws {
        let limiter = DownloadPlaybackValidationLimiter()
        try await limiter.wait()

        let cancelled = Task { () -> Bool in
            do {
                try await limiter.wait()
                return true
            } catch {
                return false
            }
        }
        while await limiter.queuedWaiterCountForTesting == 0 { await Task.yield() }
        cancelled.cancel()
        #expect(await cancelled.value == false)
        #expect(await limiter.queuedWaiterCountForTesting == 0)

        await limiter.signal()
        try await limiter.wait()
        await limiter.signal()
    }
}

private actor AsyncWorkGate {
    private var entered = false
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        guard !isOpen else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }
}
