#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

@Suite("Abandonment journal performance", .serialized)
@MainActor
struct DownloadAbandonmentPerformanceTests {
    @Test(arguments: [DownloadBackendKind.plex, .emby, .jellyfin])
    func heldCommitLeavesMainActorAvailable(backend: DownloadBackendKind) async throws {
        let hold = P6Hold()
        let committed = TestLockedBox(false)
        let live = DownloadCleanupIntentJournal.Persistence.live
        let f = try await P7PlaybackFixture(status: .paused, cleanupPersistence: .init(
            read: live.read, encode: live.encode, commit: { data, url in
                hold.hit()
                try live.commit(data, url)
                committed.withValue { $0 = true }
            }, syncDirectory: live.syncDirectory))
        defer { hold.release.signal() }
        await f.manager.cleanupRunner?.waitUntilIdle()
        f.manager.cleanupRunner = nil
        let session = BackendSession(kind: backend, baseURL: URL(string: "https://media.invalid")!,
            token: "fixture", userID: "fixture-user", serverID: "fixture-server")
        hold.arm()
        let operation = Task { @MainActor in
            switch backend {
            case .plex:
                return await f.manager.journalStaleOptimizeTitles(["fixture-a", "fixture-b", "fixture-c"], session: session) == 3
            case .emby:
                return await f.manager.journalCleanupAbandonment(.embyConvert(.knownJob(jobID: 42)),
                    originAttempt: f.key, session: session, reason: "fixture")
            case .jellyfin:
                await f.manager.stopSupersededMediaBrowserEncoder(attemptKey: f.key, ratingKey: f.key.ratingKey,
                    playSessionID: "fixture-session", backendKind: backend, backendSession: session)
                return true
            }
        }
        _ = await hold.acknowledgement.wait()
        // This actor turn must run while the physical durable commit remains held.
        #expect(!committed.value)
        #expect(f.requests.value == 0)
        // A different login arrives while the durable commit is held. Its credentials must never
        // be rebound to the captured cleanup, even after the worker eventually commits.
        let model = f.manager.appModel
        model.serverBaseURL = URL(string: "https://replacement.invalid")!
        model.serverToken = "replacement-fixture"
        model.embyServerBaseURL = model.serverBaseURL
        model.embyAccessToken = "replacement-fixture"
        model.embyUserID = "replacement-user"
        model.embyServerID = "replacement-server"
        model.jellyfinServerBaseURL = model.serverBaseURL
        model.jellyfinAccessToken = "replacement-fixture"
        model.jellyfinUserID = "replacement-user"
        model.jellyfinServerID = "replacement-server"
        hold.release.signal()
        #expect(await operation.value)
        guard case .loaded(let intents) = f.manager.cleanupIntentJournal.load() else {
            Issue.record("Journal unreadable"); await f.finish(); return
        }
        #expect(intents.count == (backend == .plex ? 3 : 1))
        #expect(intents.allSatisfy { $0.attemptKey == f.key || backend == .plex })
        #expect(intents.allSatisfy { $0.matches(session: session) })
        for intent in intents { #expect(await f.manager.executeCleanupIntent(intent) == .failed) }
        #expect(f.requests.value == 0)
        await f.finish()
    }

    @Test func staleSweepCommitsOnceAndPreservesDurabilityOnFailure() async throws {
        let commits = TestLockedBox(0)
        let fails = TestLockedBox(false)
        let live = DownloadCleanupIntentJournal.Persistence.live
        let f = try await P7PlaybackFixture(status: .paused, cleanupPersistence: .init(
            read: live.read, encode: live.encode, commit: { data, url in
                commits.withValue { $0 += 1 }
                if fails.value { throw CocoaError(.fileWriteOutOfSpace) }
                try live.commit(data, url)
            }, syncDirectory: live.syncDirectory))
        await f.manager.cleanupRunner?.waitUntilIdle()
        f.manager.cleanupRunner = nil
        let session = BackendSession(kind: .plex, baseURL: URL(string: "https://media.invalid")!,
            token: "fixture", userID: nil, serverID: "fixture-server")
        let before = commits.value
        #expect(await f.manager.journalStaleOptimizeTitles(Set((0..<12).map { "fixture-\($0)" }), session: session) == 12)
        #expect(commits.value == before + 1)
        fails.withValue { $0 = true }
        #expect(await f.manager.journalStaleOptimizeTitles(["fixture-failed"], session: session) == 0)
        guard case .loaded(let intents) = f.manager.cleanupIntentJournal.load() else {
            Issue.record("Journal unreadable"); await f.finish(); return
        }
        #expect(intents.count == 12)
        #expect(f.requests.value == 0)
        await f.finish()
    }
}
#endif
