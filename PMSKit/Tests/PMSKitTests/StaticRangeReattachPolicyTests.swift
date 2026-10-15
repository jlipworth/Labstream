import Testing
@testable import PMSKit

@Suite("Static range reattach policy")
struct StaticRangeReattachPolicyTests {
    struct UnownedRangeCase: Sendable, CustomTestStringConvertible {
        let note: String
        let durableBytes: Int
        let requestedOffset: Int?
        let rangeRequestShape: StaticRangeRequestShape
        let bodyBytesWritten: Int
        let taskMarker: String?
        let rowAttemptID: String?

        var testDescription: String { note }
    }

    /// Every row fails the current-marker guard, so the range is rejected as unowned rather than
    /// adopted, with `candidateBaseOffset = requestedOffset ?? durableBytes`. The current-marker
    /// adopt counterpart is `markedClosedSegmentAdopted`.
    @Test("Unmarked or legacy-marked ranges are rejected as unowned", arguments: [
        UnownedRangeCase(note: "unowned closed range", durableBytes: 128, requestedOffset: 64,
                         rangeRequestShape: .closed, bodyBytesWritten: 10, taskMarker: nil, rowAttemptID: nil),
        UnownedRangeCase(note: "missing range", durableBytes: 256, requestedOffset: nil,
                         rangeRequestShape: .missing, bodyBytesWritten: -5, taskMarker: nil, rowAttemptID: nil),
        UnownedRangeCase(note: "invalid range", durableBytes: 256, requestedOffset: nil,
                         rangeRequestShape: .invalid, bodyBytesWritten: 0, taskMarker: nil, rowAttemptID: nil),
        UnownedRangeCase(note: "unmarked closed range at offset 0", durableBytes: 0, requestedOffset: 0,
                         rangeRequestShape: .closed, bodyBytesWritten: 10, taskMarker: nil, rowAttemptID: nil),
        UnownedRangeCase(note: "v1 marker (no attempt token) is legacy even at a matching offset",
                         durableBytes: 0, requestedOffset: 0, rangeRequestShape: .closed, bodyBytesWritten: 10,
                         taskMarker: "lbs-segment:v1:0", rowAttemptID: "attempt-A"),
        UnownedRangeCase(note: "malformed marker is treated as unmarked", durableBytes: 0, requestedOffset: 0,
                         rangeRequestShape: .closed, bodyBytesWritten: 10,
                         taskMarker: "lbs-segment:v1:abc", rowAttemptID: nil),
        UnownedRangeCase(note: "v2 marker (legacy format with a matching token) is not current",
                         durableBytes: 0, requestedOffset: 0, rangeRequestShape: .closed, bodyBytesWritten: 10,
                         taskMarker: "lbs-segment:v2:0:attempt-A", rowAttemptID: "attempt-A"),
    ])
    func unownedOrLegacyMarkerRejected(_ testCase: UnownedRangeCase) {
        let plan = StaticRangeReattachPolicy.plan(
            taskIdentifier: 10,
            downloadID: "plex:item",
            durableBytes: testCase.durableBytes,
            requestedOffset: testCase.requestedOffset,
            rangeRequestShape: testCase.rangeRequestShape,
            bodyBytesWritten: testCase.bodyBytesWritten,
            existingTasks: [],
            taskMarker: testCase.taskMarker,
            rowAttemptID: testCase.rowAttemptID.map { DownloadAttemptID(rawValue: $0)! }
        )

        #expect(plan == StaticRangeReattachPlan(
            candidateBaseOffset: testCase.requestedOffset ?? testCase.durableBytes,
            disposition: .rejectUnownedRange(
                requestedOffset: testCase.requestedOffset,
                durableBytes: testCase.durableBytes,
                rangeRequestShape: testCase.rangeRequestShape)
        ))
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
            existingTasks: [],
            taskMarker: DownloadAttemptMarker.taskDescription(
                ratingKey: "plex:item", attemptID: DownloadAttemptID(rawValue: "attempt-A")!),
            rowAttemptID: DownloadAttemptID(rawValue: "attempt-A")!
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
            existingTasks: [],
            taskMarker: DownloadAttemptMarker.taskDescription(
                ratingKey: "emby:item", attemptID: DownloadAttemptID(rawValue: "attempt-A")!),
            rowAttemptID: DownloadAttemptID(rawValue: "attempt-A")!
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
            ],
            taskMarker: DownloadAttemptMarker.taskDescription(
                ratingKey: "emby:item", attemptID: DownloadAttemptID(rawValue: "attempt-A")!),
            rowAttemptID: DownloadAttemptID(rawValue: "attempt-A")!
        )

        #expect(plan == StaticRangeReattachPlan(
            candidateBaseOffset: 512,
            disposition: .replaceExisting(existingTaskIdentifier: 29, existingBaseOffset: 512)
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
            taskMarker: StaticRangeSegmentMarker.value(offset: 0, attemptID: DownloadAttemptID(rawValue: "attempt-A")!),
            rowAttemptID: DownloadAttemptID(rawValue: "attempt-A")!
        )

        #expect(plan == StaticRangeReattachPlan(candidateBaseOffset: 0, disposition: .adopt))
    }

    /// Every row is a matching current marker on a closed range requested ahead of the durable
    /// checkpoint. (300, 812): the planner anchors its grid at the durable bytes of plan time — a
    /// legacy open-ended partial (durable 300) plans segments at 300, 812, 1324... None of those
    /// are aligned to an absolute grid; the attempt token proves ownership, so they must still
    /// reattach. (350, 812): a crash mid-append leaves durable bytes off the train's own grid
    /// (e.g. 350 of a head segment [300, 812)); the surviving off-head segments are owned and
    /// ahead — adopt.
    @Test("A marked closed segment ahead of the durable checkpoint is adopted",
          arguments: [(0, 512), (300, 812), (350, 812)])
    func markedClosedSegmentAheadOfDurableAdopted(durable: Int, requested: Int) {
        let plan = StaticRangeReattachPolicy.plan(
            taskIdentifier: 42,
            downloadID: "plex:item",
            durableBytes: durable,
            requestedOffset: requested,
            rangeRequestShape: .closed,
            bodyBytesWritten: 10,
            existingTasks: [],
            taskMarker: StaticRangeSegmentMarker.value(offset: requested, attemptID: DownloadAttemptID(rawValue: "attempt-A")!),
            rowAttemptID: DownloadAttemptID(rawValue: "attempt-A")!
        )

        #expect(plan == StaticRangeReattachPlan(candidateBaseOffset: requested, disposition: .adopt))
    }

    @Test("A marked segment behind the durable checkpoint is rejected")
    func markedClosedSegmentBehindDurableRejected() {
        let plan = StaticRangeReattachPolicy.plan(
            taskIdentifier: 44,
            downloadID: "plex:item",
            durableBytes: 600,
            requestedOffset: 512,
            rangeRequestShape: .closed,
            bodyBytesWritten: 10,
            existingTasks: [],
            taskMarker: StaticRangeSegmentMarker.value(offset: 512, attemptID: DownloadAttemptID(rawValue: "attempt-A")!),
            rowAttemptID: DownloadAttemptID(rawValue: "attempt-A")!
        )

        #expect(plan == StaticRangeReattachPlan(
            candidateBaseOffset: 512,
            disposition: .rejectOffsetMismatch(requestedOffset: 512, durableBytes: 600)
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
            taskMarker: StaticRangeSegmentMarker.value(offset: 512, attemptID: DownloadAttemptID(rawValue: "attempt-A")!),
            rowAttemptID: DownloadAttemptID(rawValue: "attempt-A")!
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
            taskMarker: StaticRangeSegmentMarker.value(offset: 512, attemptID: DownloadAttemptID(rawValue: "attempt-A")!),
            rowAttemptID: DownloadAttemptID(rawValue: "attempt-A")!
        )

        #expect(plan == StaticRangeReattachPlan(
            candidateBaseOffset: 512,
            disposition: .replaceExisting(existingTaskIdentifier: 60, existingBaseOffset: 512)
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
            taskMarker: StaticRangeSegmentMarker.value(offset: 0, attemptID: DownloadAttemptID(rawValue: "attempt-OLD")!),
            rowAttemptID: DownloadAttemptID(rawValue: "attempt-NEW")!
        )

        #expect(plan == StaticRangeReattachPlan(
            candidateBaseOffset: 0,
            disposition: .rejectAttemptMismatch(
                taskAttemptID: DownloadAttemptID(rawValue: "attempt-OLD")!,
                rowAttemptID: DownloadAttemptID(rawValue: "attempt-NEW")!)
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
            taskMarker: StaticRangeSegmentMarker.value(offset: 0, attemptID: DownloadAttemptID(rawValue: "attempt-OLD")!),
            rowAttemptID: nil
        )

        #expect(plan == StaticRangeReattachPlan(
            candidateBaseOffset: 0,
            disposition: .rejectAttemptMismatch(
                taskAttemptID: DownloadAttemptID(rawValue: "attempt-OLD")!,
                rowAttemptID: nil)
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
            taskMarker: DownloadAttemptMarker.taskDescription(ratingKey: "plex:item", attemptID: DownloadAttemptID(rawValue: "attempt-OLD")!),
            rowAttemptID: DownloadAttemptID(rawValue: "attempt-NEW")!
        )

        #expect(plan == StaticRangeReattachPlan(
            candidateBaseOffset: 512,
            disposition: .rejectAttemptMismatch(
                taskAttemptID: DownloadAttemptID(rawValue: "attempt-OLD")!,
                rowAttemptID: DownloadAttemptID(rawValue: "attempt-NEW")!)
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
            taskMarker: StaticRangeSegmentMarker.value(offset: 0, attemptID: DownloadAttemptID(rawValue: "attempt-A")!),
            rowAttemptID: DownloadAttemptID(rawValue: "attempt-A")!
        )

        #expect(plan == StaticRangeReattachPlan(
            candidateBaseOffset: 512,
            disposition: .rejectUnownedRange(requestedOffset: 512, durableBytes: 0, rangeRequestShape: .closed)
        ))
    }
}
