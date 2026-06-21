import Testing
@testable import PMSKit

/// #93: the Home builder must distinguish a rail that legitimately returned no items from
/// a rail whose request *errored*, so a partial (degraded) Home is not cached as
/// authoritative. These cover the pure decision logic that drives that.
struct HomeRailsLoadTests {
    private struct ProbeError: Error {}

    @Test func cleanLoadIsNotDegraded() async {
        var tracker = HomeRailsLoadTracker()
        let a = await tracker.attempt { [1, 2, 3] }
        let b = await tracker.attempt { [4] }
        #expect(a == [1, 2, 3])
        #expect(b == [4])
        #expect(tracker.isDegraded == false)
    }

    @Test func emptyButSuccessfulRailIsNotDegraded() async {
        var tracker = HomeRailsLoadTracker()
        let empty: [Int] = await tracker.attempt { [] } ?? []
        #expect(empty.isEmpty)
        #expect(tracker.isDegraded == false)
    }

    @Test func aThrownRailMarksDegradedAndYieldsNil() async {
        var tracker = HomeRailsLoadTracker()
        let result: [Int]? = await tracker.attempt { throw ProbeError() }
        #expect(result == nil)
        #expect(tracker.isDegraded == true)
    }

    @Test func degradedStaysDegradedAfterLaterSuccess() async {
        var tracker = HomeRailsLoadTracker()
        _ = await tracker.attempt { throw ProbeError() } as [Int]?
        let later = await tracker.attempt { [9] }
        #expect(later == [9])
        // One failure poisons the whole load — a later success does NOT clear it, so the
        // partial result is treated as not-authoritative.
        #expect(tracker.isDegraded == true)
    }

    @Test func recordSuccessResultPassesValueThrough() {
        var tracker = HomeRailsLoadTracker()
        let value = tracker.record(Result<[Int], Error>.success([7, 8]))
        #expect(value == [7, 8])
        #expect(tracker.isDegraded == false)
    }

    @Test func recordFailureResultMarksDegraded() {
        var tracker = HomeRailsLoadTracker()
        let value = tracker.record(Result<[Int], Error>.failure(ProbeError()))
        #expect(value == nil)
        #expect(tracker.isDegraded == true)
    }

    @Test func mixedSuccessAndFailureIsDegraded() async {
        var tracker = HomeRailsLoadTracker()
        let ok = tracker.record(Result<[Int], Error>.success([1]))           // continue watching
        let nextUp = tracker.record(Result<[Int], Error>.failure(ProbeError())) // next up errored
        let latest = await tracker.attempt { [2, 3] }                        // a library rail ok
        #expect(ok == [1])
        #expect(nextUp == nil)
        #expect(latest == [2, 3])
        #expect(tracker.isDegraded == true)
    }

    @Test func homeRailsLoadWrapsRailsAndFlag() {
        let degraded = HomeRailsLoad(rails: [1, 2], isDegraded: true)
        #expect(degraded.rails == [1, 2])
        #expect(degraded.isDegraded == true)

        let clean = HomeRailsLoad(rails: [3], isDegraded: false)
        #expect(clean.rails == [3])
        #expect(clean.isDegraded == false)
    }
}
