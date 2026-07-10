import Testing
@testable import PMSKit

@Suite("Static range train integrity policy")
struct StaticRangeTrainIntegrityPolicyTests {
    // MARK: Train teardown (B.2 restart, B.3(b) adopted 200)

    @Test("Changed-resource restart supersedes the whole train, purges holds, and advances the epoch")
    func restartSupersedesTrain() {
        let actions = StaticRangeTrainIntegrityPolicy.teardownActions(for: .changedResourceRestart)
        #expect(actions.supersedeInFlightTasks)
        #expect(actions.purgeHeldSegments)
        #expect(actions.advanceTrainEpoch)
    }

    @Test("Adopted whole-file 200 supersedes the whole train, purges holds, and advances the epoch")
    func adoptedReplaceWholeSupersedesTrain() {
        let actions = StaticRangeTrainIntegrityPolicy.teardownActions(for: .adoptedWholeFileReplace)
        #expect(actions.supersedeInFlightTasks)
        #expect(actions.purgeHeldSegments)
        #expect(actions.advanceTrainEpoch)
    }

    @Test("A late sibling body from a superseded train generation is ignored, never applied")
    func lateSiblingIgnoredAfterTeardown() {
        // Tail segment beyond the new (smaller) file's size: its train epoch was advanced by the
        // adopted 200 (or a restart), so its finish must be dropped — not held, not a restart.
        #expect(!StaticRangeTrainIntegrityPolicy.shouldProcessFinishedBody(bodyTrainEpoch: 0, currentTrainEpoch: 1))
        #expect(!StaticRangeTrainIntegrityPolicy.shouldProcessFinishedBody(bodyTrainEpoch: 2, currentTrainEpoch: 5))
        #expect(StaticRangeTrainIntegrityPolicy.shouldProcessFinishedBody(bodyTrainEpoch: 3, currentTrainEpoch: 3))
    }

