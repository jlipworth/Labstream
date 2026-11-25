import Foundation
import Testing
@testable import PMSKit

/// The recovery races an independent review found in the fixes for #472, #474, #475 and #476.
/// These are the host-testable halves: the publication ledger, the idempotent publication
/// step, the halted-progress decision and the reconcile snapshot rule. The session and store
/// run the same orderings in `LabstreamTests/DownloadRecoveryRaceTests.swift`.
@Suite("Download recovery races (review of #472, #474, #475, #476)")
struct DownloadRecoveryRaceReviewTests {
    private typealias Ledger = ForwardOnlyPublicationLedger<String, Int>

    // MARK: 1. One publication per captured body

    /// The delegate claims before it moves the body to the capture path. Recovery, which
    /// looks for a body at that path, then cannot claim it, in either order.
    @Test("Delegate and recovery cannot both own one body's publication")
    func onlyOneClaimWins() {
        let ledger = Ledger()
        // The delegate first: recovery arrives while the body is being captured.
        #expect(ledger.claim("capture"))
        #expect(!ledger.claim("capture"), "recovery must not queue a second publication")
        #expect(ledger.owner(of: "capture") == .worker)
        ledger.release("capture")
        #expect(ledger.owner(of: "capture") == nil)
        // Recovery first (a body captured by a process that died): a redelivered finish is the
        // second delivery.
        #expect(ledger.claim("capture"))
        #expect(!ledger.claim("capture"))
        // Another body is another claim.
        #expect(ledger.claim("other"))
    }

    @Test("Many racing claimers of one body: exactly one wins")
    func racingClaimers() {
        for _ in 0..<50 {
            let ledger = Ledger()
            let wins = Counter()
            DispatchQueue.concurrentPerform(iterations: 16) { _ in
                if ledger.claim("capture") { wins.increment() }
            }
            #expect(wins.value == 1)
        }
    }

