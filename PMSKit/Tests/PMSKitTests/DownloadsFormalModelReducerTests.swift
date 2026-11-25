import Foundation
import Testing
@testable import PMSKit

/// Keeps the TLA+ reducer (`specs/downloads/base/DownloadsReducer.tla`) equal to the Swift one.
///
/// The test runs `DownloadLifecycleReducer.reduce` over a systematic input set and renders the
/// results as the TLA+ module `specs/downloads/base/DownloadsReducerTable.tla`:
///
/// - states: every lifecycle with the empty history, every value of every history field alone,
///   and every pair of values of two different fields (`otherHistories`);
/// - events: every event case with every payload the reducer distinguishes;
/// - facts: the whole finite space of `DownloadRowFacts` under the table's abstraction, 1,280
///   records (`facts`), for `relaunchObserved`.
///
/// The relaunch grid holds the `relaunchStateCount` states whose histories differ from the empty
/// one only in `pauseCause`, against all 1,280 facts. `relaunchIsLocal` (here) and `RelaunchLocal`
/// (in `DownloadsReducerConformance.tla`) prove that relaunch reads nothing else of a history and
/// writes only `pauseCause`, `lastFailure` and `admissionIntent` (only ever to `seasonPlanned`),
/// which extends that grid to every other state.
///
/// The file is checked in:
///
/// - this test fails when the rendered table differs from the checked-in file, so a reducer change
///   cannot land without regenerating it;
/// - `specs/downloads/base/Reducer-Conformance.cfg` (run by `scripts/check-tla-specs.sh`) fails when
///   `Reduce` in `DownloadsReducer.tla` does not return exactly that table, so a regenerated table
///   cannot land without the matching spec change, and a spec change cannot land alone.
///
/// Regenerate after an intended reducer change:
///
///     LABSTREAM_WRITE_REDUCER_TABLE=1 swift test --package-path PMSKit --no-parallel \
///         --filter DownloadsFormalModelReducerTests
///
/// then update `DownloadsReducer.tla` until `scripts/check-tla-specs.sh
/// specs/downloads/base/Reducer-Conformance.cfg` passes.
@Suite("Downloads formal model: reducer conformance")
struct DownloadsFormalModelReducerTests {
    private typealias Table = DownloadsReducerTableGenerator

    private static var tableURL: URL {
        // PMSKit/Tests/PMSKitTests/<this file> -> repository root.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("specs/downloads/base/DownloadsReducerTable.tla")
    }