    @Test("Pre-append re-check: append only with a current epoch and durable bytes at the body's offset")
    func preAppendRecheckGuardsEpochAndOffset() {
        // Happy path: epoch current, file exactly at the segment's base offset.
        #expect(StaticRangeTrainIntegrityPolicy.preAppendDecision(
            bodyTrainEpoch: 2, currentTrainEpoch: 2,
            durableBytes: 1_000, baseOffset: 1_000) == .append)
        // A delegate-queue restart advanced the epoch mid-apply: discard, restart owns the row.
        #expect(StaticRangeTrainIntegrityPolicy.preAppendDecision(
            bodyTrainEpoch: 2, currentTrainEpoch: 3,
            durableBytes: 0, baseOffset: 1_000) == .discardStaleTrain)
        // The epoch takes precedence even when the sizes happen to line up (fresh file, offset 0).
        #expect(StaticRangeTrainIntegrityPolicy.preAppendDecision(
            bodyTrainEpoch: 0, currentTrainEpoch: 1,
            durableBytes: 0, baseOffset: 0) == .discardStaleTrain)
        // Same generation but the file drifted off the body's offset: appending would land the
        // bytes at the wrong file position — discard and re-plan.
        #expect(StaticRangeTrainIntegrityPolicy.preAppendDecision(
            bodyTrainEpoch: 2, currentTrainEpoch: 2,
            durableBytes: 0, baseOffset: 1_000) == .discardOffsetDrift)
        #expect(StaticRangeTrainIntegrityPolicy.preAppendDecision(
            bodyTrainEpoch: 2, currentTrainEpoch: 2,
            durableBytes: 1_500, baseOffset: 1_000) == .discardOffsetDrift)
    }

    // MARK: Arriving-body validator decisions (hold time and in-order append)

    @Test("Empty-validator window: the first body carrying a validator pins it, head or held")
    func emptyWindowPinsFirstValidator() {
        #expect(StaticRangeTrainIntegrityPolicy.arrivingBodyDecision(
            storedValidator: nil, responseValidator: "\"v1\"") == .pinAndProceed("\"v1\""))
        // No validator anywhere: proceed unprotected (observable elsewhere), never restart-loop.
        #expect(StaticRangeTrainIntegrityPolicy.arrivingBodyDecision(
            storedValidator: nil, responseValidator: nil) == .proceed)
    }

    @Test("Held/in-order body with a matching or absent validator proceeds against the pin")
    func matchingOrAbsentValidatorProceeds() {
        #expect(StaticRangeTrainIntegrityPolicy.arrivingBodyDecision(
            storedValidator: "\"v1\"", responseValidator: "\"v1\"") == .proceed)
        // Transient header omission must not trigger a restart loop.
        #expect(StaticRangeTrainIntegrityPolicy.arrivingBodyDecision(
            storedValidator: "\"v1\"", responseValidator: nil) == .proceed)
    }

    @Test("Held-body validator mismatch at hold time restarts from the changed resource")
    func heldValidatorMismatchAtHoldTime() {
        #expect(StaticRangeTrainIntegrityPolicy.arrivingBodyDecision(
            storedValidator: "\"v1\"", responseValidator: "\"v2\"") == .restartChangedResource)
    }

    // MARK: Splice-time re-verification

    @Test("Held stash validator mismatch at drain time discards instead of splicing")
    func heldValidatorMismatchAtDrainTime() {
        #expect(StaticRangeTrainIntegrityPolicy.heldSpliceDecision(
            storedValidator: "\"v2\"", heldValidator: "\"v1\"") == .discardChangedResource)
    }

    @Test("Held stash splices when validators match or either side is unknown")
    func heldSpliceTolerance() {
        #expect(StaticRangeTrainIntegrityPolicy.heldSpliceDecision(
            storedValidator: "\"v1\"", heldValidator: "\"v1\"") == .splice)
        #expect(StaticRangeTrainIntegrityPolicy.heldSpliceDecision(
            storedValidator: "\"v1\"", heldValidator: nil) == .splice)
        #expect(StaticRangeTrainIntegrityPolicy.heldSpliceDecision(
            storedValidator: nil, heldValidator: "\"v1\"") == .splice)
        #expect(StaticRangeTrainIntegrityPolicy.heldSpliceDecision(
            storedValidator: nil, heldValidator: nil) == .splice)
    }

    // MARK: Dead-finish-adopted (unowned) restrictions

    @Test("Only the dead-finish-adopted reason restricts outcomes to discard/reset")
    func adoptedFinishRestriction() {
        #expect(StaticRangeTrainIntegrityPolicy.adoptedFinishRestriction(
            remainderReason: StaticRangeTrainIntegrityPolicy.deadFinishAdoptedReason)
            == .discardAndResetOnly)
        #expect(StaticRangeTrainIntegrityPolicy.adoptedFinishRestriction(
            remainderReason: "single_remainder") == .unrestricted)
        #expect(StaticRangeTrainIntegrityPolicy.adoptedFinishRestriction(
            remainderReason: "reattached") == .unrestricted)
        #expect(StaticRangeTrainIntegrityPolicy.adoptedFinishRestriction(
            remainderReason: nil) == .unrestricted)
    }

    @Test("An unowned body may apply only onto an existing, exactly-matching validator pin")
    func unownedBodyValidatorDecision() {
        #expect(StaticRangeTrainIntegrityPolicy.unownedBodyValidatorDecision(
            storedValidator: "\"v1\"", responseValidator: "\"v1\"") == .apply)
        // Never pins: an unowned body arriving before the first owned pin must be discarded,
        // or a prior attempt's validator poisons the fresh attempt.
        #expect(StaticRangeTrainIntegrityPolicy.unownedBodyValidatorDecision(
            storedValidator: nil, responseValidator: "\"v1\"")
            == .discard(reason: "adopted_no_pinned_validator"))
        // No absent-validator tolerance.
        #expect(StaticRangeTrainIntegrityPolicy.unownedBodyValidatorDecision(
            storedValidator: "\"v1\"", responseValidator: nil)
            == .discard(reason: "adopted_validator_absent"))
        #expect(StaticRangeTrainIntegrityPolicy.unownedBodyValidatorDecision(
            storedValidator: "\"v1\"", responseValidator: "\"v2\"")
            == .discard(reason: "adopted_validator_mismatch"))
        #expect(StaticRangeTrainIntegrityPolicy.unownedBodyValidatorDecision(
            storedValidator: nil, responseValidator: nil)
            == .discard(reason: "adopted_no_pinned_validator"))
    }

    // MARK: Terminal-failure teardown

    @Test("A terminal failure always halts, supersedes, and advances the train epoch")
    func terminalFailureTeardown() {
        let teardown = StaticRangeTrainIntegrityPolicy.terminalFailureTeardown()
        #expect(teardown.insertHalt)
        #expect(teardown.supersedeLiveTasks)
        #expect(teardown.advanceTrainEpoch)
    }
}
