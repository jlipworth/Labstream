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
}
