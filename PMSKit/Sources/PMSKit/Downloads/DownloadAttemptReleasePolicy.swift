import Foundation

/// Pure ownership decision for releasing asynchronous download work.
///
/// A rating key is reusable: attempt A can finish unwinding after attempt B has already acquired
/// the same visible row/slot. Teardown must therefore always target A's exact resources, while
/// rating-key presentation and admission state may only be cleared when A is still its owner.
/// Ownerless legacy recovery is deliberately outside this policy and must use an explicit repair
/// path rather than making an exact release behave like an unconditional rating-key clear.
public enum DownloadAttemptReleasePolicy {
    public struct Plan: Sendable, Equatable {
        /// The only owner whose task/session/keepalive/finalizer resources may be torn down.
        public let exactResourceOwner: DownloadAttemptKey

        /// Whether rating-key admission/presentation state is still owned by the released attempt.
        public let releaseCurrentState: Bool
    }

    public static func plan(
        releasing releasedAttempt: DownloadAttemptKey,
        currentOwner: DownloadAttemptKey?
    ) -> Plan {
        Plan(
            exactResourceOwner: releasedAttempt,
            releaseCurrentState: currentOwner == releasedAttempt
        )
    }
}
