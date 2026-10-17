import Foundation

/// B60 / IC-4: gate a Jellyfin or Emby download keepalive on the session actually tracking a
/// transfer for the row's exact attempt. Store status alone is not enough: a `.queued` row whose
/// `session.start` threw, or whose task was lost, kept POSTing keepalives every tick, holding a
/// dead encoder alive and defeating the server's idle kill.
///
/// One untracked tick is tolerated without sending anything, because the first tick can race
/// `session.start` and a stall restart briefly has no task. A second consecutive untracked tick
/// stops the loop; the ensure gate restarts it once a transfer is tracked again.
public struct DownloadKeepaliveTransferGate: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Send this tick's keepalive requests.
        case send
        /// Send nothing this tick and check again on the next one.
        case skip
        /// End the keepalive loop.
        case stop
    }

    public static let untrackedTicksBeforeStop = 2

    public private(set) var consecutiveUntrackedTicks = 0

    public init() {}

    public mutating func evaluate(isTrackingTransfer: Bool) -> Action {
        guard !isTrackingTransfer else {
            consecutiveUntrackedTicks = 0
            return .send
        }
        consecutiveUntrackedTicks += 1
        return consecutiveUntrackedTicks >= Self.untrackedTicksBeforeStop ? .stop : .skip
    }

    /// The ensure (reconcile) gate: never start a keepalive for a row with no tracked transfer.
    public static func shouldStart(isTrackingTransfer: Bool) -> Bool {
        isTrackingTransfer
    }
}
