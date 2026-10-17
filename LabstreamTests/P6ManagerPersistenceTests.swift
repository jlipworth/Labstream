#if !os(tvOS)
import Foundation
import PMSKit
import Synchronization
import Testing
@testable import Labstream

@Suite("P6 lead manager pins", .serialized,
       .disabled("P6 red pin: P6.2 — held MainActor evidence runs in isolation"))
struct P6ManagerPersistenceTests {
    @Test("P6-pin-01 manager heartbeat survives a held index commit", arguments: [false, true], [false, true])
    func commitHeartbeat(fails: Bool, replace: Bool) async throws {
        let fixture = try P6Fixture()
        let initial = fixture.store()
        let key = try fixture.seed(initial)
        let hold = P6Hold()
        let store = fixture.store(index: .init { data, url in
            hold.hit()
            if fails { throw CocoaError(.fileWriteUnknown) }
            try DownloadIndexFileCommitter().commit(data, to: url)
        })
        let pair = await MainActor.run {
            let session = BackgroundDownloadSession(store: store, protocolClasses: [])
            let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "p6-fixture"))
            return (DownloadManager(appModel: model, store: store, session: session,
                                    registerForBackgroundEvents: false), session)
        }
        defer { hold.release.signal(); pair.1.invalidateInjectedSessionForTesting() }
        hold.arm()
        let action = Task { @MainActor in
            pair.0.applyLifecycleEvent(.pause(.user), for: key, context: "p6_pin")
        }
        try #require(await p6Signal(hold.entered))
        var replacementSubmission: DownloadStore.SeedSubmission?
        if replace {
            let acknowledged = DispatchSemaphore(value: 0)
            let prior = store.currentPersistenceTicket()
            store.persistenceDidSubmitForP6Testing = { ticket in
                if ticket.revision > prior.revision { acknowledged.signal() }
            }
            let replacement = fixture.record("b", mode: .liveForwardOnly, filename: "replacement.mp4")
            replacementSubmission = store.submitAttemptOwnedRecord(replacement, attemptID: replacement.attemptID!, replacing: key.attemptID)
            try #require(await p6Signal(acknowledged))
            #expect(!store.ownsAttempt(key))
        }
        let heartbeat = DispatchSemaphore(value: 0)
        Task { @MainActor in heartbeat.signal() }
        let acknowledged = await p6Signal(heartbeat)
        withKnownIssue("P6 red pin: P6.2 — MainActor waits synchronously for manager lifecycle persistence") {
            #expect(acknowledged)
        }
        hold.release.signal()
        #expect(await action.value == !fails)
        if let replacementSubmission {
            _ = await store.resolve(replacementSubmission, deadline: .after(2))
            let current = try #require(store.record(for: key.ratingKey))
            #expect(current.attemptID != key.attemptID)
            #expect(current.status == .downloading)
            let staleIdentity = OfflineDownloadRowActionIdentity(ratingKey: key.ratingKey, attemptID: key.attemptID)
            #expect(await MainActor.run { pair.0.currentRecord(for: staleIdentity) } == nil)
        }
    }

    @Test("P6-pin-01 amendment: lifecycle submission's stat does not block MainActor")
    func lifecycleStatHeartbeat() async throws {
        let fixture = try P6Fixture()
        let initial = fixture.store()
        let key = try fixture.seed(initial)
        _ = try fixture.working(initial, key)
        let hold = P6Hold()
        let store = fixture.store(filesystem: .init(before: { operation, _ in
            if operation == .stat { hold.hit() }
        }))
        let pair = await MainActor.run {
            let session = BackgroundDownloadSession(store: store, protocolClasses: [])
            return (DownloadManager(appModel: AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "p6-stat")),
                                    store: store, session: session, registerForBackgroundEvents: false), session)
        }
        defer { hold.release.signal(); pair.1.invalidateInjectedSessionForTesting() }
        hold.arm()
        let observationDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread { _ = store.lifecycleFacts(for: key); observationDone.signal() }
        try #require(await p6Signal(hold.entered))
        let actionStarted = DispatchSemaphore(value: 0)
        let action = Task { @MainActor in
            actionStarted.signal()
            return pair.0.applyLifecycleEvent(.pause(.user), for: key, context: "p6_stat")
        }
        try #require(await p6Signal(actionStarted))
        let heartbeat = DispatchSemaphore(value: 0)
        Task { @MainActor in heartbeat.signal() }
        let acknowledged = await p6Signal(heartbeat)
        withKnownIssue("P6 red pin: P6.2/P6.3 — submitLifecycleEvent computes disk facts synchronously") {
            #expect(acknowledged)
        }
        hold.release.signal()
        #expect(await action.value)
        try #require(await p6Signal(observationDone))
    }
}
#endif
