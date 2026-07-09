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
}
