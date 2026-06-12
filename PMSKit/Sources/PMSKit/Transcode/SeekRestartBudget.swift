import Foundation

/// Rate-limit policy for seek-triggered transcode restarts (#27). Each restart costs PMS a
/// fresh (possibly software) transcoder job; restarts stacking faster than PMS reaps them is
/// the mechanism behind the live server OOM (docs/PLEX_AVP_TRANSCODE_OOM_REPORT.md). Pure and
/// clock-injected — the caller passes a monotonic `now` (e.g. `ProcessInfo.systemUptime`) —
/// so the whole abusive-session shape is unit-testable without timers.
///
/// Two layers, mirroring what the player enforces:
/// - **Cooldown**: a restart under `cooldownSeconds` after the last allowed one is
///   `.deferred` — the caller re-arms its confirmation for the remainder rather than
///   dropping the restart. Deferred attempts are not recorded.
/// - **Burst budget**: more than `burstLimit` allowed restarts inside the rolling
///   `burstWindowSeconds` means the stream can't actually sustain playback — `.escalate`
///   tells the caller to surface failure UI instead of silently rebuilding. A rolling
///   window, not a lifetime cap: spaced-out restarts over a long session stay allowed.
///
/// `reset()` on explicit user intent (Retry, quality reload) restores everything.
public struct SeekRestartBudget: Sendable, Equatable {
    /// The answer to "may I restart the transcode now?".
    public enum Verdict: Sendable, Equatable {
        /// Restart now; the attempt has been recorded against the burst window.
        case allow
        /// Inside the cooldown — re-check in `remaining` seconds. Not recorded.
        case deferred(remaining: TimeInterval)
        /// Burst budget exhausted — stop self-healing and put the viewer in charge.
        /// `recentCount` is how many restarts sit in the window (for logging). Not recorded.
        case escalate(recentCount: Int)
    }

    private let cooldownSeconds: TimeInterval
    private let burstLimit: Int
    private let burstWindowSeconds: TimeInterval
    /// Monotonic timestamps of recent ALLOWED restarts, pruned to the burst window.
    /// `last` doubles as the cooldown reference.
    private var recentRestarts: [TimeInterval] = []

    public init(cooldownSeconds: TimeInterval, burstLimit: Int, burstWindowSeconds: TimeInterval) {
        self.cooldownSeconds = cooldownSeconds
        self.burstLimit = burstLimit
        self.burstWindowSeconds = burstWindowSeconds
    }

    /// Ask permission for a restart at monotonic time `now`. Only `.allow` records the
    /// attempt — deferred/escalated attempts must not consume budget, or hammering inside
    /// the cooldown would escalate a session that only ever reached PMS twice.
    public mutating func requestRestart(now: TimeInterval) -> Verdict {
        if let last = recentRestarts.last {
            let remaining = cooldownSeconds - (now - last)
            if remaining > 0 {
                return .deferred(remaining: remaining)
            }
        }
        recentRestarts.removeAll { now - $0 > burstWindowSeconds }
        if recentRestarts.count >= burstLimit {
            return .escalate(recentCount: recentRestarts.count)
        }
        recentRestarts.append(now)
        return .allow
    }

    /// Clear the window and cooldown — call on user-intent rebuilds (Retry, quality reload)
    /// so an explicit Retry restores self-healing.
    public mutating func reset() {
        recentRestarts.removeAll()
    }
}
