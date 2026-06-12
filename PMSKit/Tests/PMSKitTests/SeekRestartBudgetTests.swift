import Testing
import Foundation
@testable import PMSKit

/// #27 guard-rail policy, extracted from PlaybackController so the "spam PMS with restart
/// requests" scenario is a permanent regression test instead of a live-only check. The clock
/// is injected (`now:` is a monotonic uptime), so these tests replay an entire abusive
/// session in microseconds.
///
/// Policy under test (must mirror what the player ships):
/// - restarts under `cooldownSeconds` apart are deferred (caller re-arms), NOT recorded
/// - more than `burstLimit` restarts inside a rolling `burstWindowSeconds` escalates to the
///   viewer instead of silently rebuilding; escalation does not consume budget
/// - the window rolls off — old restarts age out, long sessions self-heal indefinitely
/// - `reset()` (user-intent Retry / quality reload) restores everything

private func makeBudget() -> SeekRestartBudget {
    SeekRestartBudget(cooldownSeconds: 5, burstLimit: 3, burstWindowSeconds: 60)
}

@Test func firstRestartIsAllowed() {
    var budget = makeBudget()
    #expect(budget.requestRestart(now: 100) == .allow)
}

@Test func restartInsideCooldownIsDeferredWithRemainingTime() {
    var budget = makeBudget()
    #expect(budget.requestRestart(now: 100) == .allow)
    guard case .deferred(let remaining) = budget.requestRestart(now: 102) else {
        Issue.record("expected .deferred inside the 5s cooldown")
        return
    }
    #expect(abs(remaining - 3) < 0.0001)
}

@Test func restartExactlyAtCooldownBoundaryIsAllowed() {
    var budget = makeBudget()
    #expect(budget.requestRestart(now: 100) == .allow)
    #expect(budget.requestRestart(now: 105) == .allow)
}

@Test func deferredAttemptsDoNotConsumeBurstBudget() {
    var budget = makeBudget()
    // A scrub-happy user hammering inside the cooldown: only the ALLOWED restarts may
    // count toward the burst window, or two allowed restarts + spam would escalate early.
    #expect(budget.requestRestart(now: 0) == .allow)
    #expect(budget.requestRestart(now: 1) == .deferred(remaining: 4))
    #expect(budget.requestRestart(now: 2) == .deferred(remaining: 3))
    #expect(budget.requestRestart(now: 3) == .deferred(remaining: 2))
    #expect(budget.requestRestart(now: 5) == .allow)
    #expect(budget.requestRestart(now: 10) == .allow)
    // Three allowed restarts in the window — the next one must escalate, no sooner.
    #expect(budget.requestRestart(now: 15) == .escalate(recentCount: 3))
}

@Test func fourthRestartInsideWindowEscalates() {
    var budget = makeBudget()
    #expect(budget.requestRestart(now: 0) == .allow)
    #expect(budget.requestRestart(now: 10) == .allow)
    #expect(budget.requestRestart(now: 20) == .allow)
    #expect(budget.requestRestart(now: 30) == .escalate(recentCount: 3))
}

@Test func escalationDoesNotRecordAndWindowRollsOff() {
    var budget = makeBudget()
    #expect(budget.requestRestart(now: 0) == .allow)
    #expect(budget.requestRestart(now: 10) == .allow)
    #expect(budget.requestRestart(now: 20) == .allow)
    #expect(budget.requestRestart(now: 30) == .escalate(recentCount: 3))
    // 65s later every recorded restart (0/10/20) has aged out of the 60s window; the
    // escalate attempt at t=30 must not have been recorded, so the budget is fully back.
    #expect(budget.requestRestart(now: 95) == .allow)
}

@Test func sustainedSpacedRestartsNeverEscalate() {
    // A long session on a slow server restarting every 25s forever is legitimate
    // self-healing — the rolling window must keep at most 2 priors in scope.
    var budget = makeBudget()
    for i in 0..<50 {
        let verdict = budget.requestRestart(now: TimeInterval(i) * 25)
        #expect(verdict == .allow, "restart \(i) at t=\(i * 25)s should be allowed")
    }
}

@Test func rapidFireSpamEscalatesExactlyOnceBudgetIsExhausted() {
    // The OOM-incident shape: starve→restart cycling as fast as the cooldown permits.
    // 5s spacing → restarts at 0, 5, 10 allowed; everything after that inside the window
    // must escalate rather than reach PMS.
    var budget = makeBudget()
    var allowed = 0
    var escalated = 0
    for t in stride(from: 0.0, through: 55.0, by: 5.0) {
        switch budget.requestRestart(now: t) {
        case .allow: allowed += 1
        case .escalate: escalated += 1
        case .deferred: Issue.record("5s spacing should never hit the cooldown")
        }
    }
    #expect(allowed == 3)
    #expect(escalated == 9)
}

@Test func resetRestoresBudgetAndCooldown() {
    var budget = makeBudget()
    #expect(budget.requestRestart(now: 0) == .allow)
    #expect(budget.requestRestart(now: 5) == .allow)
    #expect(budget.requestRestart(now: 10) == .allow)
    #expect(budget.requestRestart(now: 15) == .escalate(recentCount: 3))
    budget.reset()
    // Explicit user intent (Retry / quality reload) clears both the burst window and the
    // cooldown reference — self-healing resumes immediately.
    #expect(budget.requestRestart(now: 16) == .allow)
}
