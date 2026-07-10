import Testing
@testable import PMSKit

@Suite("Download encoder teardown policy")
struct DownloadEncoderTeardownPolicyTests {
    private func metadata(backend: DownloadBackendKind,
                          playSessionID: String? = "play") -> OfflineMetadata {
        let key = DownloadRecordIdentity.recordKey(for: "item", backend: backend)
        return OfflineMetadata(ratingKey: key,
                               title: "Title",
                               type: "movie",
                               backendKind: backend,
                               playSessionID: playSessionID,
                               downloadLane: .optimize,
                               resumeMode: .liveForwardOnly)
    }

    @Test("Transient play sessions stop when the backend session is available and matching")
    func transientSessionStopsWhenSessionMatches() {
        #expect(DownloadEncoderTeardownPolicy.decision(backend: .emby,
                                                       transientPlaySessionID: "abc",
                                                       metadata: metadata(backend: .emby),
                                                       sessionAvailable: true,
                                                       sessionMatchesPersistedServer: true)
                == .stop(playSessionID: "abc"))
        #expect(DownloadEncoderTeardownPolicy.decision(backend: .jellyfin,
                                                       transientPlaySessionID: "jf",
                                                       metadata: nil,
                                                       sessionAvailable: true,
                                                       sessionMatchesPersistedServer: nil)
                == .stop(playSessionID: "jf"))
    }

    @Test("Transient play sessions do not stop against unavailable or mismatched sessions")
    func transientSessionRequiresAvailableMatchingBackend() {
        #expect(DownloadEncoderTeardownPolicy.decision(backend: .emby,
                                                       transientPlaySessionID: "abc",
                                                       metadata: metadata(backend: .emby),
                                                       sessionAvailable: false,
                                                       sessionMatchesPersistedServer: nil)
                == .none)
        #expect(DownloadEncoderTeardownPolicy.decision(backend: .emby,
                                                       transientPlaySessionID: "abc",
                                                       metadata: metadata(backend: .emby),
                                                       sessionAvailable: true,
                                                       sessionMatchesPersistedServer: false)
                == .none)
    }

    @Test("Persisted play sessions log mismatch only for their own backend")
    func persistedSessionMismatchSkipsOnlyOwnBackend() {
        #expect(DownloadEncoderTeardownPolicy.decision(backend: .emby,
                                                       transientPlaySessionID: nil,
                                                       metadata: metadata(backend: .emby),
                                                       sessionAvailable: true,
                                                       sessionMatchesPersistedServer: false)
                == .skip(reason: DownloadEncoderTeardownPolicy.serverMismatchReason))
        #expect(DownloadEncoderTeardownPolicy.decision(backend: .jellyfin,
                                                       transientPlaySessionID: nil,
                                                       metadata: metadata(backend: .emby),
                                                       sessionAvailable: true,
                                                       sessionMatchesPersistedServer: false)
                == .none)
    }

    @Test("No persisted or transient play session means no teardown")
    func noPlaySessionNoops() {
        #expect(DownloadEncoderTeardownPolicy.decision(backend: .emby,
                                                       transientPlaySessionID: nil,
                                                       metadata: metadata(backend: .emby, playSessionID: nil),
                                                       sessionAvailable: true,
                                                       sessionMatchesPersistedServer: false)
                == .none)
        #expect(DownloadEncoderTeardownPolicy.decision(backend: .emby,
                                                       transientPlaySessionID: "",
                                                       metadata: metadata(backend: .emby),
                                                       sessionAvailable: true,
                                                       sessionMatchesPersistedServer: true)
                == .none)
    }

    // MARK: JF-F5 — persisted psid must stop on the delete path (row removed, transient map empty)

    @Test("Persisted play session stops when the row is removed and the server matches")
    func persistedSessionStopsOnRowRemoval() {
        for backend in [DownloadBackendKind.jellyfin, .emby] {
            #expect(DownloadEncoderTeardownPolicy.decision(backend: backend,
                                                           transientPlaySessionID: nil,
                                                           metadata: metadata(backend: backend),
                                                           sessionAvailable: true,
                                                           sessionMatchesPersistedServer: true,
                                                           rowRemoved: true)
                    == .stop(playSessionID: "play"))
        }
    }

    @Test("Persisted play session on row removal keeps the mismatch and availability guards")
    func persistedSessionRowRemovalGuards() {
        // Wrong server: skip (the psid stays persisted only in the caller's snapshot, but the
        // DELETE must never hit a different server).
        #expect(DownloadEncoderTeardownPolicy.decision(backend: .jellyfin,
                                                       transientPlaySessionID: nil,
                                                       metadata: metadata(backend: .jellyfin),
                                                       sessionAvailable: true,
                                                       sessionMatchesPersistedServer: false,
                                                       rowRemoved: true)
                == .skip(reason: DownloadEncoderTeardownPolicy.serverMismatchReason))
        // No live session for the lane: nothing to send the DELETE with.
        #expect(DownloadEncoderTeardownPolicy.decision(backend: .jellyfin,
                                                       transientPlaySessionID: nil,
                                                       metadata: metadata(backend: .jellyfin),
                                                       sessionAvailable: false,
                                                       sessionMatchesPersistedServer: nil,
                                                       rowRemoved: true)
                == .none)
        // Server match unknown: conservative no-op rather than a possibly-wrong-server DELETE.
        #expect(DownloadEncoderTeardownPolicy.decision(backend: .jellyfin,
                                                       transientPlaySessionID: nil,
                                                       metadata: metadata(backend: .jellyfin),
                                                       sessionAvailable: true,
                                                       sessionMatchesPersistedServer: nil,
                                                       rowRemoved: true)
                == .none)
        // Wrong backend lane: another backend's release must not consume this lane's psid.
        #expect(DownloadEncoderTeardownPolicy.decision(backend: .emby,
                                                       transientPlaySessionID: nil,
                                                       metadata: metadata(backend: .jellyfin),
                                                       sessionAvailable: true,
                                                       sessionMatchesPersistedServer: true,
                                                       rowRemoved: true)
                == .none)
    }

    @Test("Persisted play session stays no-op for rows still in the store")
    func persistedSessionStillInStoreStaysNone() {
        // Terminal rows in the store are the launch sweep's job; firing from every
        // releaseInFlight would resend the DELETE on each refresh tick.
        #expect(DownloadEncoderTeardownPolicy.decision(backend: .jellyfin,
                                                       transientPlaySessionID: nil,
                                                       metadata: metadata(backend: .jellyfin),
                                                       sessionAvailable: true,
                                                       sessionMatchesPersistedServer: true,
                                                       rowRemoved: false)
                == .none)
    }
}