    @Test("The checked-in TLA+ reducer table is what the Swift reducer produces")
    func checkedInTableMatchesTheReducer() throws {
        let rendered = Table.render()
        if ProcessInfo.processInfo.environment["LABSTREAM_WRITE_REDUCER_TABLE"] == "1" {
            try rendered.write(to: Self.tableURL, atomically: true, encoding: .utf8)
            return
        }
        let checkedIn = try String(contentsOf: Self.tableURL, encoding: .utf8)
        #expect(
            checkedIn == rendered,
            """
            specs/downloads/base/DownloadsReducerTable.tla is stale: the reducer or the table's inputs \
            changed. Regenerate it with LABSTREAM_WRITE_REDUCER_TABLE=1 (see this file's header), \
            then update specs/downloads/base/DownloadsReducer.tla to match.
            """)
    }

    @Test("The table's inputs cover every lifecycle, every event case and the whole fact space")
    func inputsCoverTheVocabulary() {
        #expect(Set(Table.states.map(\.lifecycle)) == Set(DownloadLifecycle.allCases))
        let types = Set(Table.events.map(Table.typeName)).union([Table.typeName(.relaunchObserved)])
        #expect(types.count == Table.eventTypeCount)
        #expect(Table.facts.first == DownloadRowFacts(route: .staticRange))
        // 5 routes (embyConvert twice) x 4 checkpoints x 4 bodies x 2^4 flags, all distinct.
        #expect(Table.facts.count == 5 * 4 * 4 * 16)
        #expect(Set(Table.facts.map { Table.encode($0) }).count == Table.facts.count)
        #expect(Set(Table.states.map { Table.encode($0) }).count == Table.states.count)
        // The relaunch grid's states come first: every lifecycle with every pauseCause or none.
        let relaunchStates = Table.states.prefix(Table.relaunchStateCount)
        #expect(relaunchStates.allSatisfy { Table.relaunchCore($0) == $0 })
        #expect(Set(relaunchStates.map { Table.encode($0) }).count
            == DownloadLifecycle.allCases.count * (Table.pauseCauses.count + 1))
        #expect(Table.states.allSatisfy { relaunchStates.contains(Table.relaunchCore($0)) })
    }

    @Test("Only relaunchObserved reads facts")
    func onlyRelaunchReadsFacts() {
        // The table stores one result per state and event for every event but relaunchObserved,
        // so that result must not depend on the facts. Every state with at most one history
        // field set is tried against the whole fact space; every other state against a spread
        // of it in which every value of every fact field occurs.
        let spread = stride(from: 0, to: Table.facts.count, by: 37).map { Table.facts[$0] }
            + [Table.facts[Table.facts.count - 1]]
        var failures: [String] = []
        func check(_ states: [DownloadLifecycleState], against probes: [DownloadRowFacts]) {
            for state in states {
                for event in Table.events {
                    let expected = Table.reduce(state, event, Table.facts[0])
                    for facts in probes where !Table.same(Table.reduce(state, event, facts), expected) {
                        failures.append("\(Table.encode(event)) reads \(Table.encode(facts))")
                        break
                    }
                }
            }
        }
        check(Table.singleFieldStates, against: Table.facts)
        check(Table.states, against: spread)
        #expect(failures.isEmpty, "\(failures.prefix(5))")
    }

    @Test("relaunchObserved reads lifecycle and pauseCause, and writes those, lastFailure and admissionIntent")
    func relaunchIsLocal() {
        // The relaunch grid holds only the states whose history is empty but for pauseCause.
        // For every other state the result is that grid's result with the other fields carried
        // over; lastFailure and admissionIntent are the ones relaunch set, or else the state's own.
        var failures: [String] = []
        for state in Table.states {
            let core = Table.relaunchCore(state)
            for facts in Table.facts {
                let whole = Table.reduce(state, .relaunchObserved, facts)
                guard case .applied(let coreNext, let effects) =
                        Table.reduce(core, .relaunchObserved, facts) else {
                    failures.append("rejected: \(Table.encode(core)) \(Table.encode(facts))")
                    continue
                }
                var carried = state
                carried.lifecycle = coreNext.lifecycle
                carried.history.pauseCause = coreNext.history.pauseCause
                carried.history.lastFailure = coreNext.history.lastFailure ?? state.history.lastFailure
                carried.history.admissionIntent = coreNext.history.admissionIntent
                    ?? state.history.admissionIntent
                if !Table.same(whole, .applied(carried, effects)) {
                    failures.append("\(Table.encode(state)) \(Table.encode(facts))")
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(5))")
    }
}

/// Renders the reducer's behaviour over a finite input set as TLA+ text. The abstractions here
/// are the ones `DownloadsReducer.tla` lists in its header; keep the two in step.
enum DownloadsReducerTableGenerator {
    // MARK: Vocabulary. Each `name` switch has no default, so a new case fails to compile here:
    // add it to the list beside the switch and to the TLA+ vocabulary.

    static let pauseCauses: [DownloadPauseCause] = [
        .user, .queuePaused, .systemInterrupted, .awaitingSession, .storage, .deferredResume,
    ]
    static func name(_ cause: DownloadPauseCause) -> String {
        switch cause {
        case .user, .queuePaused, .systemInterrupted, .awaitingSession, .storage, .deferredResume:
            return cause.rawValue
        }
    }

    static let failureReasons: [DownloadFailureReason] = [
        .storage, .auth, .network, .server, .validation, .truncated, .sourceMissing,
        .cancelledBySystem, .aborted, .stalled, .internalError,
    ]
    static func name(_ reason: DownloadFailureReason) -> String {
        switch reason {
        case .storage, .auth, .network, .server, .validation, .truncated, .sourceMissing,
             .cancelledBySystem, .aborted, .stalled, .internalError:
            return reason.rawValue
        }
    }

    static let retryModes: [DownloadRetryMode] = [
        .freshAttempt, .resumeBlob, .staticCheckpoint, .prepReattach, .convertResume,
    ]
    static func name(_ mode: DownloadRetryMode) -> String {
        switch mode {
        case .freshAttempt, .resumeBlob, .staticCheckpoint, .prepReattach, .convertResume:
            return mode.rawValue
        }
    }

    static let admissionIntents: [DownloadAdmissionIntent] = [.seasonPlanned, .retryRequested]
    static func name(_ intent: DownloadAdmissionIntent) -> String {
        switch intent {
        case .seasonPlanned, .retryRequested: return intent.rawValue
        }
    }

    static let unverifiedReasons: [DownloadUnverifiedReason] = [
        .probeMiss("detail"), .truncatedRepeated, .backgroundProbeDeferred, .migratedUnknown,
    ]
    static func name(_ reason: DownloadUnverifiedReason) -> String {
        switch reason {
        case .probeMiss: return "probeMiss"
        case .truncatedRepeated: return "truncatedRepeated"
        case .backgroundProbeDeferred: return "backgroundProbeDeferred"
        case .migratedUnknown: return "migratedUnknown"
        }
    }

    static let outcomes: [DownloadFinalizeOutcome] = [
        .complete, .unverified(reason: "detail"), .truncated, .incompleteBytes, .emptyFile,
    ]
    static func name(_ outcome: DownloadFinalizeOutcome) -> String {
        switch outcome {
        case .complete: return "complete"
        case .unverified: return "unverified"
        case .truncated: return "truncated"
        case .incompleteBytes: return "incompleteBytes"
        case .emptyFile: return "emptyFile"
        }
    }

    static func name(_ effect: DownloadLifecycleEffect) -> String {
        switch effect {
        case .deleteWorkingBody: return "deleteWorkingBody"
        case .deletePublishedBody: return "deletePublishedBody"
        case .clearResumeBlob: return "clearResumeBlob"
        case .requestFinalization: return "requestFinalization"
        case .publish(.complete): return "publishComplete"
        case .publish(.unverified): return "publishUnverified"
        case .publish(let other): return "publish_\(other.rawValue)"
        case .resetBytesToDurableCheckpoint: return "resetBytesToDurableCheckpoint"
        case .resetBytesToZero: return "resetBytesToZero"
        }
    }

    /// Two sources that are proven different, and the two outcome IDs the events use.
    static let sources = ["s1", "s2"].map {
        DownloadSourceKey(server: nil, account: nil, backend: nil, item: $0, source: nil, profile: nil)
    }
    static let outcomeIDs = ["o1", "o2"]

    // MARK: Inputs

    /// One history field set to one value, as an edit of a history.
    private struct FieldValue: Sendable {
        let field: Int
        /// Whether the value is also combined with every value of every other field.
        var paired = true
        let apply: @Sendable (inout DownloadAttemptHistory) -> Void
    }

    /// Every value of every history field. Field 0 is `pauseCause`, the one history field
    /// relaunch reads. `lastFailure` has eleven values that the reducer never tells apart, so
    /// only three of them are paired with the other fields; all eleven appear alone.
    private static let fieldValues: [FieldValue] = {
        let park = DownloadStoragePark(requiredBytes: nil, measuredAtEpochSeconds: 0)
        func truncation(_ strikes: Int, _ source: Int, _ ids: [String]) -> DownloadTruncationHistory {
            DownloadTruncationHistory(strikes: strikes, sourceKey: sources[source], countedOutcomeIDs: ids)
        }
        let pairedFailures: Set<DownloadFailureReason> = [.network, .truncated, .storage]
        var list: [FieldValue] = []
        list += pauseCauses.map { value in FieldValue(field: 0) { $0.pauseCause = value } }
        list += failureReasons.map { value in
            FieldValue(field: 1, paired: pairedFailures.contains(value)) { $0.lastFailure = value }
        }
        list += unverifiedReasons.map { value in FieldValue(field: 2) { $0.unverifiedReason = value } }
        list += admissionIntents.map { value in FieldValue(field: 3) { $0.admissionIntent = value } }
        list.append(FieldValue(field: 4) { $0.storagePark = park })
        list.append(FieldValue(field: 5) { $0.bodyCondemned = true })
        list += [truncation(1, 0, ["o1"]), truncation(1, 1, ["o2"]), truncation(2, 0, ["o1", "o2"])]
            .map { value in FieldValue(field: 6) { $0.truncation = value } }
        return list
    }()

    private static func history(_ values: [FieldValue]) -> DownloadAttemptHistory {
        var history = DownloadAttemptHistory.empty
        for value in values { value.apply(&history) }
        return history
    }

    /// The histories relaunch can tell apart: no `pauseCause` (the empty history, first) and
    /// each `pauseCause`, everything else empty.
    private static let relaunchHistories: [DownloadAttemptHistory] =
        [.empty] + fieldValues.filter { $0.field == 0 }.map { history([$0]) }

    /// Every other history with one or two fields set: each value of the remaining fields alone,
    /// each pair of (paired) values of two different fields, and one history with every field set.
    private static let otherHistories: [DownloadAttemptHistory] = {
        var list: [DownloadAttemptHistory] = []
        for value in fieldValues where value.field > 0 { list.append(history([value])) }
        for (offset, first) in fieldValues.enumerated() where first.paired {
            for second in fieldValues[(offset + 1)...]
            where second.paired && second.field != first.field {
                list.append(history([first, second]))
            }
        }
        list.append(history((0...6).map { field in fieldValues.first { $0.field == field && $0.paired }! }))
        return list
    }()

    /// The states of the relaunch grid: the first `relaunchStateCount` entries of `states`.
    static let relaunchStateCount = DownloadLifecycle.allCases.count * relaunchHistories.count

    /// Every lifecycle with every history above, the relaunch grid's states first.
    static let states: [DownloadLifecycleState] = {
        [relaunchHistories, otherHistories].flatMap { histories in
            DownloadLifecycle.allCases.flatMap { lifecycle in
                histories.map { DownloadLifecycleState(lifecycle: lifecycle, history: $0) }
            }
        }
    }()

    /// The states with at most one history field set: the ones every fact record is tried on
    /// for the events that must not read facts.
    static let singleFieldStates: [DownloadLifecycleState] = {
        let histories = [.empty] + fieldValues.map { history([$0]) }
        return DownloadLifecycle.allCases.flatMap { lifecycle in
            histories.map { DownloadLifecycleState(lifecycle: lifecycle, history: $0) }
        }
    }()

    /// `state` with every history field relaunch does not read reset to empty.
    static func relaunchCore(_ state: DownloadLifecycleState) -> DownloadLifecycleState {
        DownloadLifecycleState(lifecycle: state.lifecycle,
                               history: DownloadAttemptHistory(pauseCause: state.history.pauseCause))
    }

    /// Every event case with every payload the reducer distinguishes, except `relaunchObserved`,
    /// which has its own grid over `facts`.
    static let events: [DownloadLifecycleEvent] = {
        var list: [DownloadLifecycleEvent] = []
        list += pauseCauses.map { .pause($0) }
        list += retryModes.map { .retry($0) }
        list += failureReasons.map { .retryRejected($0) }
        list += [.requeued, .admissionGranted]
        list += admissionIntents.map { .admissionRequested($0) }
        list += [.admissionWithdrawn]
        list += admissionIntents.map { .admissionDeferred($0) }
        list += [.prepReattached, .prepHandoff]
        list += failureReasons.map { .prepFailed($0) }
        list += [.transferStarted, .transferProgress, .checkpointAdvanced, .transferRebuilding,
                 .taskAdopted, .rebuildExpired, .resourceChanged]
        list += failureReasons.map { .transferInterrupted($0) }
        list += failureReasons.map { .transferFailed($0) }
        list += pauseCauses.map { .backendUnavailable($0) }
        list += [.bodyCaptured, .bodyAtWorking]
        for id in outcomeIDs {
            for outcome in outcomes {
                for source in sources {
                    list.append(.finalizeOutcome(id: id, outcome: outcome, source: source))
                }
            }
        }
        list += outcomes.map { .publishedBodyRevalidated(id: outcomeIDs[0], outcome: $0) }
        list += DownloadLifecycle.allCases.map { .promotionCommitted($0) }
        list += [.promotionAbandoned]
        list += DownloadLifecycle.allCases.map { .promotionRecovered($0) }
        list += [.localPlaybackProgressed, .sizeAuditFailed, .stallDetected]
        return list
    }()

    /// Facts for `relaunchObserved`: the whole space. Every route, checkpoint, body and live-task
    /// combination, crossed with the three guards that make relaunch a no-op. The first entry is
    /// the default facts. Byte counts are abstracted to zero or more.
    static let facts: [DownloadRowFacts] = {
        let routes: [DownloadRowFacts.Route] = [
            .staticRange, .plexPrep, .embyConvert(hasJobOrIdentity: false),
            .embyConvert(hasJobOrIdentity: true), .forwardOnly,
        ]
        let checkpoints: [DownloadRowFacts.Checkpoint] = [
            .none, .durablePartial(bytes: 0), .durablePartial(bytes: 1), .resumeBlob,
        ]
        let bodies: [DownloadRowFacts.Body] = [.none, .captured, .workingComplete, .published]
        let flags = [false, true]
        var list: [DownloadRowFacts] = []
        for route in routes {
            for checkpoint in checkpoints {
                for body in bodies {
                    for pendingArtifactHead in flags {
                        for deletionPending in flags {
                            for liveTask in flags {
                                for snapshotEligible in [true, false] {
                                    list.append(DownloadRowFacts(
                                        route: route, checkpoint: checkpoint, body: body,
                                        pendingArtifactHead: pendingArtifactHead,
                                        deletionPending: deletionPending, liveTask: liveTask,
                                        snapshotEligible: snapshotEligible))
                                }
                            }
                        }
                    }
                }
            }
        }
        return list
    }()

    static func reduce(_ state: DownloadLifecycleState, _ event: DownloadLifecycleEvent,
                       _ facts: DownloadRowFacts) -> DownloadLifecycleTransition {
        DownloadLifecycleReducer.reduce(state, event, facts: facts)
    }

    /// Two results are the same under the table's abstraction. A storage park carries the time
    /// it was measured, which the table reduces to "present".
    static func same(_ first: DownloadLifecycleTransition, _ second: DownloadLifecycleTransition) -> Bool {
        if first == second { return true }
        guard case .applied(var a, let aEffects) = first, case .applied(var b, let bEffects) = second,
              aEffects == bEffects, (a.history.storagePark == nil) == (b.history.storagePark == nil)
        else { return false }
        a.history.storagePark = nil
        b.history.storagePark = nil
        return a == b
    }

    // MARK: Encoding

    /// The number of `DownloadLifecycleEvent` cases; `typeName` is exhaustive over them.
    static let eventTypeCount = 32

    static func typeName(_ event: DownloadLifecycleEvent) -> String {
        switch event {
        case .pause: return "pause"
        case .retry: return "retry"
        case .retryRejected: return "retryRejected"
        case .requeued: return "requeued"
        case .admissionGranted: return "admissionGranted"
        case .admissionRequested: return "admissionRequested"
        case .admissionWithdrawn: return "admissionWithdrawn"
        case .admissionDeferred: return "admissionDeferred"
        case .prepReattached: return "prepReattached"
        case .prepHandoff: return "prepHandoff"
        case .prepFailed: return "prepFailed"
        case .transferStarted: return "transferStarted"
        case .transferProgress: return "transferProgress"
        case .checkpointAdvanced: return "checkpointAdvanced"
        case .transferRebuilding: return "transferRebuilding"
        case .taskAdopted: return "taskAdopted"
        case .rebuildExpired: return "rebuildExpired"
        case .resourceChanged: return "resourceChanged"
        case .transferInterrupted: return "transferInterrupted"
        case .transferFailed: return "transferFailed"
        case .backendUnavailable: return "backendUnavailable"
        case .bodyCaptured: return "bodyCaptured"
        case .bodyAtWorking: return "bodyAtWorking"
        case .finalizeOutcome: return "finalizeOutcome"
        case .publishedBodyRevalidated: return "publishedBodyRevalidated"
        case .promotionCommitted: return "promotionCommitted"
        case .promotionAbandoned: return "promotionAbandoned"
        case .promotionRecovered: return "promotionRecovered"
        case .localPlaybackProgressed: return "localPlaybackProgressed"
        case .sizeAuditFailed: return "sizeAuditFailed"
        case .stallDetected: return "stallDetected"
        case .relaunchObserved: return "relaunchObserved"
        }
    }

    private static func quoted(_ text: String) -> String { "\"\(text)\"" }
    private static func bool(_ value: Bool) -> String { value ? "TRUE" : "FALSE" }

    static func encode(_ event: DownloadLifecycleEvent) -> String {
        let type = quoted(typeName(event))
        switch event {
        case .pause(let cause), .backendUnavailable(let cause):
            return "[type |-> \(type), cause |-> \(quoted(name(cause)))]"
        case .retry(let mode):
            return "[type |-> \(type), mode |-> \(quoted(name(mode)))]"
        case .retryRejected(let reason), .prepFailed(let reason), .transferInterrupted(let reason),
             .transferFailed(let reason):
            return "[type |-> \(type), reason |-> \(quoted(name(reason)))]"
        case .admissionRequested(let intent), .admissionDeferred(let intent):
            return "[type |-> \(type), intent |-> \(quoted(name(intent)))]"
        case .finalizeOutcome(let id, let outcome, let source):
            return "[type |-> \(type), id |-> \(quoted(id)), outcome |-> \(quoted(name(outcome))), "
                + "source |-> \(quoted(source.item))]"
        case .publishedBodyRevalidated(_, let outcome):
            return "[type |-> \(type), outcome |-> \(quoted(name(outcome)))]"
        case .promotionCommitted(let terminal), .promotionRecovered(let terminal):
            return "[type |-> \(type), terminal |-> \(quoted(terminal.rawValue))]"
        case .requeued, .admissionGranted, .admissionWithdrawn, .prepReattached, .prepHandoff,
             .transferStarted, .transferProgress, .checkpointAdvanced, .transferRebuilding,
             .taskAdopted, .rebuildExpired, .resourceChanged, .bodyCaptured, .bodyAtWorking,
             .promotionAbandoned, .localPlaybackProgressed, .sizeAuditFailed, .stallDetected,
             .relaunchObserved:
            return "[type |-> \(type)]"
        }
    }

    /// `St(lifecycle, pauseCause, lastFailure, unverifiedReason, admissionIntent, storagePark,
    /// bodyCondemned, strikes, source, counted)`.
    static func encode(_ state: DownloadLifecycleState) -> String {
        let history = state.history
        let counted = (history.truncation?.countedOutcomeIDs ?? []).sorted().map(quoted)
        let fields = [
            quoted(state.lifecycle.rawValue),
            quoted(history.pauseCause.map(name) ?? "none"),
            quoted(history.lastFailure.map(name) ?? "none"),
            quoted(history.unverifiedReason.map(name) ?? "none"),
            quoted(history.admissionIntent.map(name) ?? "none"),
            bool(history.storagePark != nil),
            bool(history.isBodyCondemned),
            String(history.truncation?.strikes ?? 0),
            quoted(history.truncation?.sourceKey.item ?? "none"),
            "{\(counted.joined(separator: ","))}",
        ]
        return "St(\(fields.joined(separator: ",")))"
    }

    /// `Fx(route, hasJob, checkpoint, body, pendingArtifactHead, deletionPending, liveTask,
    /// snapshotEligible)`.
    static func encode(_ facts: DownloadRowFacts) -> String {
        let route: String
        var hasJob = false
        switch facts.route {
        case .staticRange: route = "staticRange"
        case .plexPrep: route = "plexPrep"
        case .embyConvert(let hasJobOrIdentity): route = "embyConvert"; hasJob = hasJobOrIdentity
        case .forwardOnly: route = "forwardOnly"
        }
        let checkpoint: String
        switch facts.checkpoint {
        case .none: checkpoint = "none"
        case .durablePartial(let bytes): checkpoint = bytes > 0 ? "partial" : "partialEmpty"
        case .resumeBlob: checkpoint = "resumeBlob"
        }
        let body: String
        switch facts.body {
        case .none: body = "none"
        case .captured: body = "captured"
        case .workingComplete: body = "workingComplete"
        case .published: body = "published"
        }
        let fields = [
            quoted(route), bool(hasJob), quoted(checkpoint), quoted(body),
            bool(facts.pendingArtifactHead), bool(facts.deletionPending), bool(facts.liveTask),
            bool(facts.snapshotEligible),
        ]
        return "Fx(\(fields.joined(separator: ",")))"
    }

    /// A result with its state written out, for comparing two results.
    static func encode(result: DownloadLifecycleTransition) -> String {
        encode(result: result) { encode($0) }
    }

    private static func encode(result: DownloadLifecycleTransition,
                               state: (DownloadLifecycleState) -> String) -> String {
        switch result {
        case .rejected(.illegal): return "Il"
        case .rejected(.replayed): return "Rp"
        case .applied(let next, let effects):
            return "Ap(\(state(next)),<<\(effects.map { quoted(name($0)) }.joined(separator: ","))>>)"
        }
    }

    // MARK: Rendering

    static func render() -> String {
        // States are interned by their encoding: the inputs first, then every new result state.
        var stateLines = states.map { encode($0) }
        var stateIndex: [String: Int] = [:]
        for (offset, line) in stateLines.enumerated() where stateIndex[line] == nil {
            stateIndex[line] = offset + 1
        }
        precondition(stateIndex.count == stateLines.count, "two input states encode alike")
        var resultLines: [String] = []
        var resultIndex: [String: Int] = [:]

        func intern(_ result: DownloadLifecycleTransition) -> Int {
            let line = encode(result: result) { next in
                let text = encode(next)
                if let known = stateIndex[text] { return String(known) }
                stateLines.append(text)
                stateIndex[text] = stateLines.count
                return String(stateLines.count)
            }
            if let known = resultIndex[line] { return known }
            resultLines.append(line)
            resultIndex[line] = resultLines.count
            return resultLines.count
        }

        let defaultFacts = facts[0]
        let eventGrid = states.map { state in
            events.map { intern(reduce(state, $0, defaultFacts)) }
        }
        let relaunchGrid = states.prefix(relaunchStateCount).map { state in
            facts.map { intern(reduce(state, .relaunchObserved, $0)) }
        }

        func tuple(_ name: String, _ lines: [String], numbered: Bool = true) -> String {
            let body = lines.enumerated().map { offset, line in
                let comma = offset == lines.count - 1 ? "" : ","
                return numbered ? "  \(line)\(comma)  \\* \(offset + 1)" : "  \(line)\(comma)"
            }
            return "\(name) == <<\n\(body.joined(separator: "\n"))\n>>\n"
        }
        func grid(_ rows: [[Int]]) -> [String] {
            rows.map { "<<\($0.map(String.init).joined(separator: ","))>>" }
        }

        var out = """
            ----------------------- MODULE DownloadsReducerTable -----------------------
            (***************************************************************************)
            (* GENERATED.  Do not edit.                                                *)
            (*                                                                         *)
            (* DownloadLifecycleReducer.reduce over a fixed input set, written by      *)
            (* PMSKit/Tests/PMSKitTests/DownloadsFormalModelReducerTests.swift.        *)
            (* That test fails when this file is stale; Reducer-Conformance.cfg fails  *)
            (* when Reduce in DownloadsReducer.tla does not return this table.         *)
            (*                                                                         *)
            (* Regenerate:                                                             *)
            (*   LABSTREAM_WRITE_REDUCER_TABLE=1 swift test --package-path PMSKit \\    *)
            (*     --no-parallel --filter DownloadsFormalModelReducerTests             *)
            (*                                                                         *)
            (* TableStates[1..TableInputCount] are the input states; the rest appear   *)
            (* only in results.  TableEventGrid[s][e] is the index in TableResults of  *)
            (* reduce(TableStates[s], TableEvents[e], facts: TableFacts[1]).           *)
            (* TableRelaunchGrid[s][f], for s in 1..TableRelaunchInputCount, is the    *)
            (* same for relaunchObserved with TableFacts[f]: those states differ from  *)
            (* an empty history only in pauseCause, and TableFacts is the whole fact   *)
            (* space.  The trailing comment on a line is its index.                    *)
            (***************************************************************************)
            EXTENDS DownloadsReducer

            TableInputCount == \(states.count)
            TableRelaunchInputCount == \(relaunchStateCount)


            """
        out += tuple("TableStates", stateLines) + "\n"
        out += tuple("TableEvents", events.map { encode($0) }) + "\n"
        out += tuple("TableFacts", facts.map { encode($0) }) + "\n"
        out += "Ap(state, effects) == Applied(TableStates[state], effects)\n"
        out += "Il == Illegal\n"
        out += "Rp == Replayed\n\n"
        out += tuple("TableResults", resultLines) + "\n"
        out += tuple("TableEventGrid", grid(eventGrid)) + "\n"
        out += tuple("TableRelaunchGrid", grid(relaunchGrid))
        out += "=============================================================================\n"
        return out
    }
}
