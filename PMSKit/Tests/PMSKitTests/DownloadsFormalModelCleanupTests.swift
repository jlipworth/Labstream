import Foundation
import Testing
@testable import PMSKit

/// What the TLA+ model of Delete and server cleanup rests on, and what it found
/// (`specs/downloads/DownloadsCleanup.tla`, `specs/downloads/Cleanup-*.cfg`).
///
/// The first tests keep the model's runner guard (`MayRun`) equal to
/// `CleanupIntentEligibilityPolicy`. The rest are findings: each states the behaviour the design
/// wants and is wrapped in `withKnownIssue`, so the suite stays green while the finding is open.
/// When a fix lands the expectations hold, no issue is recorded, and `withKnownIssue` fails the
/// test: delete the wrapper then, and flip the matching `Cleanup-Finding-*.cfg` to
/// `EXPECT: pass`.
///
/// The deletion barrier, the artifact worker and the index writer are app code with no PMSKit
/// decision to call, so the findings pin the shape of the app source. Each needs a
/// `LabstreamTests` pin with its fix.
@Suite("Downloads formal-model cleanup")
struct DownloadsFormalModelCleanupTests {
    private typealias Policy = CleanupIntentEligibilityPolicy
    private static let storePath = "Labstream/Capabilities/Downloads/Core/DownloadStore.swift"

    // MARK: - The model's runner guard

    /// `MayRun` in the model: nothing runs against a row that is retiring or unknown.
    @Test("Model MayRun: a retiring or unknown row never runs cleanup")
    func retiringOrUnknownRowWaits() {
        for provenance in [DurableDownloadCleanupIntent.Provenance.rowDeletion, .terminalRelease] {
            #expect(Policy.decision(provenance: provenance, rowState: .retiring) == .wait)
            #expect(Policy.decision(provenance: provenance, rowState: .unknown) == .wait)
        }
    }

    /// `MayRun`: once the row is durably gone, a deletion or a terminal release runs. Delete
    /// reuses an earlier terminal-release entry, so both must run against an absent row.
    @Test("Model MayRun: a durably absent row runs its cleanup")
    func absentRowRuns() {
        #expect(Policy.decision(provenance: .rowDeletion, rowState: .committedAbsent) == .run)
        #expect(Policy.decision(provenance: .terminalRelease, rowState: .committedAbsent) == .run)
    }

