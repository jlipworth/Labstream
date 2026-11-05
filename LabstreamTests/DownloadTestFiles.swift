#if !os(tvOS)
import Foundation
import Synchronization
import Testing
import XCTest
@testable import Labstream

/// Owns only a newly-created per-test subtree. DownloadStore's durable authority is a
/// sibling of its base, so bases must be children of this root, never the root itself.
final class DownloadTestFiles: Sendable {
    @TaskLocal static var current: DownloadTestFiles?
    private static let scopes = Mutex<[String: DownloadTestFiles]>([:])
    let root: URL
    private let cleanups = Mutex<[@Sendable () async -> Void]>([])

    static var temporaryDirectory: URL {
        guard let current else {
            preconditionFailure("Download fixtures require @Suite(.downloadTestFiles)")
        }
        return current.root
    }

    init(parent: URL = FileManager.default.temporaryDirectory) throws {
        root = parent.appendingPathComponent("download-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        Self.scopes.withLock { $0[root.standardizedFileURL.path] = self }
    }

    static func onCleanup(_ cleanup: @escaping @Sendable () async -> Void) {
        guard let current else { preconditionFailure("Missing download test file scope") }
        current.onCleanup(cleanup)
    }

    func onCleanup(_ cleanup: @escaping @Sendable () async -> Void) {
        cleanups.withLock { $0.append(cleanup) }
    }

    func cleanup() async throws {
        defer { Self.scopes.withLock { $0.removeValue(forKey: root.standardizedFileURL.path) } }
        let actions = cleanups.withLock { actions in
            let result = actions.reversed()
            actions.removeAll()
            return Array(result)
        }
        for action in actions { await action() }
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    /// All fixture stores join their writers before the enclosing root is removed.
    /// Path lookup also covers detached startup probes, which do not inherit TaskLocal values.
    static func store(
        baseDirectory: URL,
        fileManager: FileManager = .default,
        indexPersistence: DownloadStore.IndexPersistence = .live,
        embyCleanupPersistence: DownloadStore.EmbyCleanupPersistence? = nil,
        artifactFilesystem: DownloadArtifactFilesystem = .live,
        checkpointFilesystem: DownloadStaticCheckpointFilesystem = .live,
        promotionFilesystem: DownloadPromotionFilesystem = .live,
        storeFilesystem: DownloadStoreFilesystem = .live,
        availableStorageBytes: @escaping @Sendable (URL) -> Int64? = {
            DownloadVolumeFreeSpace.measure(directory: $0)?.bytes
        },
        startupOnWorker: Bool = false,
        startupRepairWillBegin: @escaping @Sendable () -> Void = {}
    ) -> DownloadStore {
        let path = baseDirectory.standardizedFileURL.path
        guard let owner = scopes.withLock({ scopes in
            scopes.filter { path.hasPrefix($0.key + "/") }
                .max { $0.key.count < $1.key.count }?.value
        }) else { preconditionFailure("Store base must be inside an owned test root") }
        let store = DownloadStore(baseDirectory: baseDirectory, fileManager: fileManager,
            indexPersistence: indexPersistence, embyCleanupPersistence: embyCleanupPersistence,
            artifactFilesystem: artifactFilesystem, checkpointFilesystem: checkpointFilesystem,
            promotionFilesystem: promotionFilesystem, storeFilesystem: storeFilesystem,
            availableStorageBytes: availableStorageBytes, startupOnWorker: startupOnWorker,
            startupRepairWillBegin: startupRepairWillBegin)
        owner.onCleanup {
            if let startup = store.initialStartupSubmission {
                _ = await store.resolve(startup, deadline: .after(10))
            }
            await store.drainArtifactWorkerForP6Testing()
            _ = await store.flushPersistence(timeout: 5)
        }
        return store
    }

    @MainActor
    static func manager(
        appModel: AppModel,
        store: DownloadStore? = nil,
        storeConstruction: () -> DownloadStore = {
            preconditionFailure("Test managers must construct an owned store")
        },
        session: BackgroundDownloadSession? = nil,
        sessionConstruction: (DownloadStore) -> BackgroundDownloadSession = { BackgroundDownloadSession(store: $0) },
        cleanupIntentJournal: DownloadCleanupIntentJournal? = nil,
        sideAssetFetchCoordinator: SideAssetFetchCoordinator? = nil,
        backgroundCompletionRegistry: BackgroundDownloadCompletionRegistry = .shared,
        registerForBackgroundEvents: Bool = true,
        preferencesDefaults: UserDefaults = .standard,
        startupIndexDeadline: @escaping @Sendable () -> DownloadStoreDeadline = { .after(30) }
    ) -> DownloadManager {
        let manager = DownloadManager(appModel: appModel, store: store,
            storeConstruction: storeConstruction, session: session, sessionConstruction: sessionConstruction,
            cleanupIntentJournal: cleanupIntentJournal, sideAssetFetchCoordinator: sideAssetFetchCoordinator,
            backgroundCompletionRegistry: backgroundCompletionRegistry,
            registerForBackgroundEvents: registerForBackgroundEvents, preferencesDefaults: preferencesDefaults,
            startupIndexDeadline: startupIndexDeadline)
        let path = manager.store.directory.standardizedFileURL.path
        guard let owner = scopes.withLock({ scopes in
            scopes.filter { path.hasPrefix($0.key + "/") }
                .max { $0.key.count < $1.key.count }?.value
        }) else { preconditionFailure("Test managers must use an owned store") }
        // Do not extend manager lifetime: startup tests explicitly prove its release.
        // Any surviving manager is stopped before the strongly-owned stores are drained.
        owner.onCleanup { [weak manager] in
            guard let manager else { return }
            await stopManager(manager)
        }
        return manager
    }

    @MainActor
    private static func stopManager(_ manager: DownloadManager) async {
        manager.setQueuePausedForTesting(true)
        let pump = manager.admissionPumpTask
        let wake = manager.admissionWakeTask
        pump?.cancel()
        wake?.cancel()
        manager.session.onChange = nil
        manager.session.onError = nil
        manager.session.onRangeRequestNeeded = nil
        manager.session.onFinalizerRequest = nil
        manager.session.invalidateInjectedSessionForTesting()
        await pump?.value
        await wake?.value
        await manager.launchSweepJournaling?.value
        await manager.cleanupRunner?.waitUntilIdle()
        await manager.session.drainRangeIOForTesting()
        await manager.scheduledRefreshTaskForTesting?.value
        await manager.drainManagerOperationsForTesting()
    }

    static func withScope(_ body: @Sendable () async throws -> Void) async throws {
        let files = try DownloadTestFiles()
        do {
            try await $current.withValue(files, operation: body)
        } catch {
            try await files.cleanup()
            throw error
        }
        try await files.cleanup()
    }
}

struct DownloadTestFilesTrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        // Suite invocation and parameter expansion do not own fixture files.
        guard !test.isSuite, testCase != nil else { return try await function() }
        try await DownloadTestFiles.withScope(function)
    }
}

extension Trait where Self == DownloadTestFilesTrait {
    static var downloadTestFiles: Self { Self() }
}

/// XCTest runs setup and the test in separate task contexts, so its fixtures use
/// an instance owner and an awaited teardown block instead of the task-local trait.
class DownloadFileTestCase: XCTestCase {
    private(set) var downloadTestFiles: DownloadTestFiles!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let files = try DownloadTestFiles()
        downloadTestFiles = files
        addTeardownBlock { try await files.cleanup() }
    }
}
#endif
