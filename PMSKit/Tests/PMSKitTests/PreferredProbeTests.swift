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
    // Every still-pending probe, including the slower relay, is cancelled.
    #expect(await log.cancelled == [1, 2, 3])
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
