/// Bounded health accounting for the Emby server-side convert status poller.
///
/// A healthy conversion may legitimately run for hours, so elapsed render time is not a failure.
/// What must be bounded is a continuously unreachable/5xx/undecodable status endpoint: without a
/// success reset the app otherwise polls forever behind "Preparing on server…". At the production
/// five-second cadence, sixty consecutive failures allow roughly five minutes for a server restart
/// or transient network outage before surfacing a retryable terminal row.
public enum EmbyConvertPollHealthPolicy {
    public static let consecutiveFailureBudget = 60

    public struct State: Equatable, Sendable {
        public var consecutiveFailures: Int

        public init(consecutiveFailures: Int = 0) {
            self.consecutiveFailures = consecutiveFailures
        }
    }

    public enum Action: Equatable, Sendable {
        case keepPolling
        case failPersistent
    }

    public static func registerFailure(state: inout State) -> Action {
        state.consecutiveFailures += 1
        return state.consecutiveFailures >= consecutiveFailureBudget ? .failPersistent : .keepPolling
    }

    public static func registerSuccess(state: inout State) {
        state.consecutiveFailures = 0
    }
}