    /// The publication the app runs once it holds the working path's lease, over real files:
    /// ask the policy, then move. Two of them run one after the other, as the lease orders them.
    @Test("Two publications of one body: the second leaves the published body alone")
    func twoPublishersKeepTheBody() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("publication-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = directory.appendingPathComponent("capture")
        let working = directory.appendingPathComponent("working")
        let body = Data(repeating: 7, count: 4_096)
        try body.write(to: capture)

        func publish() -> ForwardOnlyFinishedBodyPolicy.PublicationStep {
            let size = (try? FileManager.default.attributesOfItem(atPath: working.path)[.size] as? Int) ?? 0
            let step = ForwardOnlyFinishedBodyPolicy.publicationStep(
                bodyExistsAtCapturePath: FileManager.default.fileExists(atPath: capture.path),
                workingBodyBytes: size)
            guard step != .alreadyPublished else { return step }
            try? FileManager.default.removeItem(at: working)
            try? FileManager.default.moveItem(at: capture, to: working)
            return step
        }
        #expect(publish() == .moveBody)
        #expect(publish() == .alreadyPublished)
        #expect(try Data(contentsOf: working) == body)

        // With neither file the move fails and fails the row, as before.
        try FileManager.default.removeItem(at: working)
        #expect(publish() == .bodyMissing)
        // An empty working file is not a published body.
        try Data().write(to: working)
        #expect(ForwardOnlyFinishedBodyPolicy.publicationStep(
            bodyExistsAtCapturePath: false, workingBodyBytes: 0) == .bodyMissing)
        // A body at the capture path always wins: it replaces whatever is at the working path.
        #expect(ForwardOnlyFinishedBodyPolicy.publicationStep(
            bodyExistsAtCapturePath: true, workingBodyBytes: 4_096) == .moveBody)
    }

    // MARK: 2. Progress under a halt

    @Test("The last progress of a finished task under a pause leaves it for its finish callback")
    func haltedProgressKeepsAFinishedTask() {
        func progress(_ halt: StaticRangeHaltKind, completed: Bool = false,
                      written: Int64, expected: Int64) -> StaticRangePauseSweepDisposition {
            StaticRangeFinishedBodyPolicy.haltedProgressDisposition(
                haltKind: halt, taskStateIsCompleted: completed,
                bytesWritten: written, bytesExpectedToWrite: expected)
        }
        // Every declared byte has arrived: the finish callback is next and writes the body.
        #expect(progress(.pause, written: 64, expected: 64) == .leaveForFinishCallback)
        #expect(progress(.pause, completed: true, written: 10, expected: 64) == .leaveForFinishCallback)
        #expect(progress(.pause, completed: true, written: 1_000, expected: -1) == .leaveForFinishCallback)
        // A task that is still transferring is superseded and cancelled, as before.
        #expect(progress(.pause, written: 10, expected: 64) == .supersedeAndCancel)
        #expect(progress(.pause, written: 1_000, expected: -1) == .supersedeAndCancel)
        #expect(progress(.pause, written: 0, expected: 0) == .supersedeAndCancel)
        // A cancel discards a finished body anyway, so its progress always supersedes.
        #expect(progress(.cancel, written: 64, expected: 64) == .supersedeAndCancel)
        #expect(progress(.cancel, completed: true, written: 64, expected: 64) == .supersedeAndCancel)
        // The same judgement as the pause's task listing, so neither undoes the other.
        for (written, expected) in [(Int64(64), Int64(64)), (10, 64), (1_000, -1)] {
            #expect(progress(.pause, written: written, expected: expected)
                == StaticRangeFinishedBodyPolicy.pauseSweepDisposition(
                    taskStateIsCompleted: false, bytesReceived: written,
                    bytesExpectedToReceive: expected))
        }
    }

    // MARK: 3. A lease wait that runs out

    /// A worker whose lease wait ran out parks its work. The claim then belongs to the retry,
    /// and the release of the lease it waited for makes it a worker again.
    @Test("A parked publication is run again by the lease release it waited for")
    func leaseReleaseResumesAParkedPublication() {
        let ledger = Ledger()
        #expect(ledger.claim("capture"))
        #expect(ledger.park("capture", waitingFor: "working-a", work: 1))
        #expect(ledger.owner(of: "capture") == .parkedRetry)
        #expect(ledger.parkedKeys == ["capture"])
        // A recovery pass still cannot claim a second publication.
        #expect(!ledger.claim("capture"))

        // Another path's release wakes nothing.
        #expect(ledger.resume(releasedPaths: ["working-b"]).isEmpty)
        #expect(ledger.owner(of: "capture") == .parkedRetry)

        let resumed = ledger.resume(releasedPaths: ["working-a", "working-b"])
        #expect(resumed.map(\.key) == ["capture"])
        #expect(resumed.map(\.work) == [1])
        #expect(ledger.owner(of: "capture") == .worker, "the retry is a worker again")
        // One wake, one worker: a second release does not start a second publication.
        #expect(ledger.resume(releasedPaths: ["working-a"]).isEmpty)
        #expect(ledger.resume("capture") == nil)
    }

    @Test("A parked publication is also run again when someone asks for its body")
    func askingAgainResumesAParkedPublication() {
        let ledger = Ledger()
        #expect(ledger.claim("capture"))
        // A worker is not handed out again: it is already going to run.
        #expect(ledger.resume("capture") == nil)
        ledger.park("capture", waitingFor: "working", work: 7)
        #expect(ledger.resume("capture") == 7)
        #expect(ledger.owner(of: "capture") == .worker)
        #expect(ledger.resume("capture") == nil)
        // Still busy: it parks again, and the lease release finds it.
        #expect(ledger.park("capture", waitingFor: "working", work: 8))
        #expect(ledger.resume(releasedPaths: ["working"]).map(\.work) == [8])
    }

    /// The invariant the stranded body broke: a claim always has an owner that will act.
    @Test("A claim is never left with no owner, and a released one cannot be parked")
    func aClaimAlwaysHasAnOwner() {
        let ledger = Ledger()
        // Parking without a claim does nothing (the publication was released meanwhile).
        #expect(!ledger.park("capture", waitingFor: "working", work: 1))
        #expect(ledger.owner(of: "capture") == nil)
        #expect(ledger.claim("capture"))
        ledger.release("capture")
        #expect(!ledger.park("capture", waitingFor: "working", work: 1))
        #expect(ledger.resume(releasedPaths: ["working"]).isEmpty)
        // A released body can be claimed again (a new process-local publication).
        #expect(ledger.claim("capture"))
        ledger.park("capture", waitingFor: "working", work: 2)
        ledger.release("capture")
        #expect(ledger.resume("capture") == nil)
        #expect(ledger.parkedKeys.isEmpty)
    }

    /// A release and a park race on different threads. Whatever the order, the publication
    /// ends as exactly one worker: woken by the release, or found by the retry that follows.
    @Test("A wake racing a park never loses or doubles the publication")
    func wakeRacingPark() {
        for _ in 0..<200 {
            let ledger = Ledger()
            #expect(ledger.claim("capture"))
            let runs = Counter()
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                if index == 0 {
                    ledger.park("capture", waitingFor: "working", work: 1)
                } else {
                    runs.add(ledger.resume(releasedPaths: ["working"]).count)
                }
            }
            // The app tries the lease once more before it parks, so a release that came first
            // is seen there; here the follow-up ask stands in for it.
            if ledger.resume("capture") != nil { runs.increment() }
            #expect(runs.value == 1)
            #expect(ledger.owner(of: "capture") == .worker)
        }
    }

    // MARK: 4. The foreground reconcile snapshot

    @Test("Reconcile judges a foreground row only while it is unchanged since the snapshot")
    func foregroundSnapshotRule() throws {
        typealias Row = DownloadReconcileRowObservation
        let attempt = try #require(DownloadAttemptID(rawValue: "attempt-a"))
        let retry = try #require(DownloadAttemptID(rawValue: "attempt-b"))
        let seen = Row(attemptID: attempt, mutationGeneration: 4)
        let observations = ["row": seen]
        func judges(_ current: Row, _ observations: [String: Row]? = ["row": seen],
                    key: String = "row") -> Bool {
            DownloadReconcileSnapshotPolicy.judgesRow(
                ratingKey: key, observations: observations, current: current)
        }
        #expect(judges(seen, observations))
        // The user resumed the row during the task listing: its generation moved.
        #expect(!judges(Row(attemptID: attempt, mutationGeneration: 5)))
        // A Retry replaced the attempt.
        #expect(!judges(Row(attemptID: retry, mutationGeneration: 4)))
        // A row the snapshot never saw (created during the listing).
        #expect(!judges(Row(attemptID: attempt, mutationGeneration: 0), key: "new"))
        // Launch reconcile carries no observations and judges every row of its snapshot.
        #expect(judges(Row(attemptID: attempt, mutationGeneration: 9), nil))
        #expect(judges(Row(attemptID: nil, mutationGeneration: 0), nil, key: "new"))
    }

    /// What the stale exclusion let through: the reducer requeues an admitted forward-only
    /// row with no task, which is right at launch and wrong under a supervised start.
    @Test("The requeue the snapshot rule guards is the reducer's Admission-A1 decision")
    func requeueIsTheDecisionBeingGuarded() {
        let admitted = DownloadLifecycleState(lifecycle: .admitted)
        let next = DownloadLifecycleReducer.reduce(
            admitted, .relaunchObserved, facts: DownloadRowFacts(route: .forwardOnly))
        #expect(next.state?.lifecycle == .planned)
        #expect(next.state?.history.admissionIntent == .seasonPlanned)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { add(1) }
    func add(_ value: Int) { lock.withLock { count += value } }
    var value: Int { lock.withLock { count } }
}
