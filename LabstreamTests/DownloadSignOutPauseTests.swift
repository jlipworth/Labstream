import Foundation
import PMSKit
import Testing
@testable import Labstream

@MainActor
struct DownloadSignOutPauseTests {
    @Test func signingOutPausesOnlyActiveRowsOwnedByThatBackend() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "download-signout-pause-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DownloadStore(baseDirectory: directory)
        let emby = try #require(makeRecord(store: store, ratingKey: "emby:item", backend: .emby))
        let jellyfin = try #require(makeRecord(store: store, ratingKey: "jellyfin:item", backend: .jellyfin))
        let plex = try #require(makeRecord(store: store, ratingKey: "plex:item", backend: .plex))
        #expect(store.createAttemptOwnedRecord(emby.record, attemptID: emby.key.attemptID) == .committed(emby.key))
        #expect(store.createAttemptOwnedRecord(jellyfin.record, attemptID: jellyfin.key.attemptID) == .committed(jellyfin.key))
        #expect(store.createAttemptOwnedRecord(plex.record, attemptID: plex.key.attemptID) == .committed(plex.key))

        let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "download-signout"))
        let session = BackgroundDownloadSession(store: store, protocolClasses: [])
        let manager = DownloadManager(appModel: model, store: store, session: session,
                                      registerForBackgroundEvents: false)
        defer { session.invalidateInjectedSessionForTesting() }

        manager.pauseDownloadsForBackendSignOut(.emby)

        #expect(store.record(for: emby.key)?.status == .paused)
        #expect(store.record(for: jellyfin.key)?.status == .downloading)
        #expect(store.record(for: plex.key)?.status == .downloading)

        manager.pauseDownloadsForBackendSignOut(.jellyfin)

        #expect(store.record(for: jellyfin.key)?.status == .paused)
        #expect(store.record(for: plex.key)?.status == .downloading)
    }

    private func makeRecord(store: DownloadStore, ratingKey: String,
                            backend: DownloadBackendKind) -> (key: DownloadAttemptKey, record: DownloadRecord)? {
        guard let attemptID = DownloadAttemptID(rawValue: "attempt-\(ratingKey)") else { return nil }
        let key = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptID)
        let record = DownloadRecord(
            ratingKey: ratingKey,
            attemptID: attemptID,
            title: "Test item",
            localURL: store.destinationURL(ratingKey: ratingKey, ext: "mp4"),
            bytes: 10,
            progress: 0.1,
            status: .downloading,
            metadata: OfflineMetadata(
                ratingKey: ratingKey,
                title: "Test item",
                type: "movie",
                sourcePartSize: 100,
                backendKind: backend,
                backendBaseURLString: "https://media.example.invalid",
                backendServerID: "server",
                backendUserID: "user",
                resumeMode: .staticByteRange))
        return (key, record)
    }
}