    /// `MayRun`: a deletion entry waits while its row is still there (the journal can commit
    /// before the row's reservation does), and a terminal release runs only against a terminal
    /// row that does not protect the job (B44, `Cleanup-Faithful-B44-off.cfg`).
    @Test("Model MayRun: a present row runs only an unprotected terminal release")
    func presentRowRunsOnlyUnprotectedTerminalRelease() {
        for isTerminal in [true, false] {
            for protects in [true, false] {
                let row = Policy.RowState.present(isTerminal: isTerminal, protectsResource: protects)
                #expect(Policy.decision(provenance: .rowDeletion, rowState: row) == .wait)
                #expect(Policy.decision(provenance: .terminalRelease, rowState: row)
                        == (isTerminal && !protects ? .run : .wait))
            }
        }
    }

    /// The model's `Protects`: a failed Emby Convert row keeps its job for Retry, and an entry
    /// written before provenance existed is still classified as a terminal release for it, so
    /// the runner's check is what keeps the job alive.
    @Test("Model Protects: a failed Convert row keeps its job, and a legacy entry still targets it")
    func failedConvertRowProtectsItsJob() {
        #expect(DownloadRetryPreparationPolicy.shouldKeepEmbyConvertAuthorityForRetry(
            status: .failed, resumeMode: .serverPrepThenStatic, isEmbyRecord: true,
            hasEmbyConvertJobID: true, hasEmbyConvertRecoveryIdentity: false))
        #expect(Policy.legacyProvenance(
            for: .present(isTerminal: true, protectsResource: true)) == .terminalRelease)
    }

    // MARK: - Findings

    /// Cleanup-C1. The volume is full. The user deletes a row; the row-deletion intent is queued
    /// in memory but its index commit fails, so the worker fails the head and drops its ticket.
    /// Any explicit recovery (every range-request resume and every background-completion flush
    /// runs one for all rows) then registers a new ticket with `preparedRevision` 0. Waiting for
    /// revision 0 returns at once, so the worker unlinks the row's files while the index on disk
    /// still holds a live row with no deletion intent. A kill before the terminal commit leaves a
    /// row that claims a body that is gone.
    ///
    /// The held-body and promotion workers do not have this hole: each waits for a revision it
    /// submitted itself before it touches a file.
    @Test("Cleanup-C1: a row deletion unlinks only after its intent is durable")
    func rowDeletionUnlinksOnlyAfterDurableIntent() throws {
        let execute = try #require(Self.appFunctionSource(
            declaration: "    private func executeRowDeletion(", in: Self.storePath))
        let recover = try #require(Self.appFunctionSource(
            declaration: "    private func recoverPendingArtifactIntents(", in: Self.storePath))
        let held = try #require(Self.appFunctionSource(
            declaration: "    private func executeHeldLifecycle(", in: Self.storePath))

        // The guard the held-body worker already has: a wait on the newest submitted revision.
        #expect(held.contains("currentPersistenceTicket()"))
        // The only durability wait the row deletion has, before it unlinks.
        let unlink = try #require(execute.range(of: "artifactFilesystem.removeItem"))
        let beforeUnlink = execute[..<unlink.lowerBound]
        #expect(beforeUnlink.contains("waitForPersistence(through: ticket.preparedRevision)"))

        withKnownIssue("TLA+ finding Cleanup-C1: a re-registered row deletion skips its durability wait") {
            let waitsForOwnRevision = beforeUnlink.contains("currentPersistenceTicket()")
                || beforeUnlink.contains("enqueueAttemptPersistenceLocked()")
            let recoveryRegistersRevisionZero = recover.contains("preparedRevision: .init(revision: 0)")
            #expect(waitsForOwnRevision || !recoveryRegistersRevisionZero,
                    "a recovered row deletion can unlink before its intent is on disk")
        }
    }

    /// B27 (#392). An old build left `pendingValidatedPromotionStatus` on a row. Launch recovery
    /// finishes it only when a body exists; with both bodies gone it returns `.sourceMissing` and
    /// the flag stays. Both Delete entry points then refuse the row as stale, on every tap, and
    /// Retry is refused too: the row cannot be removed.
    @Test("B27: Delete is not refused by a legacy validated promotion")
    func deleteIsNotRefusedByLegacyPromotion() throws {
        let submitRemove = try #require(Self.appFunctionSource(
            declaration: "    private func submitRemove(\n", in: Self.storePath))
        let submitDeletionPending = try #require(Self.appFunctionSource(
            declaration: "    func submitDeletionPending(\n", in: Self.storePath))
        let recovery = try #require(Self.appFunctionSource(
            declaration: "    func recoverPendingValidatedPromotion(\n", in: Self.storePath))

        // The wedge: the only code that clears the flag gives up without clearing it.
        #expect(recovery.contains("return .sourceMissing"))
        #expect(recovery.contains("current.pendingValidatedPromotionStatus = nil"))

        withKnownIssue("TLA+ finding B27 (#392): a legacy validated promotion wedges Delete") {
            #expect(!submitRemove.contains("existing.pendingValidatedPromotionStatus == nil"),
                    "submitRemove refuses a row with a legacy promotion flag")
            #expect(!submitDeletionPending.contains("row.pendingValidatedPromotionStatus == nil"),
                    "submitDeletionPending refuses a row with a legacy promotion flag")
        }
    }

    /// B30 (#393). On a completely full volume no index snapshot can be written. Delete stages
    /// its intent in memory and the worker waits for that revision; the commit fails, the worker
    /// fails the head and returns before any unlink. Tapping Delete again repeats the same steps,
    /// so the space the user is trying to free never comes back.
    ///
    /// This pins the bare failure branch. A fix that reserves capacity for Delete's own writes
    /// may leave the branch as it is: remove this pin by hand with that fix.
    @Test("B30: Delete on a completely full volume still reclaims space")
    func deleteOnFullVolumeReclaims() throws {
        let execute = try #require(Self.appFunctionSource(
            declaration: "    private func executeRowDeletion(", in: Self.storePath))
        let unlink = try #require(execute.range(of: "artifactFilesystem.removeItem"))
        let beforeUnlink = String(execute[..<unlink.lowerBound])

        withKnownIssue("TLA+ finding B30 (#393): a full volume blocks Delete before any unlink") {
            let givesUpBeforeUnlink = Self.collapsingWhitespace(beforeUnlink).contains(
                "guard prepared.result.committed(through: ticket.preparedRevision) else { "
                    + "failArtifactLifecycle(ticket, prepared.result); return }")
            #expect(!givesUpBeforeUnlink,
                    "a failed intent commit ends the deletion with every file still on disk")
        }
    }

    // MARK: - Source access

    /// The text of one function in an app source file, from its declaration to the closing brace
    /// at the declaration's indentation. Nil when the file or the function is missing.
    private static func appFunctionSource(declaration: String, in relativePath: String) -> String? {
        // PMSKit/Tests/PMSKitTests/<this file> -> repository root.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let source = try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8),
              let start = source.range(of: declaration) else { return nil }
        let indentation = declaration.prefix { $0 == " " }
        let rest = source[start.lowerBound...]
        guard let end = rest.range(of: "\n\(indentation)}\n") else { return nil }
        return String(rest[..<end.upperBound])
    }

    private static func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
