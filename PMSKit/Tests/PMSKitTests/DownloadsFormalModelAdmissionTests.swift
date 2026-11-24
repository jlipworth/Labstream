import Foundation
import Testing
@testable import PMSKit

/// The TLA+ model of download admission (`specs/downloads/DownloadsAdmission.tla`,
/// `specs/downloads/DownloadsAdmission.md`).
///
/// The first tests tie the model's abstractions to the pure Swift decisions they stand for. The
/// finding tests state the behaviour the design wants and are wrapped in `withKnownIssue`, so
/// the suite stays green while a finding is open. When a fix lands the expectations hold, no
/// issue is recorded, and `withKnownIssue` fails the test: delete the wrapper then, and flip the
/// matching `Admission-Finding-*.cfg` to `EXPECT: pass`.
@Suite("Downloads formal-model admission")
struct DownloadsFormalModelAdmissionTests {
    private typealias R = DownloadLifecycleReducer
    private typealias Policy = DownloadAdmissionPolicy

    private static func waitingFirstStart() -> DownloadLifecycleState {
        var history = DownloadAttemptHistory.empty
        history.admissionIntent = .seasonPlanned
        return DownloadLifecycleState(lifecycle: .planned, history: history)
    }

    /// The model's pump grants "any maximal set of eligible requests that fits the caps"
    /// (`PumpPass`, `Fits`). Check that `grants` returns such a set for every small queue.
    @Test("Model abstraction: a pump pass grants a maximal set that fits the caps")
    func grantsAreAMaximalSetThatFits() {
        let lanes: [DownloadAdmissionLane] = [.staticFile, .liveForward]
        for total in DownloadAdmissionLimits.supportedTotals {
            let limits = DownloadAdmissionLimits(maximumTotal: total)
            // Three rows, each an occupant, a request or absent, in either lane.
            for code in 0..<Int(pow(6.0, 3.0)) {
                var occupants: [DownloadAdmissionOccupant] = []
                var requests: [DownloadAdmissionRequest] = []
                var digits = code
                for row in 0..<3 {
                    let digit = digits % 6
                    digits /= 6
                    let lane = lanes[digit % 2]
                    switch digit / 2 {
                    case 0: occupants.append(.init(id: "r\(row)", lane: lane))
                    case 1: requests.append(.init(id: "r\(row)", lane: lane, origin: .automatic,
                                                  requestedAt: 0))
                    default: break
                    }
                }
                func fits(_ extra: [DownloadAdmissionRequest]) -> Bool {
                    guard !extra.isEmpty else { return true }
                    guard occupants.count + extra.count <= limits.maximumTotal else { return false }
                    return lanes.allSatisfy { lane in
                        let added = extra.filter { $0.lane == lane }.count
                        let held = occupants.filter { $0.lane == lane }.count
                        return added == 0 || held + added <= (limits.maximumByLane[lane] ?? 1)
                    }
                }
                let granted = Policy.grants(limits: limits, occupants: occupants,
                                            requests: requests, now: 0, queuePaused: false)
                #expect(fits(granted))
                for other in requests where !granted.contains(other) {
                    #expect(!fits(granted + [other]), "a request that fits was left waiting")
                }
                // Pause All grants only exempt rows.
                let paused = Policy.grants(limits: limits, occupants: occupants,
                                           requests: requests, now: 0, queuePaused: true,
                                           pauseExemptIDs: ["r0"])
                #expect(paused.allSatisfy { $0.id == "r0" })
            }
        }
    }

    /// B65 as the model states it (`PauseKeepsFirstStart`, `UserPauseHolds`): a user pause keeps
    /// a waiting first start's intent and withdraws a waiting retry.
    @Test("Model property: a user pause keeps a first-start intent and withdraws a retry")
    func userPauseKeepsFirstStartAndWithdrawsRetry() {
        let facts = DownloadRowFacts(route: .forwardOnly)
        let paused = R.reduce(Self.waitingFirstStart(), .pause(.user), facts: facts).state
        #expect(paused?.lifecycle == .paused)
        #expect(paused?.history.admissionIntent == .seasonPlanned)

        var history = DownloadAttemptHistory.empty
        history.lastFailure = .network
        history.admissionIntent = .retryRequested
        let waitingRetry = DownloadLifecycleState(lifecycle: .failed, history: history)
        let withdrawn = R.reduce(waitingRetry, .admissionWithdrawn, facts: facts).state
        #expect(withdrawn?.lifecycle == .failed)
        #expect(withdrawn?.history.admissionIntent == nil)
    }

    /// B66 and B67 as the model states them (`NoOrphanQueued`, `OutageDefersFirstStart`): a
    /// granted start that left no work goes back to waiting with its intent.
    @Test("Model property: a granted start without work waits again")
    func grantedStartWithoutWorkWaitsAgain() {
        let facts = DownloadRowFacts(route: .forwardOnly)
        let granted = R.reduce(Self.waitingFirstStart(), .admissionGranted, facts: facts).state
        #expect(granted?.lifecycle == .admitted)
        let deferred = granted.flatMap {
            R.reduce($0, .admissionDeferred(.seasonPlanned), facts: facts).state
        }
        #expect(deferred?.lifecycle == .planned)
        #expect(deferred?.history.admissionIntent == .seasonPlanned)
    }

    /// A1. Startup recovery fails a forward-only row that never started.
    ///
    /// 1. The pump grants a waiting first start (`admissionGranted`: planned to admitted, intent
    ///    cleared). The process dies while the start is still refreshing the item, before any
    ///    transfer task exists. On relaunch the row has no task, no body and no checkpoint, so
    ///    `relaunchObserved` fails it with `network` and nothing asks for a lane again. Had the
    ///    same start ended in process, `finishAdmittedStart` would have sent `admissionDeferred`
    ///    and the row would wait again (B66, B67).
    /// 2. The user pauses a waiting first start (or taps Pause All on a queue of them). The row
    ///    is `paused(user)` and keeps `seasonPlanned`. After a relaunch the same rule fails it,
    ///    so a row the user only paused shows as a network failure.
    ///
    /// The static lane hides ordering 1: launch recovery re-drives an interrupted static row.
    @Test("A1: relaunch keeps a forward-only row that never started")
    func relaunchKeepsForwardOnlyRowThatNeverStarted() {
        withKnownIssue("TLA+ finding A1 (#475): relaunch fails a forward-only row that never started") {
            let noWork = DownloadRowFacts(route: .forwardOnly)

            // Ordering 1: granted, then the process died before any work existed.
            let granted = try #require(
                R.reduce(Self.waitingFirstStart(), .admissionGranted, facts: noWork).state)
            let afterCrash = R.reduce(granted, .relaunchObserved, facts: noWork)
            #expect(afterCrash.state?.lifecycle != .failed)
            #expect(afterCrash.state.map { $0.lifecycle == .planned
                    || $0.history.admissionIntent != nil } == true,
                    "the row no longer waits for a lane")

            // Ordering 2: paused while it waited for its first start.
            let paused = try #require(
                R.reduce(Self.waitingFirstStart(), .pause(.user), facts: noWork).state)
            let pausedAfterCrash = R.reduce(paused, .relaunchObserved, facts: noWork)
            #expect(pausedAfterCrash.state?.lifecycle == .paused)
            #expect(pausedAfterCrash.state?.history.pauseCause == .user)
            #expect(pausedAfterCrash.state?.history.admissionIntent == .seasonPlanned)
        }
    }
}
