import Foundation

/// Decides when the launch-only download recovery pass runs: hydrating inactive backends that own
/// active work, and sweeping orphaned server encoders. Both need a reachable server.
///
/// On a normal launch the session restore makes browse ready before the pass starts, so the pass
/// runs once. On an offline launch the pass runs while servers are unreachable and does nothing
/// useful. The first browse-ready edge after that (Reconnect) must run it again (B77). If that
/// edge arrives while the offline pass is still awaiting hydration, the rerun waits until the pass
/// finishes, so the two never overlap. The rerun happens at most once per process.
public struct LaunchDownloadRecoveryGate: Sendable, Equatable {
    private enum Phase: Sendable, Equatable {
        case notStarted
        case running(browseReadyAtStart: Bool)
        case finished(awaitingReadyEdge: Bool)
    }

    private var phase: Phase = .notStarted

    public init() {}

    public mutating func beginLaunchPass(browseReady: Bool) {
        phase = .running(browseReadyAtStart: browseReady)
    }

    /// Returns true when the caller must run the recovery pass again now.
    public mutating func finishLaunchPass(browseReady: Bool) -> Bool {
        guard case .running(let readyAtStart) = phase else { return false }
        if readyAtStart {
            phase = .finished(awaitingReadyEdge: false)
            return false
        }
        if browseReady {
            phase = .finished(awaitingReadyEdge: false)
            return true
        }
        phase = .finished(awaitingReadyEdge: true)
        return false
    }

    /// Returns true when the caller must run the recovery pass again now.
    public mutating func browseBecameReady() -> Bool {
        guard phase == .finished(awaitingReadyEdge: true) else { return false }
        phase = .finished(awaitingReadyEdge: false)
        return true
    }
}
