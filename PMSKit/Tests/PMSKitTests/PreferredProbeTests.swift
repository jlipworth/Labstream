import Testing
import Foundation
@testable import PMSKit

/// Records which probes observed cancellation.
private actor CancellationLog {
    private(set) var cancelled: Set<Int> = []
    func record(_ index: Int) { cancelled.insert(index) }
}

/// A fake probe: sleeps `delay`, then returns `index` when `succeeds`, otherwise nil.
/// A cancelled sleep is recorded and reported as a failure.
private func fakeProbe(delays: [Duration], successes: Set<Int>,
                       log: CancellationLog? = nil) -> @Sendable (Int) async -> Int? {
    { index in
        do {
            try await Task.sleep(for: delays[index])
        } catch {
            await log?.record(index)
            return nil
        }
        return successes.contains(index) ? index : nil
    }
}

@Test func preferredSuccessDoesNotWaitForDeadLowerPreferenceCandidates() async {
    // Preferred LAN answers quickly; two dead interfaces hang far longer than the test
    // tolerance; a relay also answers. The drain-all selection waited for the dead ones.
    let log = CancellationLog()
    let clock = ContinuousClock()
    let start = clock.now
    let result = await PreferredProbe.firstSuccess(
        count: 4,
        fakeProbe(delays: [.milliseconds(10), .seconds(30), .seconds(30), .milliseconds(50)],
                  successes: [0, 3], log: log))
    let elapsed = clock.now - start
    #expect(result?.index == 0)
    #expect(result?.value == 0)
    #expect(elapsed < .seconds(5))
    // Every still-pending probe, including the slower relay, is cancelled. Losers wind down
    // in the background, after the result has already been returned.
    #expect(await eventually { await log.cancelled == [1, 2, 3] })
}

@Test func fasterLowerPreferenceSuccessWaitsForPendingPreferredCandidate() async {
    // The relay answers first, but the preferred candidate is still pending and then
    // succeeds: preference wins over speed.
    let result = await PreferredProbe.firstSuccess(
        count: 2,
        fakeProbe(delays: [.milliseconds(80), .milliseconds(5)], successes: [0, 1]))
    #expect(result?.index == 0)
}

@Test func failedPreferredCandidatesFallThroughToNextSuccess() async {
    let result = await PreferredProbe.firstSuccess(
        count: 3,
        fakeProbe(delays: [.milliseconds(20), .milliseconds(5), .milliseconds(10)],
                  successes: [2]))
    #expect(result?.index == 2)
}

@Test func allFailedReturnsNil() async {
    let result = await PreferredProbe.firstSuccess(
        count: 3,
        fakeProbe(delays: [.milliseconds(5), .milliseconds(1), .milliseconds(3)], successes: []))
    #expect(result == nil)
}

@Test func emptyCandidatesReturnNilWithoutProbing() async {
    let result = await PreferredProbe.firstSuccess(count: 0) { (_: Int) -> Int? in
        Issue.record("probe must not run")
        return 0
    }
    #expect(result == nil)
}

/// Tracks how many probes run at once and which indices were ever started.
private actor ConcurrencyGauge {
    private(set) var current = 0
    private(set) var peak = 0
    private(set) var started: Set<Int> = []
    func enter(_ index: Int) { current += 1; peak = max(peak, current); started.insert(index) }
    func leave() { current -= 1 }
}

private func gaugedProbe(delays: [Duration], successes: Set<Int>,
                         gauge: ConcurrencyGauge) -> @Sendable (Int) async -> Int? {
    { index in
        await gauge.enter(index)
        let finished = (try? await Task.sleep(for: delays[index])) != nil
        await gauge.leave()
        return finished && successes.contains(index) ? index : nil
    }
}

@Test func boundedWindowCapsConcurrencyAndKeepsPreferenceOrder() async {
    // Six failing candidates ahead of the only success: with a window of two, no more than
    // two probes run at once, and the success is still found once every earlier one fails.
    let gauge = ConcurrencyGauge()
    let result = await PreferredProbe.firstSuccess(
        count: 7, maxConcurrent: 2,
        gaugedProbe(delays: [.milliseconds(10), .milliseconds(5), .milliseconds(15),
                             .milliseconds(5), .milliseconds(10), .milliseconds(5),
                             .milliseconds(5)],
                    successes: [6], gauge: gauge))
    #expect(result?.index == 6)
    #expect(await gauge.peak == 2)
    #expect(await gauge.started == Set(0..<7))
}

