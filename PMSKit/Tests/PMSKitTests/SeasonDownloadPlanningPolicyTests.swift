import Testing
@testable import PMSKit

@Suite("Season download planning")
struct SeasonDownloadPlanningPolicyTests {
    @Test func triStateSelectionNeverTreatsUnknownAsUnwatched() {
        let states: [SeasonEpisodeWatchedState] = [.unwatched, .watched, .unavailable, .unwatched]
        let unwatched = SeasonDownloadSelectionPolicy.select(states: states, scope: .unwatched)
        #expect(unwatched.selectedIndices == [0, 3])
        #expect(unwatched.unavailableCount == 1)
        #expect(SeasonDownloadSelectionPolicy.select(states: states, scope: .all).selectedIndices == [0, 1, 2, 3])
        #expect(SeasonEpisodeWatchedState(viewCount: nil) == .unavailable)
    }

    @Test func watchedStateIsBackendAwareForMissingViewCount() {
        // Plex omits viewCount for never-watched items, so nil means unwatched.
        #expect(SeasonEpisodeWatchedState(viewCount: nil, backend: .plex) == .unwatched)
        #expect(SeasonEpisodeWatchedState(viewCount: 0, backend: .plex) == .unwatched)
        #expect(SeasonEpisodeWatchedState(viewCount: 3, backend: .plex) == .watched)

        // Jellyfin/Emby expose a genuinely three-valued Played, so nil stays unavailable.
        for backend in [MediaBackendID.jellyfin, .emby] {
            #expect(SeasonEpisodeWatchedState(viewCount: nil, backend: backend) == .unavailable)
            #expect(SeasonEpisodeWatchedState(viewCount: 0, backend: backend) == .unwatched)
            #expect(SeasonEpisodeWatchedState(viewCount: 2, backend: backend) == .watched)
        }
    }

    @Test func plexAllNilSeasonSelectsEveryEpisodeAsUnwatched() {
        let states = [Int?](repeating: nil, count: 8).map {
            SeasonEpisodeWatchedState(viewCount: $0, backend: .plex)
        }
        let unwatched = SeasonDownloadSelectionPolicy.select(states: states, scope: .unwatched)
        #expect(unwatched.selectedIndices == Array(0..<8))
        #expect(unwatched.unwatchedCount == 8)
        #expect(unwatched.unavailableCount == 0)
        #expect(!unwatched.selectedIndices.isEmpty)
    }

    @Test func existingRowsAreIdempotentAndPausedRowsStayPaused() {
        #expect(SeasonDownloadDedupPolicy.action(status: nil) == .add)
        #expect(SeasonDownloadDedupPolicy.action(status: .complete) == .alreadyAvailable)
        #expect(SeasonDownloadDedupPolicy.action(status: .unverified) == .alreadyAvailable)
        #expect(SeasonDownloadDedupPolicy.action(status: .queued) == .alreadyPlanned)
        #expect(SeasonDownloadDedupPolicy.action(status: .paused) == .preservePaused)
        #expect(SeasonDownloadDedupPolicy.action(status: .failed) == .retryFailed)
        #expect(SeasonDownloadDedupPolicy.action(status: .failed, deletionPending: true) == .skipDeletionPending)
    }

    @Test func nearestVersionUsesOverallProportionalDistanceAndTieSize() {
        let requested = SeasonDownloadQualityPoint(width: 1920, height: 1080, bitrateKbps: 8_000)
        let candidates = [
            (SeasonDownloadQualityPoint(width: 1280, height: 720, bitrateKbps: 7_500), Optional(900), true),
            (SeasonDownloadQualityPoint(width: 1920, height: 1080, bitrateKbps: 12_000), Optional(800), true),
            (SeasonDownloadQualityPoint(width: 1920, height: 1080, bitrateKbps: 8_000), Optional(1_200), false),
        ]
        #expect(SeasonDownloadExistingVersionMatchPolicy.nearestIndex(requested: requested, candidates: candidates) == 1)

        let ties = [
            (SeasonDownloadQualityPoint(width: nil, height: 1080, bitrateKbps: nil), Optional(2_000), true),
            (SeasonDownloadQualityPoint(width: nil, height: 1080, bitrateKbps: nil), Optional(1_000), true),
        ]
        #expect(SeasonDownloadExistingVersionMatchPolicy.nearestIndex(requested: requested, candidates: ties) == 1)
    }

    @Test func unknownVersionFactsAreNotAutoSelected() {
        let requested = SeasonDownloadQualityPoint(width: nil, height: 720, bitrateKbps: nil)
        let candidates = [(SeasonDownloadQualityPoint(width: nil, height: nil, bitrateKbps: nil), Optional<Int>.none, true)]
        #expect(SeasonDownloadExistingVersionMatchPolicy.nearestIndex(requested: requested, candidates: candidates) == nil)
    }

    @Test func aggregateStorageKeepsUnknownCount() {
        let summary = SeasonDownloadStoragePolicy.summarize([1_000, nil, 2_000, 0])
        #expect(summary.knownBytes == 3_000)
        #expect(summary.unknownCount == 2)
    }

    @Test func admissionIsBoundedAndLaneAware() {
        let pending = [
            SeasonDownloadAdmissionCandidate(id: "prep-1", lane: .serverPreparation),
            .init(id: "prep-2", lane: .serverPreparation),
            .init(id: "static-1", lane: .staticFile),
            .init(id: "live-1", lane: .liveForward),
        ]
        let admitted = SeasonDownloadAdmissionPolicy.admitted(pending: pending, active: [])
        #expect(admitted.map(\.id) == ["prep-1", "static-1", "live-1"])
        #expect(admitted.count == SeasonDownloadAdmissionPolicy.maximumTotal)
    }

    @Test func backendLanesPreserveExistingTransferBehavior() {
        #expect(SeasonDownloadAdmissionPolicy.lane(backend: .plex, downloadLane: .optimize)
            == .serverPreparation)
        #expect(SeasonDownloadAdmissionPolicy.lane(backend: .emby, downloadLane: .optimize)
            == .serverPreparation)
        #expect(SeasonDownloadAdmissionPolicy.lane(backend: .jellyfin, downloadLane: .optimize)
            == .liveForward)
        for backend in [DownloadBackendKind.plex, .jellyfin, .emby] {
            #expect(SeasonDownloadAdmissionPolicy.lane(backend: backend, downloadLane: .original)
                == .staticFile)
        }
    }
}
