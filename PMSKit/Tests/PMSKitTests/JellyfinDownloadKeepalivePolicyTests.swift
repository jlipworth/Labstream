import Foundation
import Testing
@testable import PMSKit

@Suite("Jellyfin download keepalive policy")
struct JellyfinDownloadKeepalivePolicyTests {
    private let url = URL(fileURLWithPath: "/tmp/labstream-jellyfin-keepalive.mp4")

    private func record(status: DownloadStatus = .downloading,
                        backend: DownloadBackendKind = .jellyfin,
                        lane: DownloadLane = .compatibleRemux,
                        mediaSourceID: String? = " source ",
                        playSessionID: String? = " session ") -> DownloadRecord {
        let ratingKey = DownloadRecordIdentity.recordKey(for: "item", backend: backend)
        let metadata = OfflineMetadata(ratingKey: ratingKey,
                                       title: "Title",
                                       type: "movie",
                                       duration: 12_345,
                                       backendKind: backend,
                                       mediaSourceID: mediaSourceID,
                                       playSessionID: playSessionID,
                                       downloadLane: lane,
                                       resumeMode: lane == .original ? .staticByteRange : .liveForwardOnly)
        return DownloadRecord(ratingKey: ratingKey,
                              title: "Title",
                              localURL: url,
                              bytes: 0,
                              progress: 0,
                              status: status,
                              metadata: metadata)
    }

    @Test("Candidate trims ids and returns backend-local item id")
    func candidate() {
        let candidate = JellyfinDownloadKeepalivePolicy.candidate(for: record(), hasExistingTask: false)
        #expect(candidate == JellyfinDownloadKeepaliveCandidate(ratingKey: "jellyfin:item",
                                                               itemID: "item",
                                                               mediaSourceID: "source",
                                                               playSessionID: "session",
                                                               durationMs: 12_345))
    }

    @Test("Candidate requires active Jellyfin non-original row with session ids and no existing task")
    func candidateGuards() {
        #expect(JellyfinDownloadKeepalivePolicy.candidate(for: record(status: .queued), hasExistingTask: false) != nil)
        #expect(JellyfinDownloadKeepalivePolicy.candidate(for: record(status: .downloading), hasExistingTask: false) != nil)
        #expect(JellyfinDownloadKeepalivePolicy.candidate(for: record(status: .paused), hasExistingTask: false) == nil)
        #expect(JellyfinDownloadKeepalivePolicy.candidate(for: record(backend: .emby), hasExistingTask: false) == nil)
        #expect(JellyfinDownloadKeepalivePolicy.candidate(for: record(lane: .original), hasExistingTask: false) == nil)
        #expect(JellyfinDownloadKeepalivePolicy.candidate(for: record(mediaSourceID: "  "), hasExistingTask: false) == nil)
        #expect(JellyfinDownloadKeepalivePolicy.candidate(for: record(playSessionID: "\n"), hasExistingTask: false) == nil)
        #expect(JellyfinDownloadKeepalivePolicy.candidate(for: record(), hasExistingTask: true) == nil)
    }

    // D3 interim (B55/B60): the keepalive must not move the user's resume point. Until the live
    // A/B test settles a Ping-only keepalive, Playing/Progress report a fixed position of 0. The
    // N2/F2c advancing-position policy and its tests were removed as superseded.
    @Test("Keepalive reports a fixed zero position while D3 is pending")
    func keepaliveReportsFixedZeroPosition() {
        #expect(JellyfinDownloadKeepalivePolicy.reportedPositionTicks == 0)
    }

    // MARK: - tickOutcome collapse

    @Test("All 2xx statuses collapse to healthy")
    func healthyTick() {
        #expect(JellyfinDownloadKeepalivePolicy.tickOutcome(statuses: [200, 204, 200]) == .healthy)
        #expect(JellyfinDownloadKeepalivePolicy.tickOutcome(statuses: []) == .healthy)
    }

    @Test("Auth-dead status dominates every other failure in the tick")
    func authDominates() {
        #expect(JellyfinDownloadKeepalivePolicy.tickOutcome(statuses: [500, nil, 401])
                == .authRejected(statusCode: 401))
        #expect(JellyfinDownloadKeepalivePolicy.tickOutcome(statuses: [403, 200, 200])
                == .authRejected(statusCode: 403))
    }

    @Test("Non-auth HTTP failure outranks transport failure")
    func httpOutranksTransport() {
        #expect(JellyfinDownloadKeepalivePolicy.tickOutcome(statuses: [nil, 503, 200])
                == .httpFailure(statusCode: 503))
        #expect(JellyfinDownloadKeepalivePolicy.tickOutcome(statuses: [nil, 200, nil])
                == .transportFailure)
    }

    // MARK: - healthAction transitions

    @Test("Auth-dead stops pinging immediately")
    func stopOnAuthDead() {
        #expect(JellyfinDownloadKeepalivePolicy.healthAction(previous: .healthy,
                                                             outcome: .authRejected(statusCode: 401))
                == .stopAuthDead(statusCode: 401))
        #expect(JellyfinDownloadKeepalivePolicy.healthAction(previous: nil,
                                                             outcome: .authRejected(statusCode: 403))
                == .stopAuthDead(statusCode: 403))
    }

    @Test("First failure emits degraded once; repeats stay silent")
    func firstFailureEmitsOnce() {
        let first = JellyfinDownloadKeepalivePolicy.healthAction(previous: .healthy,
                                                                 outcome: .httpFailure(statusCode: 500))
        #expect(first == .emitDegraded(reason: "http_500"))
        let repeated = JellyfinDownloadKeepalivePolicy.healthAction(previous: .httpFailure(statusCode: 500),
                                                                    outcome: .httpFailure(statusCode: 500))
        #expect(repeated == .none)
    }

    @Test("A changed failure status re-emits degraded")
    func statusChangeReemits() {
        let changed = JellyfinDownloadKeepalivePolicy.healthAction(previous: .httpFailure(statusCode: 500),
                                                                   outcome: .httpFailure(statusCode: 502))
        #expect(changed == .emitDegraded(reason: "http_502"))
        let transport = JellyfinDownloadKeepalivePolicy.healthAction(previous: .httpFailure(statusCode: 502),
                                                                     outcome: .transportFailure)
        #expect(transport == .emitDegraded(reason: "transport"))
    }

    @Test("Recovery after failure emits recovered; steady health stays silent")
    func recovery() {
        #expect(JellyfinDownloadKeepalivePolicy.healthAction(previous: .transportFailure,
                                                             outcome: .healthy) == .emitRecovered)
        #expect(JellyfinDownloadKeepalivePolicy.healthAction(previous: .healthy,
                                                             outcome: .healthy) == .none)
        #expect(JellyfinDownloadKeepalivePolicy.healthAction(previous: nil,
                                                             outcome: .healthy) == .none)
    }
}
