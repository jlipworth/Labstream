import Testing
@testable import PMSKit

@Suite("Static range reattach policy")
struct StaticRangeReattachPolicyTests {
    @Test("Legacy closed ranges are dropped instead of adopted")
    func dropsClosedRange() {
        let plan = StaticRangeReattachPolicy.plan(
            taskIdentifier: 10,
            downloadID: "plex:item",
            durableBytes: 128,
            requestedOffset: 64,
            rangeRequestShape: .closed,
            bodyBytesWritten: 10,
            existingTasks: []
        )

        #expect(plan == StaticRangeReattachPlan(
            candidateBaseOffset: 64,
            disposition: .dropLegacyRange(requestedOffset: 64, durableBytes: 128, rangeRequestShape: .closed)
        ))
    }

    @Test("Missing or invalid ranges are dropped instead of adopted")
    func dropsMissingOrInvalidRange() {
        #expect(StaticRangeReattachPolicy.plan(
            taskIdentifier: 11,
            downloadID: "jellyfin:item",
            durableBytes: 256,
            requestedOffset: nil,
            rangeRequestShape: .missing,
            bodyBytesWritten: -5,
            existingTasks: []
        ).disposition == .dropLegacyRange(requestedOffset: nil, durableBytes: 256, rangeRequestShape: .missing))

        #expect(StaticRangeReattachPolicy.plan(
            taskIdentifier: 12,
            downloadID: "jellyfin:item",
            durableBytes: 256,
            requestedOffset: nil,
            rangeRequestShape: .invalid,
            bodyBytesWritten: 0,
            existingTasks: []
        ).disposition == .dropLegacyRange(requestedOffset: nil, durableBytes: 256, rangeRequestShape: .invalid))
    }

    @Test("Open-ended remainders must start at the durable partial checkpoint")
    func rejectsOffsetMismatch() {
        let plan = StaticRangeReattachPolicy.plan(
            taskIdentifier: 13,
            downloadID: "plex:item",
            durableBytes: 128,
            requestedOffset: 64,
            rangeRequestShape: .openEnded,
            bodyBytesWritten: 10,
            existingTasks: []
        )

        #expect(plan == StaticRangeReattachPlan(
            candidateBaseOffset: 64,
            disposition: .rejectOffsetMismatch(requestedOffset: 64, durableBytes: 128)
        ))
    }

    @Test("Matching open-ended remainders are adopted")
    func adoptsMatchingOpenEndedRemainder() {
        let plan = StaticRangeReattachPolicy.plan(
            taskIdentifier: 20,
            downloadID: "emby:item",
            durableBytes: 512,
            requestedOffset: 512,
            rangeRequestShape: .openEnded,
            bodyBytesWritten: 0,
            existingTasks: []
        )

        #expect(plan == StaticRangeReattachPlan(candidateBaseOffset: 512, disposition: .adopt))
    }

    @Test("Duplicate open-ended remainders use the authoritative task policy")
    func duplicateOpenEndedRemainders() {
        let plan = StaticRangeReattachPolicy.plan(
            taskIdentifier: 30,
            downloadID: "emby:item",
            durableBytes: 512,
            requestedOffset: 512,
            rangeRequestShape: .openEnded,
            bodyBytesWritten: 64,
            existingTasks: [
                StaticRangeTaskSnapshot(taskIdentifier: 29, downloadID: "emby:item", baseOffset: 512, bodyBytesWritten: 32),
            ]
        )

        #expect(plan == StaticRangeReattachPlan(
            candidateBaseOffset: 512,
            disposition: .replaceExisting(existingTaskIdentifier: 29, existingBaseOffset: 512)
        ))
    }

    @Test("Unmarked closed ranges are still dropped as legacy")
    func unmarkedClosedRangeStillDropped() {
        let plan = StaticRangeReattachPolicy.plan(
            taskIdentifier: 40,
            downloadID: "plex:item",
            durableBytes: 0,
            requestedOffset: 0,
            rangeRequestShape: .closed,
            bodyBytesWritten: 10,
            existingTasks: [],
            taskMarker: nil
        )

        #expect(plan == StaticRangeReattachPlan(
            candidateBaseOffset: 0,
            disposition: .dropLegacyRange(requestedOffset: 0, durableBytes: 0, rangeRequestShape: .closed)
        ))
    }

    @Test("A marked closed segment with matching offset is adopted")
    func markedClosedSegmentAdopted() {
        let plan = StaticRangeReattachPolicy.plan(
            taskIdentifier: 41,
            downloadID: "plex:item",
            durableBytes: 0,
            requestedOffset: 0,
            rangeRequestShape: .closed,
            bodyBytesWritten: 10,
            existingTasks: [],
            taskMarker: StaticRangeSegmentMarker.value(offset: 0, attemptID: "attempt-A"),
            rowAttemptID: "attempt-A"
        )

        #expect(plan == StaticRangeReattachPlan(candidateBaseOffset: 0, disposition: .adopt))
    }

    @Test("A marked closed segment ahead of the durable checkpoint but aligned to the segment grid is adopted")
    func markedClosedSegmentAheadOfDurableGridAligned() {
        let plan = StaticRangeReattachPolicy.plan(
            taskIdentifier: 42,
            downloadID: "plex:item",
            durableBytes: 0,
            requestedOffset: 512,
            rangeRequestShape: .closed,
            bodyBytesWritten: 10,
            existingTasks: [],
            taskMarker: StaticRangeSegmentMarker.value(offset: 512, attemptID: "attempt-A"),
            segmentBytes: 512,
            rowAttemptID: "attempt-A"
        )

        #expect(plan == StaticRangeReattachPlan(candidateBaseOffset: 512, disposition: .adopt))
    }

    @Test("A marked segment behind the durable checkpoint is rejected even when grid-aligned")
    func markedClosedSegmentBehindDurableRejected() {
        let plan = StaticRangeReattachPolicy.plan(
            taskIdentifier: 44,
            downloadID: "plex:item",
            durableBytes: 600,
            requestedOffset: 512,
            rangeRequestShape: .closed,
            bodyBytesWritten: 10,
            existingTasks: [],
            taskMarker: StaticRangeSegmentMarker.value(offset: 512, attemptID: "attempt-A"),
            segmentBytes: 512,
            rowAttemptID: "attempt-A"
        )

        #expect(plan == StaticRangeReattachPlan(
            candidateBaseOffset: 512,
            disposition: .rejectOffsetMismatch(requestedOffset: 512, durableBytes: 600)
        ))
    }

    @Test("A marked closed segment not aligned to the segment grid is rejected as an offset mismatch")
    func markedClosedSegmentNotGridAlignedRejected() {
        let plan = StaticRangeReattachPolicy.plan(
            taskIdentifier: 43,
            downloadID: "plex:item",
            durableBytes: 0,
            requestedOffset: 300,
            rangeRequestShape: .closed,
            bodyBytesWritten: 10,
            existingTasks: [],
            taskMarker: StaticRangeSegmentMarker.value(offset: 300, attemptID: "attempt-A"),
            segmentBytes: 512,
            rowAttemptID: "attempt-A"
        )

        #expect(plan == StaticRangeReattachPlan(
            candidateBaseOffset: 300,
            disposition: .rejectOffsetMismatch(requestedOffset: 300, durableBytes: 0)
        ))
    }

    @Test("Two marked segments at different offsets both adopt")
    func twoMarkedSegmentsDifferentOffsetsBothAdopt() {
        let existing = [
            StaticRangeTaskSnapshot(taskIdentifier: 50, downloadID: "plex:item", baseOffset: 0, bodyBytesWritten: 100),
        ]

        let plan = StaticRangeReattachPolicy.plan(
            taskIdentifier: 51,
            downloadID: "plex:item",
            durableBytes: 0,
            requestedOffset: 512,
            rangeRequestShape: .closed,
            bodyBytesWritten: 10,
            existingTasks: existing,
            taskMarker: StaticRangeSegmentMarker.value(offset: 512, attemptID: "attempt-A"),
            segmentBytes: 512,
            rowAttemptID: "attempt-A"
        )

        #expect(plan == StaticRangeReattachPlan(candidateBaseOffset: 512, disposition: .adopt))
    }

    @Test("Two marked segments at the same offset supersede: newer adopted, older superseded")
    func twoMarkedSegmentsSameOffsetSupersede() {
        let existing = [
            StaticRangeTaskSnapshot(taskIdentifier: 60, downloadID: "plex:item", baseOffset: 512, bodyBytesWritten: 32),
        ]

        let plan = StaticRangeReattachPolicy.plan(
            taskIdentifier: 61,
            downloadID: "plex:item",
            durableBytes: 0,
            requestedOffset: 512,
            rangeRequestShape: .closed,
            bodyBytesWritten: 64,
            existingTasks: existing,
            taskMarker: StaticRangeSegmentMarker.value(offset: 512, attemptID: "attempt-A"),
            segmentBytes: 512,
            rowAttemptID: "attempt-A"
        )

        #expect(plan == StaticRangeReattachPlan(
            candidateBaseOffset: 512,
            disposition: .replaceExisting(existingTaskIdentifier: 60, existingBaseOffset: 512)
        ))
    }

    @Test("A v1 marker (no attempt token) is legacy — dropped even at a matching offset")
    func v1MarkerDropsAsLegacy() {
        let plan = StaticRangeReattachPolicy.plan(
            taskIdentifier: 45,
            downloadID: "plex:item",
            durableBytes: 0,
            requestedOffset: 0,
            rangeRequestShape: .closed,
            bodyBytesWritten: 10,
            existingTasks: [],
            taskMarker: StaticRangeSegmentMarker.value(offset: 0),
            rowAttemptID: "attempt-A"
        )

        #expect(plan == StaticRangeReattachPlan(
            candidateBaseOffset: 0,
            disposition: .dropLegacyRange(requestedOffset: 0, durableBytes: 0, rangeRequestShape: .closed)
        ))
    }

    @Test("A marked segment from a prior attempt is rejected as an attempt mismatch")
    func attemptMismatchRejected() {
        let plan = StaticRangeReattachPolicy.plan(
            taskIdentifier: 46,
            downloadID: "plex:item",
            durableBytes: 0,
            requestedOffset: 0,
            rangeRequestShape: .closed,
            bodyBytesWritten: 10,
            existingTasks: [],
            taskMarker: StaticRangeSegmentMarker.value(offset: 0, attemptID: "attempt-OLD"),
            rowAttemptID: "attempt-NEW"
        )

        #expect(plan == StaticRangeReattachPlan(
            candidateBaseOffset: 0,
            disposition: .rejectAttemptMismatch(taskAttemptID: "attempt-OLD", rowAttemptID: "attempt-NEW")
        ))
    }

    @Test("A tokened task against a row with no attempt is rejected, not adopted")
    func tokenedTaskAgainstTokenlessRowRejected() {
        let plan = StaticRangeReattachPolicy.plan(
            taskIdentifier: 47,
            downloadID: "plex:item",
            durableBytes: 0,
            requestedOffset: 0,
            rangeRequestShape: .closed,
            bodyBytesWritten: 10,
            existingTasks: [],
            taskMarker: StaticRangeSegmentMarker.value(offset: 0, attemptID: "attempt-OLD"),
            rowAttemptID: nil
        )

        #expect(plan == StaticRangeReattachPlan(
            candidateBaseOffset: 0,
            disposition: .rejectAttemptMismatch(taskAttemptID: "attempt-OLD", rowAttemptID: nil)
        ))
    }

    @Test("An attempt-stamped open-ended remainder from a prior attempt is rejected")
    func openEndedAttemptMismatchRejected() {
        let plan = StaticRangeReattachPolicy.plan(
            taskIdentifier: 48,
            downloadID: "plex:item",
            durableBytes: 512,
            requestedOffset: 512,
            rangeRequestShape: .openEnded,
            bodyBytesWritten: 0,
            existingTasks: [],
            taskMarker: DownloadAttemptMarker.taskDescription(ratingKey: "plex:item", attemptID: "attempt-OLD"),
            rowAttemptID: "attempt-NEW"
        )

        #expect(plan == StaticRangeReattachPlan(
            candidateBaseOffset: 512,
            disposition: .rejectAttemptMismatch(taskAttemptID: "attempt-OLD", rowAttemptID: "attempt-NEW")
        ))
    }

    @Test("An attempt-stamped open-ended remainder matching the row's attempt is adopted")
    func openEndedMatchingAttemptAdopted() {
        let plan = StaticRangeReattachPolicy.plan(
            taskIdentifier: 49,
            downloadID: "plex:item",
            durableBytes: 512,
            requestedOffset: 512,
            rangeRequestShape: .openEnded,
            bodyBytesWritten: 0,
            existingTasks: [],
            taskMarker: DownloadAttemptMarker.taskDescription(ratingKey: "plex:item", attemptID: "attempt-A"),
            rowAttemptID: "attempt-A"
        )

        #expect(plan == StaticRangeReattachPlan(candidateBaseOffset: 512, disposition: .adopt))
    }

    @Test("A malformed marker is treated as unmarked and legacy-dropped")
    func malformedMarkerDropsAsLegacy() {
        let plan = StaticRangeReattachPolicy.plan(
            taskIdentifier: 70,
            downloadID: "plex:item",
            durableBytes: 0,
            requestedOffset: 0,
            rangeRequestShape: .closed,
            bodyBytesWritten: 10,
            existingTasks: [],
            taskMarker: "lbs-segment:v1:abc"
        )

        #expect(plan == StaticRangeReattachPlan(
            candidateBaseOffset: 0,
            disposition: .dropLegacyRange(requestedOffset: 0, durableBytes: 0, rangeRequestShape: .closed)
        ))
    }

    @Test("A marker whose offset does not match the requested offset is treated as unmarked")
    func markerOffsetMismatchDropsAsLegacy() {
        let plan = StaticRangeReattachPolicy.plan(
            taskIdentifier: 71,
            downloadID: "plex:item",
            durableBytes: 0,
            requestedOffset: 512,
            rangeRequestShape: .closed,
            bodyBytesWritten: 10,
            existingTasks: [],
            taskMarker: StaticRangeSegmentMarker.value(offset: 0, attemptID: "attempt-A"),
            rowAttemptID: "attempt-A"
        )

        #expect(plan == StaticRangeReattachPlan(
            candidateBaseOffset: 512,
            disposition: .dropLegacyRange(requestedOffset: 512, durableBytes: 0, rangeRequestShape: .closed)
        ))
    }
}