@Test func boundedWindowNeverStartsCandidatesAfterPreferredSuccess() async {
    // The preferred candidate answers while the window is full; candidates beyond the
    // window are never contacted.
    let gauge = ConcurrencyGauge()
    let result = await PreferredProbe.firstSuccess(
        count: 6, maxConcurrent: 2,
        gaugedProbe(delays: [.milliseconds(5), .seconds(30), .milliseconds(5),
                             .milliseconds(5), .milliseconds(5), .milliseconds(5)],
                    successes: [0, 4], gauge: gauge))
    #expect(result?.index == 0)
    #expect(await gauge.started == [0, 1])
}

/// Polls `condition` for up to two seconds.
private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// A probe that ignores cancellation, like a connection attempt the system keeps open
/// until its own timeout: it always takes `delays[index]`.
private func uncancellableProbe(delays: [Duration], successes: Set<Int>) -> @Sendable (Int) async -> Int? {
    { index in
        let nanoseconds = UInt64(delays[index].components.seconds) * 1_000_000_000
            + UInt64(delays[index].components.attoseconds / 1_000_000_000)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) {
                continuation.resume()
            }
        }
        return successes.contains(index) ? index : nil
    }
}

@Test func resultDoesNotWaitForLosersThatIgnoreCancellation() async {
    // The preferred candidate answers at once; a lower-ranked one ignores cancellation and
    // takes 3 s. The result must not wait for it to wind down.
    let clock = ContinuousClock()
    let start = clock.now
    let result = await PreferredProbe.firstSuccess(
        count: 2,
        uncancellableProbe(delays: [.milliseconds(10), .seconds(3)], successes: [0]))
    #expect(result?.index == 0)
    #expect(clock.now - start < .seconds(1))
}

private let directOnly = PreferredProbe.EarlyAcceptance(grace: .milliseconds(100)) { $0 != 2 }

@Test func graceAcceptsLowerRankedSuccessWhenPreferredCandidateHangs() async {
    // The preferred (local) candidate is unroutable and hangs until its timeout; the remote
    // one answers. After the grace, the remote one wins instead of waiting the full timeout.
    let clock = ContinuousClock()
    let start = clock.now
    let result = await PreferredProbe.firstSuccess(
        count: 2, earlyAcceptance: directOnly,
        uncancellableProbe(delays: [.seconds(3), .milliseconds(10)], successes: [1]))
    #expect(result?.index == 1)
    #expect(clock.now - start < .seconds(1))
}

@Test func preferredCandidateAnsweringWithinGraceStillWins() async {
    // The remote candidate answers first, but the preferred one answers inside the grace.
    let result = await PreferredProbe.firstSuccess(
        count: 2, earlyAcceptance: PreferredProbe.EarlyAcceptance(grace: .milliseconds(400)) { _ in true },
        fakeProbe(delays: [.milliseconds(60), .milliseconds(5)], successes: [0, 1]))
    #expect(result?.index == 0)
}

@Test func ineligibleSuccessNeverWinsEarly() async {
    // Only a relay (index 2) has answered; relays may not win early, so the preferred
    // candidate is awaited even though it answers well after the grace.
    let result = await PreferredProbe.firstSuccess(
        count: 3, earlyAcceptance: directOnly,
        fakeProbe(delays: [.milliseconds(300), .milliseconds(5), .milliseconds(5)],
                  successes: [0, 2]))
    #expect(result?.index == 0)
}

@Test func graceElapsingPicksTheBestEligibleSuccessSoFar() async {
    // Index 0 hangs; indices 2 and 1 answer in that order inside the grace. The best
    // (lowest-ranked) eligible success wins, not the first to answer.
    let early = PreferredProbe.EarlyAcceptance(grace: .milliseconds(150)) { _ in true }
    let result = await PreferredProbe.firstSuccess(
        count: 3, earlyAcceptance: early,
        uncancellableProbe(delays: [.seconds(3), .milliseconds(40), .milliseconds(5)],
                           successes: [1, 2]))
    #expect(result?.index == 1)
}

@Test func callerCancellationReturnsNilAndCancelsProbes() async {
    let log = CancellationLog()
    let task = Task {
        await PreferredProbe.firstSuccess(
            count: 2,
            fakeProbe(delays: [.seconds(30), .seconds(30)], successes: [0, 1], log: log))
    }
    try? await Task.sleep(for: .milliseconds(50))
    task.cancel()
    let result = await task.value
    #expect(result == nil)
    #expect(await eventually { await log.cancelled == [0, 1] })
}
