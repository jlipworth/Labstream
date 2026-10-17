import Foundation
import Testing
@testable import PMSKit

@Suite("Cleanup intent eligibility")
struct CleanupIntentEligibilityPolicyTests {
    private typealias Policy = CleanupIntentEligibilityPolicy
    private let origin = DownloadAttemptKey(
        ratingKey: "emby:item", attemptID: DownloadAttemptID(uuid: UUID()))

    @Test("Nothing runs while the store is unsure or the row is retiring")
    func retiringAndUnknownAlwaysWait() {
        for provenance: DurableDownloadCleanupIntent.Provenance? in [
            .rowDeletion, .terminalRelease, .abandonment(originAttempt: origin), nil,
        ] {
            #expect(Policy.decision(provenance: provenance, rowState: .retiring) == .wait)
            #expect(Policy.decision(provenance: provenance, rowState: .unknown) == .wait)
        }
    }

    @Test("A deletion intent runs only after the removal has committed")
    func rowDeletionNeedsCommittedAbsence() {
        #expect(Policy.decision(provenance: .rowDeletion, rowState: .committedAbsent) == .run)
        #expect(Policy.decision(
            provenance: .rowDeletion,
            rowState: .present(isTerminal: true, protectsResource: false)) == .wait)
    }

    @Test("A terminal release runs for an unprotected terminal row, and after its deletion")
    func terminalReleaseRules() {
        #expect(Policy.decision(
            provenance: .terminalRelease,
            rowState: .present(isTerminal: true, protectsResource: false)) == .run)
        // B44/B49: a failed row whose Retry resumes this job keeps it.
        #expect(Policy.decision(
            provenance: .terminalRelease,
            rowState: .present(isTerminal: true, protectsResource: true)) == .wait)
        #expect(Policy.decision(
            provenance: .terminalRelease,
            rowState: .present(isTerminal: false, protectsResource: false)) == .wait)
        // Delete may reuse this intent through ensure; it must still run once the row is gone.
        #expect(Policy.decision(provenance: .terminalRelease, rowState: .committedAbsent) == .run)
    }

    @Test("An abandonment defers only to the ownership recheck")
    func abandonmentRuns() {
        let abandonment = DurableDownloadCleanupIntent.Provenance.abandonment(originAttempt: origin)
        #expect(Policy.decision(
            provenance: abandonment,
            rowState: .present(isTerminal: false, protectsResource: false)) == .run)
        #expect(Policy.decision(provenance: abandonment, rowState: .committedAbsent) == .run)
    }

    @Test("Unclassified legacy entries never run until classified")
    func legacyEntriesWaitThenClassify() {
        #expect(Policy.decision(provenance: nil, rowState: .committedAbsent) == .wait)
        #expect(Policy.legacyProvenance(for: .committedAbsent) == .rowDeletion)
        #expect(Policy.legacyProvenance(
            for: .present(isTerminal: true, protectsResource: true)) == .terminalRelease)
        #expect(Policy.legacyProvenance(
            for: .present(isTerminal: false, protectsResource: false)) == nil)
        #expect(Policy.legacyProvenance(for: .retiring) == nil)
        #expect(Policy.legacyProvenance(for: .unknown) == nil)
    }
}
