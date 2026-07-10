import Foundation
import Testing
@testable import PMSKit

@Suite("Plex optimize poll health policy")
struct PlexOptimizePollHealthPolicyTests {

    @Test("Success resets counters and the emitted-bucket watermark")
    func successResets() {
        var state = PlexOptimizePollHealthPolicy.State(consecutiveFailures: 42,
                                                       consecutiveAuthRejections: 2,
                                                       lastEmittedBucket: "30-99")
        #expect(PlexOptimizePollHealthPolicy.register(.success, state: &state) == .none)
        #expect(state == PlexOptimizePollHealthPolicy.State())
    }

    @Test("Auth rejections go terminal only after the consecutive budget")
    func authBudget() {
        var state = PlexOptimizePollHealthPolicy.State()
        #expect(PlexOptimizePollHealthPolicy.register(.authRejected, state: &state) == .none)
        #expect(PlexOptimizePollHealthPolicy.register(.authRejected, state: &state) == .none)
        #expect(PlexOptimizePollHealthPolicy.register(.authRejected, state: &state) == .failAuthDead)
    }

    @Test("A success between auth rejections resets the auth budget")
    func authBudgetResetOnSuccess() {
        var state = PlexOptimizePollHealthPolicy.State()
        _ = PlexOptimizePollHealthPolicy.register(.authRejected, state: &state)
        _ = PlexOptimizePollHealthPolicy.register(.authRejected, state: &state)
        _ = PlexOptimizePollHealthPolicy.register(.success, state: &state)
        #expect(PlexOptimizePollHealthPolicy.register(.authRejected, state: &state) == .none)
        #expect(state.consecutiveAuthRejections == 1)
    }

    @Test("Generic failures never trip the auth budget")
    func genericFailuresDoNotTerminate() {
        var state = PlexOptimizePollHealthPolicy.State()
        for _ in 0..<50 {
            #expect(PlexOptimizePollHealthPolicy.register(.failure, state: &state) != .failAuthDead)
        }
        // A failure run also clears partial auth-rejection credit.
        _ = PlexOptimizePollHealthPolicy.register(.authRejected, state: &state)
        #expect(state.consecutiveAuthRejections == 1)
    }

    @Test("Unreachable diagnostic is emitted once per bucket, not every poll")
    func bucketedEmission() {
        var state = PlexOptimizePollHealthPolicy.State()
        var emissions: [(bucket: String, count: Int)] = []
        for _ in 0..<120 {
            if case .emitUnreachable(let bucket, let count) =
                PlexOptimizePollHealthPolicy.register(.failure, state: &state) {
                emissions.append((bucket, count))
            }
        }
        #expect(emissions.map(\.bucket) == ["3-9", "10-29", "30-99", "100-299"])
        #expect(emissions.map(\.count) == [3, 10, 30, 100])
    }

    @Test("Recovery then re-degradation re-emits from the first bucket")
    func reemitAfterRecovery() {
        var state = PlexOptimizePollHealthPolicy.State()
        for _ in 0..<5 { _ = PlexOptimizePollHealthPolicy.register(.failure, state: &state) }
        _ = PlexOptimizePollHealthPolicy.register(.success, state: &state)
        var reEmitted: String?
        for _ in 0..<3 {
            if case .emitUnreachable(let bucket, _) =
                PlexOptimizePollHealthPolicy.register(.failure, state: &state) {
                reEmitted = bucket
            }
        }
        #expect(reEmitted == "3-9")
    }

    @Test("Failure buckets are log-scaled with a floor of 3")
    func bucketBoundaries() {
        #expect(PlexOptimizePollHealthPolicy.failureBucket(0) == nil)
        #expect(PlexOptimizePollHealthPolicy.failureBucket(2) == nil)
        #expect(PlexOptimizePollHealthPolicy.failureBucket(3) == "3-9")
        #expect(PlexOptimizePollHealthPolicy.failureBucket(9) == "3-9")
        #expect(PlexOptimizePollHealthPolicy.failureBucket(10) == "10-29")
        #expect(PlexOptimizePollHealthPolicy.failureBucket(299) == "100-299")
        #expect(PlexOptimizePollHealthPolicy.failureBucket(1000) == "1000+")
    }
}

@Suite("Terminal auth message mapping")
struct DownloadTerminalAuthMessagePolicyTests {
    @Test("Exact 401/403 terminal messages map to auth-dead")
    func authDeadMessages() {
        #expect(DownloadTerminalAuthMessagePolicy.isAuthDeadTransferMessage("Server returned HTTP 401."))
        #expect(DownloadTerminalAuthMessagePolicy.isAuthDeadTransferMessage("Server returned HTTP 403."))
    }

    @Test("Other terminal messages are never remapped")
    func nonAuthMessages() {
        #expect(!DownloadTerminalAuthMessagePolicy.isAuthDeadTransferMessage("Server returned HTTP 404."))
        #expect(!DownloadTerminalAuthMessagePolicy.isAuthDeadTransferMessage("Server returned HTTP 500."))
        #expect(!DownloadTerminalAuthMessagePolicy.isAuthDeadTransferMessage("Server returned HTTP 401"))
        #expect(!DownloadTerminalAuthMessagePolicy.isAuthDeadTransferMessage("Transfer timed out."))
        #expect(!DownloadTerminalAuthMessagePolicy.isAuthDeadTransferMessage(""))
    }
}
