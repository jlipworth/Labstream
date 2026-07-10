import Foundation

/// Pure health accounting for the Plex optimize server-prep poller (audit lens 8, A-1).
///
/// The poller can run for the entire server render (potentially hours) and previously had no HTTP
/// feedback at all: the metadata fetch swallowed every failure to `nil`, so a revoked token, a
/// re-login, or an unreachable server was indistinguishable from a slow render — the loop kept
/// issuing 3–4 requests per interval forever behind "Preparing on server…". This policy pins:
///  - a small consecutive budget of auth-rejected (401/403) polls before the attempt goes
///    terminal with an auth-specific error, and
///  - bucketed emission for the `downloads.optimize_poll_unreachable` diagnostic so an
///    unreachable/auth-dead loop is visible in the jsonl without logging every poll tick.
public enum PlexOptimizePollHealthPolicy {
    /// Consecutive auth-rejected (401/403) metadata polls tolerated before the attempt is
    /// declared auth-dead terminal. Small: a rejected token does not heal by re-polling, but a
    /// proxy hiccup can produce a one-off 401.
    public static let authRejectionBudget = 3

    /// One metadata poll's outcome, classified by the app layer from the typed client error.
    public enum FetchOutcome: Equatable, Sendable {
        /// The fetch decoded (the item may still lack the rendered Part — that is progress, not failure).
        case success
        /// HTTP 401/403 — the credential was rejected.
        case authRejected
        /// Unreachable / non-auth HTTP failure / undecodable body.
        case failure
    }

    /// Mutable per-attempt counters owned by the poll loop.
    public struct State: Equatable, Sendable {
        public var consecutiveFailures: Int
        public var consecutiveAuthRejections: Int
        public var lastEmittedBucket: String?

        public init(consecutiveFailures: Int = 0,
                    consecutiveAuthRejections: Int = 0,
                    lastEmittedBucket: String? = nil) {
            self.consecutiveFailures = consecutiveFailures
            self.consecutiveAuthRejections = consecutiveAuthRejections
            self.lastEmittedBucket = lastEmittedBucket
        }
    }

    public enum Action: Equatable, Sendable {
        case none
        /// Emit one `downloads.optimize_poll_unreachable` diagnostic for this bucket boundary.
        case emitUnreachable(bucket: String, consecutiveFailures: Int)
        /// Stop polling and fail the row terminally with an auth-specific message.
        case failAuthDead
    }

    /// Fold one poll outcome into the attempt's state and decide the side effect.
    public static func register(_ outcome: FetchOutcome, state: inout State) -> Action {
        switch outcome {
        case .success:
            // Full reset (including the emitted-bucket watermark) so a later re-degradation
            // re-emits from the first bucket instead of staying silent.
            state = State()
            return .none
        case .authRejected:
            state.consecutiveAuthRejections += 1
            state.consecutiveFailures += 1
            if state.consecutiveAuthRejections >= authRejectionBudget {
                return .failAuthDead
            }
            return unreachableActionIfNeeded(&state)
        case .failure:
            state.consecutiveAuthRejections = 0
            state.consecutiveFailures += 1
            return unreachableActionIfNeeded(&state)
        }
    }

    /// Coarse log-scale bucket for consecutive failed polls; nil below the reporting floor.
    /// One diagnostic per bucket keeps a multi-hour dead loop to a handful of lines.
    public static func failureBucket(_ consecutiveFailures: Int) -> String? {
        switch consecutiveFailures {
        case ..<3: return nil
        case 3..<10: return "3-9"
        case 10..<30: return "10-29"
        case 30..<100: return "30-99"
        case 100..<300: return "100-299"
        case 300..<1000: return "300-999"
        default: return "1000+"
        }
    }

    private static func unreachableActionIfNeeded(_ state: inout State) -> Action {
        guard let bucket = failureBucket(state.consecutiveFailures),
              bucket != state.lastEmittedBucket else { return .none }
        state.lastEmittedBucket = bucket
        return .emitUnreachable(bucket: bucket, consecutiveFailures: state.consecutiveFailures)
    }
}
