import Foundation
import Testing
@testable import PMSKit

@Suite("Emby download keepalive policy")
struct EmbyDownloadKeepalivePolicyTests {
    private func record(backend: DownloadBackendKind = .emby,
                        lane: DownloadLane = .compatibleRemux,
                        status: DownloadStatus = .downloading,
                        playSessionID: String? = " psid ",
                        mediaSourceID: String? = " source ") -> DownloadRecord {
        DownloadRecord(
            ratingKey: "\(backend.rawValue):item-1", title: "Title",
            localURL: URL(fileURLWithPath: "/tmp/emby-keepalive.mp4"), status: status,
            metadata: OfflineMetadata(
                ratingKey: "item-1", title: "Title", type: "movie", duration: 12_000,
                backendKind: backend, mediaSourceID: mediaSourceID,
                playSessionID: playSessionID, downloadLane: lane,
                resumeMode: lane == .original ? .staticByteRange : .liveForwardOnly))
    }

    @Test("Only active Emby compatible remux rows are candidates")
    func eligibility() throws {
        let candidate = try #require(EmbyDownloadKeepalivePolicy.candidate(
            for: record(), hasExistingTask: false))
        #expect(candidate.ratingKey == "emby:item-1")
        #expect(candidate.playSessionID == "psid")

        #expect(EmbyDownloadKeepalivePolicy.candidate(
            for: record(lane: .original), hasExistingTask: false) == nil)
        #expect(EmbyDownloadKeepalivePolicy.candidate(
            for: record(lane: .optimize), hasExistingTask: false) == nil)
        #expect(EmbyDownloadKeepalivePolicy.candidate(
            for: record(backend: .jellyfin), hasExistingTask: false) == nil)
        #expect(EmbyDownloadKeepalivePolicy.candidate(
            for: record(status: .complete), hasExistingTask: false) == nil)
        #expect(EmbyDownloadKeepalivePolicy.candidate(
            for: record(), hasExistingTask: true) == nil)
    }

    @Test("Missing persisted session identity fails closed")
    func missingIdentity() {
        #expect(EmbyDownloadKeepalivePolicy.candidate(
            for: record(playSessionID: " "), hasExistingTask: false) == nil)
        // Ping-only keepalive does not require source identity; this keeps pre-migration/relaunch
        // rows alive without inventing a media source or changing playback position.
        #expect(EmbyDownloadKeepalivePolicy.candidate(
            for: record(mediaSourceID: nil), hasExistingTask: false) != nil)
    }

    @Test("Only the current keepalive generation removes its dictionary slot")
    func generationSafeRemoval() {
        let old = UUID()
        let replacement = UUID()
        #expect(EmbyDownloadKeepalivePolicy.shouldRemoveTask(
            completingGeneration: replacement, currentGeneration: replacement))
        #expect(!EmbyDownloadKeepalivePolicy.shouldRemoveTask(
            completingGeneration: old, currentGeneration: replacement))
        #expect(!EmbyDownloadKeepalivePolicy.shouldRemoveTask(
            completingGeneration: old, currentGeneration: nil))
    }

    @Test("Auth quarantine suppresses only the rejected session generation")
    func authQuarantine() {
        #expect(EmbyDownloadKeepalivePolicy.authQuarantineAction(
            quarantinedGeneration: nil, currentGeneration: "session-a") == .none)
        #expect(EmbyDownloadKeepalivePolicy.authQuarantineAction(
            quarantinedGeneration: "session-a", currentGeneration: "session-a") == .suppress)
        #expect(EmbyDownloadKeepalivePolicy.authQuarantineAction(
            quarantinedGeneration: "session-a", currentGeneration: "session-b") == .clear)
    }

    @Test("Known persisted user must match; legacy missing user remains best effort")
    func persistedUserOwnership() {
        #expect(EmbyDownloadKeepalivePolicy.matchesPersistedUser(nil, currentUserID: "new-user"))
        #expect(EmbyDownloadKeepalivePolicy.matchesPersistedUser(" ", currentUserID: nil))
        #expect(EmbyDownloadKeepalivePolicy.matchesPersistedUser(
            " user-a ", currentUserID: "user-a"))
        #expect(!EmbyDownloadKeepalivePolicy.matchesPersistedUser(
            "user-a", currentUserID: "user-b"))
        #expect(!EmbyDownloadKeepalivePolicy.matchesPersistedUser(
            "user-a", currentUserID: nil))
    }
}
