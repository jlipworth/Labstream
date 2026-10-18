#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

@Suite("P6 store and manager review pins", .serialized)
struct P6ManagerReworkTests {
    @Test("Startup normalization leaves MainActor responsive and transport dormant", arguments: [false, true])
    func initializationHeartbeat(fails: Bool) async throws {
        let fixture = try P6Fixture()
        let initial = fixture.store()
        var record = fixture.record(status: .complete)
        record.metadata?.posterRelativePath = "fixture.poster.jpg"
        try Data([1]).write(to: record.localURL)
        try #require(initial.createAttemptOwnedRecord(record, attemptID: record.attemptID!) == .committed(
            DownloadAttemptKey(ratingKey: record.ratingKey, attemptID: record.attemptID!)))
        let index = fixture.directory.appendingPathComponent("index.json")
        var root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
        var rows = try #require(root["rows"] as? [[String: Any]])
        var metadata = try #require(rows[0]["metadata"] as? [String: Any])
        metadata.removeValue(forKey: "sideAssetBundleOwner")
        rows[0]["metadata"] = metadata
        root["rows"] = rows
        try JSONSerialization.data(withJSONObject: root).write(to: index)
        let hold = P6Hold()
        hold.arm()
        defer { hold.release.signal() }
        let construction = Task { @MainActor in
            let store = DownloadStore(baseDirectory: fixture.directory, indexPersistence: .init { data, url in
                hold.hit()
                if fails { throw CocoaError(.fileWriteUnknown) }
                try DownloadIndexFileCommitter().commit(data, to: url)
            }, startupOnWorker: true)
            let session = BackgroundDownloadSession(store: store, protocolClasses: [])
            let manager = DownloadManager(appModel: AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "p6-startup")),
                store: store, session: session, registerForBackgroundEvents: false)
            return (manager, session)
        }
        try #require(await hold.acknowledgement.wait())
        let heartbeat = P6HeldProgress()
        let inspection = Task { @MainActor in
            let (manager, session) = await construction.value
            #expect(manager.startupRecoveryState == .preparing)
            #expect(!manager.admission.recoveryComplete)
            #expect(!session.startupAdmissionIsActiveForTesting)
            #expect(manager.startupActivationSubmissionCountForTesting == 0)
            heartbeat.acknowledge(hold)
        }
        #expect(await heartbeat.wait())
        hold.release.signal()
        let (manager, session) = await construction.value
        defer { session.invalidateInjectedSessionForTesting() }
        await inspection.value
        let recovered = await manager.awaitStartupRecoveryForTesting()
        #expect(recovered == !fails)
        await MainActor.run {
            if fails {
                guard case .blocked = manager.startupRecoveryState else { Issue.record("failed normalization admitted transport"); return }
                #expect(!session.startupAdmissionIsActiveForTesting)
                #expect(!manager.admission.recoveryComplete)
            } else {
                #expect(manager.startupRecoveryState == .ready)
                #expect(manager.admission.recoveryComplete)
                #expect(manager.store.metadata(for: record.ratingKey)?.sideAssetBundleOwner != nil)
            }
        }
    }

    @Test("Pause of later Emby candidate survives an earlier candidate's held recovery commit")
    func pauseLaterRecoveryCandidate() async throws {
        let fixture = try P6Fixture()
        let hold = P6Hold()
        let store = fixture.store(index: .init { data, url in
            hold.hit()
            try DownloadIndexFileCommitter().commit(data, to: url)
        })
        let (manager, session) = await MainActor.run {
            let session = BackgroundDownloadSession(store: store, protocolClasses: [])
            let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "p6-recovery"))
            let manager = DownloadManager(appModel: model, store: store, session: session, registerForBackgroundEvents: false)
            manager.setQueuePausedForTesting(true)
            return (manager, session)
        }
        defer { hold.release.signal(); session.invalidateInjectedSessionForTesting() }
        try #require(await manager.awaitStartupRecoveryForTesting())
        var keys: [DownloadAttemptKey] = []
        for suffix in ["a", "b"] {
            var record = fixture.record(suffix, status: suffix == "a" ? .failed : .preparing,
                mode: .serverPrepThenStatic, ratingKey: "emby:review-\(suffix)", filename: "\(suffix).mp4")
            record.metadata?.backendKind = .emby
            record.metadata?.backendBaseURLString = "https://emby.invalid"
            record.metadata?.backendServerID = "fixture-server"
            record.metadata?.backendUserID = "fixture-user"
            record.metadata?.downloadLane = .optimize
            record.metadata?.embyConvertJobBaselineIDs = [1]
            record.metadata?.embyConvertRecoveryFingerprint = .init(itemId: suffix, quality: "Custom",
                profile: "fixture", bitrate: 4_000_000, userId: "fixture-user")
            record.metadata?.embyConvertRecoveryStartedAtEpochSeconds = Date().timeIntervalSince1970
            record.metadata?.embyConvertRecoveryPhase = .dispatchAmbiguous
            let key = DownloadAttemptKey(ratingKey: record.ratingKey, attemptID: record.attemptID!)
            try #require(store.createAttemptOwnedRecord(record, attemptID: key.attemptID) == .committed(key))
            keys.append(key)
        }
        await MainActor.run {
            manager.appModel.embyServerBaseURL = URL(string: "https://emby.invalid")!
            manager.appModel.embyAccessToken = "fixture-token"
            manager.appModel.embyUserID = "fixture-user"
            manager.appModel.embyServerID = "fixture-server"
        }
        hold.arm()
        let recovery = Task { @MainActor in await manager.resumePendingEmbyConvertDownloadsAsync() }
        try #require(await p6Signal(hold.entered))
        let later = keys[1]
        await MainActor.run {
            #expect(manager.pause(.init(ratingKey: later.ratingKey, attemptID: later.attemptID)))
            // Free the single prep slot while A's commit is held, so capacity cannot mask a
            // stale B snapshot. A's own continuation is independently fenced by its pause.
            #expect(manager.pause(.init(ratingKey: keys[0].ratingKey, attemptID: keys[0].attemptID)))
        }
        #expect(store.lifecycleState(for: later)?.lifecycle == .paused)
        hold.release.signal()
        await recovery.value
        await manager.drainManagerOperationsForTesting()
        await MainActor.run {
            #expect(store.lifecycleState(for: later)?.lifecycle == .paused)
            #expect(!manager.activeJobs.contains(later.ratingKey))
            #expect(!manager.hasRegisteredServerPrepPoller(ratingKey: later.ratingKey))
            _ = manager.pause(.init(ratingKey: keys[0].ratingKey, attemptID: keys[0].attemptID))
        }
        await manager.drainManagerOperationsForTesting()
        _ = await store.flushPersistence(timeout: 2)
        await store.drainArtifactWorkerForP6Testing()
    }
}
#endif
