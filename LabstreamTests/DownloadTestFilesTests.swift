#if !os(tvOS)
import Foundation
import Synchronization
import Testing
@testable import Labstream

@Suite(.downloadTestFiles)
struct DownloadTestFilesTests {
    private enum Exit: Error { case expected }

    @Test(arguments: ["p5", "p6", "download-store-persistence", "attempt-checkpoint",
                      "download-stage", "artifact-lifecycle", "prep-runner", "handoff-storage"])
    func removesBaseAndAuthorityOnEveryExit(prefix: String) async throws {
        let outer = DownloadTestFiles.temporaryDirectory
        let unrelated = outer.appendingPathComponent("unrelated")
        try Data([9]).write(to: unrelated)
        // Repeat within one owned parent, so even hidden leftovers are observable without
        // enumerating or deleting the host's shared temporary directory.
        for exit in 0..<3 {
            let paths = Mutex<[URL]>([])
            let owner = try DownloadTestFiles(parent: outer)
            do {
                try await DownloadTestFiles.$current.withValue(owner) {
                    let base = DownloadTestFiles.temporaryDirectory.appendingPathComponent("\(prefix)-fixture")
                    let store = DownloadTestFiles.store(baseDirectory: base)
                    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                    let authority = store.durableCleanupAuthorityDirectory
                    try FileManager.default.createDirectory(at: authority, withIntermediateDirectories: true)
                    try Data([1]).write(to: base.appendingPathComponent("stage"))
                    try Data([2]).write(to: authority.appendingPathComponent("journal"))
                    paths.withLock { $0 = [base, authority] }
                    if exit == 1 { throw Exit.expected }
                    if exit == 2 { return } // early return still belongs to the scope
                }
            } catch Exit.expected { }
            try await owner.cleanup()
            try await owner.cleanup() // idempotent, including absent bases
            #expect(!FileManager.default.fileExists(atPath: owner.root.path))
            for path in paths.withLock({ $0 }) {
                #expect(!FileManager.default.fileExists(atPath: path.path))
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outer.path) == ["unrelated"])
    }

    @Test func startupBoundsInventoryAndFiltersSiblingReclamation() async throws {
        let parent = DownloadTestFiles.temporaryDirectory
        let base = parent.appendingPathComponent("store")
        let retired = parent.appendingPathComponent(".store-retired-fixture")
        let unrelated = parent.appendingPathComponent(".another-store-retired-fixture")
        for url in [retired, unrelated] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let files = StartupEnumerationRecorder()
        let store = DownloadTestFiles.store(baseDirectory: base, fileManager: files)
        await store.drainArtifactWorkerForP6Testing()
        _ = store.unreferencedAttemptStagingURLs()
        let allowed = Set([base.standardizedFileURL.path,
                           store.durableCleanupAuthorityDirectory.standardizedFileURL.path])
        #expect(await files.retiredRemoved.wait(seconds: 10) == true)
        let enumerated = files.directories.withLock { $0 }
        // Every admissible startup schedules crash-recovery reclamation of retired
        // roots. That one parent listing is intentional and now test-owned too.
        #expect(enumerated.contains(parent.standardizedFileURL.path))
        #expect(enumerated.allSatisfy { path in
            path == parent.standardizedFileURL.path
                || allowed.contains { path == $0 || path.hasPrefix($0 + "/") }
        })
        #expect(!FileManager.default.fileExists(atPath: retired.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test func pendingIndexCommitFinishesBeforeRootRemovalOnThrow() async throws {
        let hold = P6Hold()
        let committed = Mutex(false)
        let paths = Mutex<[URL]>([])
        do {
            try await DownloadTestFiles.withScope {
                let fixture = try P6Fixture()
                let store = fixture.store(index: .init { data, url in
                    hold.hit()
                    try DownloadIndexFileCommitter().commit(data, to: url)
                    committed.withLock { $0 = true }
                })
                let key = try fixture.seed(store)
                paths.withLock { $0 = [fixture.directory, store.durableCleanupAuthorityDirectory] }
                committed.withLock { $0 = false }
                hold.arm()
                // The body deliberately exits without resolving this accepted index write.
                store.submitMetadata(for: key) { $0.localPlaybackPositionMs = 123 }
                DownloadTestFiles.onCleanup { hold.release.signal() }
                try #require(await hold.acknowledgement.wait(seconds: 5) == true)
                throw Exit.expected
            }
        } catch Exit.expected { }
        #expect(committed.withLock { $0 })
        for path in paths.withLock({ $0 }) {
            #expect(!FileManager.default.fileExists(atPath: path.path))
        }
    }

    @Test(arguments: [0, 1, 2])
    func scopeAwaitsCleanupAndDoesNotDependOnFixtureDeinit(exit: Int) async throws {
        let retained = Mutex<P6Fixture?>(nil)
        let paths = Mutex<[URL]>([])
        let finished = Mutex(false)
        do {
            try await DownloadTestFiles.withScope {
                let fixture = try P6Fixture()
                retained.withLock { $0 = fixture }
                let store = fixture.store()
                let authority = store.durableCleanupAuthorityDirectory
                try FileManager.default.createDirectory(at: authority, withIntermediateDirectories: true)
                paths.withLock { $0 = [fixture.directory, authority] }
                DownloadTestFiles.onCleanup {
                    await Task.yield()
                    #expect(FileManager.default.fileExists(atPath: fixture.directory.path))
                    finished.withLock { $0 = true }
                }
                if exit == 1 { throw Exit.expected }
                if exit == 2 { return }
            }
        } catch Exit.expected { }
        #expect(finished.withLock { $0 })
        #expect(retained.withLock { $0 != nil })
        for path in paths.withLock({ $0 }) {
            #expect(!FileManager.default.fileExists(atPath: path.path))
        }
    }
}
private final class StartupEnumerationRecorder: FileManager, @unchecked Sendable {
    let directories = Mutex<Set<String>>([])
    let retiredRemoved = P6Acknowledgement<Bool>()
    override func removeItem(at url: URL) throws {
        try super.removeItem(at: url)
        if url.lastPathComponent == ".store-retired-fixture" { retiredRemoved.signal(true) }
    }
    override func contentsOfDirectory(atPath path: String) throws -> [String] {
        directories.withLock { $0.insert(URL(fileURLWithPath: path).standardizedFileURL.path) }
        return try super.contentsOfDirectory(atPath: path)
    }
    override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                                      options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
        directories.withLock { $0.insert(url.standardizedFileURL.path) }
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}
#endif
