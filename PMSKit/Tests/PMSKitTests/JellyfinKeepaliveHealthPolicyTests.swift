import Foundation
import Testing
@testable import PMSKit

@Suite("Jellyfin keepalive health policy")
struct JellyfinKeepaliveHealthPolicyTests {

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
