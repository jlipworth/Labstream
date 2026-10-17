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

@Suite("Cleanup intent retry and Plex outcomes")
struct CleanupIntentRetryPolicyTests {
    @Test func backoffDoublesFromThirtySecondsToThirtyMinutes() {
        #expect(CleanupIntentRetryPolicy.backoffSeconds(afterFailures: 0) == 0)
        #expect(CleanupIntentRetryPolicy.backoffSeconds(afterFailures: 1) == 30)
        #expect(CleanupIntentRetryPolicy.backoffSeconds(afterFailures: 2) == 60)
        #expect(CleanupIntentRetryPolicy.backoffSeconds(afterFailures: 7) == 1_800)
        #expect(CleanupIntentRetryPolicy.backoffSeconds(afterFailures: 99) == 1_800)
    }

    @Test func plexRetentionSlowsAfterADayAndRetiresAfterAWeek() {
        let day = CleanupIntentRetryPolicy.slowPlexAfterSeconds
        #expect(CleanupIntentRetryPolicy.plexRetention(
            recordedAtEpochSeconds: 1_000, nowEpochSeconds: 1_000 + 60)
            == .retain(minimumDelaySeconds: 0))
        #expect(CleanupIntentRetryPolicy.plexRetention(
            recordedAtEpochSeconds: 0, nowEpochSeconds: day + 1)
            == .retain(minimumDelaySeconds: CleanupIntentRetryPolicy.slowPlexBackoffSeconds))
        #expect(CleanupIntentRetryPolicy.plexRetention(
            recordedAtEpochSeconds: 0,
            nowEpochSeconds: CleanupIntentRetryPolicy.plexRetentionSeconds) == .retire)
        #expect(CleanupIntentRetryPolicy.plexRetention(
            recordedAtEpochSeconds: nil, nowEpochSeconds: .greatestFiniteMagnitude)
            == .retain(minimumDelaySeconds: 0))
    }

    @Test func onlyUnresolvedCreatesExpire() {
        let week = CleanupIntentRetryPolicy.plexRetentionSeconds
        #expect(CleanupIntentRetryPolicy.plexRetention(
            recordedAtEpochSeconds: 0, nowEpochSeconds: week * 2, mayRetire: false)
            == .retain(minimumDelaySeconds: CleanupIntentRetryPolicy.slowPlexBackoffSeconds))
    }

    @Test func plexQueueOutcomesAreExplicit() throws {
        func queue(_ json: String) throws -> BackgroundProcessingItems {
            try JSONDecoder().decode(BackgroundProcessingItems.self, from: Data(json.utf8))
        }
        let title = "Labstream marker 1"
        #expect(try queue("{}").cleanupOutcome(queueTitle: title) == .malformed)
        #expect(try queue(#"{"MediaContainer":{"Item":"oops"}}"#)
            .cleanupOutcome(queueTitle: title) == .malformed)
        #expect(try queue(#"{"MediaContainer":{"size":0}}"#)
            .cleanupOutcome(queueTitle: title) == .absent)
        #expect(try queue(#"{"MediaContainer":{"Item":[{"id":7,"title":"Labstream marker 1","Status":{"state":"processing"}}]}}"#)
            .cleanupOutcome(queueTitle: title) == .cancellable(id: "7"))
        #expect(try queue(#"{"MediaContainer":{"Item":[{"id":7,"title":"Labstream marker 1","Status":{"state":"Complete"}}]}}"#)
            .cleanupOutcome(queueTitle: title) == .completed)
        #expect(try queue(#"{"MediaContainer":{"Item":[{"id":7,"title":"Labstream marker 1"}]}}"#)
            .cleanupOutcome(queueTitle: title) == .uncertain)
        #expect(try queue(#"{"MediaContainer":{"Item":[{"id":7,"title":"Labstream marker 1","Status":{"state":"mystery"}}]}}"#)
            .cleanupOutcome(queueTitle: title) == .uncertain)
        #expect(try queue(#"{"MediaContainer":{"Item":[{"id":7,"title":"Labstream marker 1","Status":{"state":"pending"}},{"id":8,"title":"Labstream marker 1","Status":{"state":"pending"}}]}}"#)
            .cleanupOutcome(queueTitle: title) == .uncertain)
    }

    @Test func liveRecoveryIdentitiesClaimTheJobsTheyWouldAdopt() {
        // B49: a replacement row that holds only crash-window identity still owns the one new job
        // its recovery would adopt; an older ambiguous intent must not cancel it.
        let fingerprint = EmbyConvertRecoveryPolicy.Fingerprint(
            itemId: "1200", quality: "custom", profile: "tv", bitrate: 8_000_000)
        let started = Date().timeIntervalSince1970 - 60
        let created = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: started + 1))
        func job(_ id: Int, item: String = "1200") -> EmbyConvertRecoveryEntry {
            EmbyConvertRecoveryEntry(
                id: id, requestedItemIds: [item], itemId: item,
                targetId: "originalmediafolder", quality: "custom", profile: "tv",
                bitrate: 8_000_000, dateCreated: created, userId: "7",
                syncNewContent: false, unwatchedOnly: false)
        }
        let identity = EmbyConvertRecoveryPolicy.LiveRecoveryIdentity(
            baselineJobIDs: [41], fingerprint: fingerprint,
            attemptStartedAtEpochSeconds: started, phase: .dispatchAmbiguous)
        let claimed = EmbyConvertRecoveryPolicy.claimedJobIDs(
            liveJobIDs: [50], liveRecoveryIdentities: [identity],
            jobs: [job(41), job(100), job(200, item: "other")],
            nowEpochSeconds: Date().timeIntervalSince1970)
        #expect(claimed == [50, 100])
    }
}
