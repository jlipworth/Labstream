import Foundation
import Testing
@testable import PMSKit

/// The TLA+ model of download admission (`specs/downloads/admission/DownloadsAdmission.tla`,
/// `specs/downloads/admission/README.md`).
///
/// The first tests tie the model's abstractions to the pure Swift decisions they stand for. The
/// finding tests state the behaviour the design wants and are wrapped in `withKnownIssue`, so
/// the suite stays green while a finding is open. When a fix lands the expectations hold, no
/// issue is recorded, and `withKnownIssue` fails the test: delete the wrapper then, and flip the
/// matching `admission/Finding-*.cfg` to `EXPECT: pass`.
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

    /// `GrantRespectsObservedOccupancy` in the model: occupants are counted as they are observed,
    /// over a cap or not, and nothing new enters the total or a lane that is at or over its
    /// cap. The setting can be lowered while work runs and a reused Emby source hands off with
    /// no slot, so "occupancy is within the cap" is not an invariant of the app; this is.
    @Test("Model property: a grant respects observed occupancy, from over-cap states too")
    func grantsRespectObservedOccupancyWhenOverCap() {
        let lanes: [DownloadAdmissionLane] = [.staticFile, .liveForward]
        for total in DownloadAdmissionLimits.supportedTotals {
            let limits = DownloadAdmissionLimits(maximumTotal: total)
            for staticHeld in 0...5 { for forwardHeld in 0...2 {
                var occupants: [DownloadAdmissionOccupant] = []
                for index in 0..<staticHeld { occupants.append(.init(id: "s\(index)", lane: .staticFile)) }
                for index in 0..<forwardHeld { occupants.append(.init(id: "f\(index)", lane: .liveForward)) }
                let requests = lanes.flatMap { lane in
                    (0..<2).map { DownloadAdmissionRequest(
                        id: "q-\(lane.rawValue)-\($0)", lane: lane, origin: .user, requestedAt: 0) }
                }
                let granted = Policy.grants(limits: limits, occupants: occupants,
                                            requests: requests, now: 0, queuePaused: false)
                let held: [DownloadAdmissionLane: Int] = [.staticFile: staticHeld,
                                                          .liveForward: forwardHeld]
                if !granted.isEmpty {
                    #expect(occupants.count + granted.count <= limits.maximumTotal)
                }
                for lane in lanes {
                    let added = granted.filter { $0.lane == lane }.count
                    if added > 0 {
                        #expect((held[lane] ?? 0) + added <= (limits.maximumByLane[lane] ?? 1))
                    }
                }
            } }
        }
    }

    /// The three ways the model lets occupancy or the daemon's task count pass a cap, each tied
    /// to the app source: `SetCap` (the coordinator only wakes admission when the setting
    /// changes), `ReuseRows` (a reused Emby source hands off without waiting for a slot) and
    /// `cancelling` (a pause drops its tracking before the task enumeration that cancels).
    @Test("Model abstraction: a lowered setting, an Emby reuse and a pending cancel keep their work")
    func supportedWaysPastACap() throws {
        let coordinator = try #require(Self.appFile(
            "Labstream/Capabilities/Downloads/Core/DownloadAdmissionCoordinator.swift"))
        #expect(coordinator.contains(
            "// Only wake admission. Running work, generations and requests are untouched."))
        #expect(coordinator.contains(
            "DownloadAdmissionLimits(maximumTotal: PlaybackPreferences.simultaneousDownloads(defaults: defaults))"))

        let emby = try #require(Self.appFile(
            "Labstream/Capabilities/Downloads/Core/DownloadManager+EmbyConvert.swift"))
        #expect(emby.components(separatedBy: "waitsForTransferSlot: false)").count == 3)
        #expect(emby.contains("if waitsForTransferSlot {"))

        let session = try #require(Self.appFile(
            "Labstream/Capabilities/Downloads/Core/BackgroundDownloadSession.swift"))
        let pause = try #require(session.range(of: "    func pause(ratingKey: String) {"))
        let body = session[pause.lowerBound...]
        let untrack = try #require(body.range(of: "stopHealthResults(for: attemptKey, outcome: \"paused\")"))
        let enumerate = try #require(body.range(of: "urlSession.getAllTasks { tasks in"))
        #expect(untrack.lowerBound < enumerate.lowerBound)
    }

    private static func appFile(_ relativePath: String) -> String? {
        // PMSKit/Tests/PMSKitTests/<this file> -> repository root.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// `FirstStartGoesThroughWindow` in the model (B65): Resume of a row that still carries the
    /// first-start intent asks the window again instead of starting it as a generic retry.
    @Test("Model property: Resume of a paused first start asks the window again")
    func resumeOfPausedFirstStartAsksTheWindow() throws {
        let admission = try #require(Self.appFile(
            "Labstream/Capabilities/Downloads/Core/DownloadManager+Admission.swift"))
        let action = try #require(admission.range(of: "    func admitRowAction(_ record: DownloadRecord) {"))
        let body = admission[action.lowerBound...]
        let firstStart = try #require(body.range(
            of: "if record.admissionIntent == .seasonPlanned || record.lifecycle == .planned {"))
        let direct = try #require(body.range(of: "launchAdmittedStart(record, lane: lane, origin: .user)"))
        #expect(firstStart.lowerBound < direct.lowerBound)

        let facts = DownloadRowFacts(route: .forwardOnly)
        let paused = try #require(R.reduce(Self.waitingFirstStart(), .pause(.user), facts: facts).state)
        let asked = R.reduce(paused, .admissionRequested(.seasonPlanned), facts: facts).state
        #expect(asked?.lifecycle == .planned)
        #expect(asked?.history.admissionIntent == .seasonPlanned)
    }

    /// `PauseKeepsFirstStart` and `UserPauseHolds` in the model: a user pause keeps a waiting
    /// first start's intent and withdraws a waiting retry. (B65 itself was the Resume that
    /// bypassed the window; the pause never erased the mark. `Mutant-PauseErasesFirstStart.cfg`
    /// is the erasure.)
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

    /// A1 (#475, fixed). Startup recovery used to fail a forward-only row that never started:
    ///
    /// 1. The pump grants a waiting first start (`admissionGranted`: planned to admitted, intent
    ///    cleared). The process dies while the start is still refreshing the item, before any
    ///    transfer task exists. On relaunch the row has no task, no body and no checkpoint;
    ///    `relaunchObserved` failed it with `network` and nothing asked for a lane again. In
    ///    process `finishAdmittedStart` sends `admissionDeferred` and the row waits again (B66,
    ///    B67); relaunch now does the same.
    /// 2. The user pauses a waiting first start (or taps Pause All on a queue of them). The row
    ///    is `paused(user)` and keeps `seasonPlanned`. Relaunch failed it, so a row the user only
    ///    paused showed as a network failure; it now stays paused with its intent.
    ///
    /// The static lane hid ordering 1: launch recovery re-drives an interrupted static row.
    /// `specs/downloads/admission/Faithful-A1-off.cfg` keeps the old behaviour as a violation.
    @Test("A1: relaunch keeps a forward-only row that never started")
    func relaunchKeepsForwardOnlyRowThatNeverStarted() throws {
        let noWork = DownloadRowFacts(route: .forwardOnly)

        // Ordering 1: granted, then the process died before any work existed.
        let granted = try #require(
            R.reduce(Self.waitingFirstStart(), .admissionGranted, facts: noWork).state)
        let afterCrash = R.reduce(granted, .relaunchObserved, facts: noWork)
        #expect(afterCrash.state?.lifecycle != .failed)
        #expect(afterCrash.state.map { $0.lifecycle == .planned
                || $0.history.admissionIntent != nil } == true,
                "the row no longer waits for a lane")
        #expect(afterCrash.state?.lifecycle == .planned)
        #expect(afterCrash.state?.history.admissionIntent == .seasonPlanned)
        #expect(afterCrash.effects.isEmpty)

        // Ordering 2: paused while it waited for its first start.
        let paused = try #require(
            R.reduce(Self.waitingFirstStart(), .pause(.user), facts: noWork).state)
        let pausedAfterCrash = R.reduce(paused, .relaunchObserved, facts: noWork)
        #expect(pausedAfterCrash.state?.lifecycle == .paused)
        #expect(pausedAfterCrash.state?.history.pauseCause == .user)
        #expect(pausedAfterCrash.state?.history.admissionIntent == .seasonPlanned)
        #expect(pausedAfterCrash.effects.isEmpty)
    }
}
