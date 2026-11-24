import Foundation
import Testing
@testable import PMSKit

/// Keeps the TLA+ reducer (`specs/downloads/base/DownloadsReducer.tla`) equal to the Swift one.
///
/// The test runs `DownloadLifecycleReducer.reduce` over every lifecycle, a fixed set of histories,
/// every event shape and a fixed set of facts, and renders the results as the TLA+ module
/// `specs/downloads/base/DownloadsReducerTable.tla`. That file is checked in:
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

    @Test("The table's inputs cover every lifecycle and every event case")
    func inputsCoverTheVocabulary() {
        #expect(Set(Table.states.map(\.lifecycle)) == Set(DownloadLifecycle.allCases))
        let types = Set(Table.events.map(Table.typeName)).union([Table.typeName(.relaunchObserved)])
        #expect(types.count == Table.eventTypeCount)
        #expect(Table.facts.first == DownloadRowFacts(route: .staticRange))
    }

    @Test("Only relaunchObserved reads facts")
    func onlyRelaunchReadsFacts() {
        // The table stores one result per state and event for every event but relaunchObserved,
        // so that result must not depend on the facts.
        let probes = [Table.facts[0], Table.facts[Table.facts.count / 2], Table.facts[Table.facts.count - 1]]
        for state in Table.states {
            for event in Table.events {
                let results = Set(probes.map { Table.encode(result: Table.reduce(state, event, $0)) })
                #expect(results.count == 1, "\(Table.encode(event)) reads facts")
            }
        }
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

    /// Every lifecycle with each history below: the empty one, each field set alone, and the
    /// combinations the reducer treats specially.
    static let states: [DownloadLifecycleState] = {
        typealias History = DownloadAttemptHistory
        let park = DownloadStoragePark(requiredBytes: nil, measuredAtEpochSeconds: 0)
        func truncation(_ strikes: Int, _ source: Int, _ ids: [String]) -> DownloadTruncationHistory {
            DownloadTruncationHistory(strikes: strikes, sourceKey: sources[source], countedOutcomeIDs: ids)
        }
        var histories: [History] = [.empty]
        histories += pauseCauses.map { History(pauseCause: $0) }
        histories += [.network, .truncated, .storage].map { History(lastFailure: $0) }
        histories += unverifiedReasons.map { History(unverifiedReason: $0) }
        histories += admissionIntents.map { History(admissionIntent: $0) }
        histories.append(History(storagePark: park))
        histories.append(History(bodyCondemned: true))
        histories.append(History(truncation: truncation(1, 0, ["o1"])))
        histories.append(History(truncation: truncation(1, 1, ["o2"])))
        histories.append(History(truncation: truncation(2, 0, ["o1", "o2"])))
        histories.append(History(pauseCause: .user, admissionIntent: .retryRequested))
        histories.append(History(storagePark: park, pauseCause: .storage))
        histories.append(History(truncation: truncation(1, 0, ["o1"]), lastFailure: .truncated,
                                 bodyCondemned: true))
        histories.append(History(
            truncation: truncation(1, 0, ["o1"]), unverifiedReason: .truncatedRepeated,
            lastFailure: .network, storagePark: park, pauseCause: .user,
            admissionIntent: .retryRequested, bodyCondemned: true))
        return DownloadLifecycle.allCases.flatMap { lifecycle in
            histories.map { DownloadLifecycleState(lifecycle: lifecycle, history: $0) }
        }
    }()

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

    /// Facts for `relaunchObserved`: every route, checkpoint, body and live-task combination, then
    /// each of the three guards that make relaunch a no-op. The first entry is the default facts.
    static let facts: [DownloadRowFacts] = {
        let routes: [DownloadRowFacts.Route] = [
            .staticRange, .plexPrep, .embyConvert(hasJobOrIdentity: false),
            .embyConvert(hasJobOrIdentity: true), .forwardOnly,
        ]
        let checkpoints: [DownloadRowFacts.Checkpoint] = [
            .none, .durablePartial(bytes: 0), .durablePartial(bytes: 1), .resumeBlob,
        ]
        let bodies: [DownloadRowFacts.Body] = [.none, .captured, .workingComplete, .published]
        var list: [DownloadRowFacts] = []
        for route in routes {
            for checkpoint in checkpoints {
                for body in bodies {
                    for liveTask in [false, true] {
                        list.append(DownloadRowFacts(route: route, checkpoint: checkpoint, body: body,
                                                     liveTask: liveTask))
                    }
                }
            }
        }
        list.append(DownloadRowFacts(route: .staticRange, pendingArtifactHead: true))
        list.append(DownloadRowFacts(route: .staticRange, deletionPending: true))
        list.append(DownloadRowFacts(route: .staticRange, snapshotEligible: false))
        return list
    }()

    static func reduce(_ state: DownloadLifecycleState, _ event: DownloadLifecycleEvent,
                       _ facts: DownloadRowFacts) -> DownloadLifecycleTransition {
        DownloadLifecycleReducer.reduce(state, event, facts: facts)
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
        let relaunchGrid = states.map { state in
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
            (* TableRelaunchGrid[s][f] is the same for relaunchObserved with           *)
            (* TableFacts[f].  The trailing comment on a line is its index.            *)
            (***************************************************************************)
            EXTENDS DownloadsReducer

            TableInputCount == \(states.count)


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
