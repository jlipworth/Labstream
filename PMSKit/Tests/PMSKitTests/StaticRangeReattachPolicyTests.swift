import Testing
@testable import PMSKit

@Suite("Static range reattach policy")
struct StaticRangeReattachPolicyTests {

    @Test("Requested offset must match the durable partial checkpoint")
    func rejectsOffsetMismatch() {
        let plan = StaticRangeReattachPolicy.plan(
            taskIdentifier: 10,
            downloadID: "plex:item",
            durableBytes: 128,
            requestedOffset: 64,
            chunkBytesWritten: 10,
            existingTasks: []
        )

        #expect(plan == StaticRangeReattachPlan(
            candidateBaseOffset: 64,
            disposition: .rejectOffsetMismatch(requestedOffset: 64, durableBytes: 128)
        ))
    }

    @Test("Missing Range offset falls back to the durable partial size")
    func missingOffsetUsesDurableBytes() {
        let plan = StaticRangeReattachPolicy.plan(
            taskIdentifier: 11,
            downloadID: "jellyfin:item",
            durableBytes: 256,
            requestedOffset: nil,
            chunkBytesWritten: -5,
            existingTasks: []
        )

        #expect(plan == StaticRangeReattachPlan(candidateBaseOffset: 256, disposition: .adopt))
    }

    @Test("A reattached task can replace an older lower-checkpoint task")
    func replacesOlderDuplicate() {
        let plan = StaticRangeReattachPolicy.plan(
            taskIdentifier: 20,
            downloadID: "emby:item",
            durableBytes: 512,
            requestedOffset: 512,
            chunkBytesWritten: 0,
            existingTasks: [
                StaticRangeTaskSnapshot(
                    taskIdentifier: 19,
                    downloadID: "emby:item",
                    baseOffset: 256,
                    chunkBytesWritten: 64
                ),
            ]
        )

        #expect(plan == StaticRangeReattachPlan(
            candidateBaseOffset: 512,
            disposition: .replaceExisting(existingTaskIdentifier: 19, existingBaseOffset: 256)
        ))
    }

    @Test("A reattached task is suppressed by a newer same-row task")
    func suppressesOlderDuplicate() {
        let plan = StaticRangeReattachPolicy.plan(
            taskIdentifier: 30,
            downloadID: "plex:item",
            durableBytes: 512,
            requestedOffset: 512,
            chunkBytesWritten: 8,
            existingTasks: [
                StaticRangeTaskSnapshot(
                    taskIdentifier: 31,
                    downloadID: "plex:item",
                    baseOffset: 512,
                    chunkBytesWritten: 32
                ),
                StaticRangeTaskSnapshot(
                    taskIdentifier: 32,
                    downloadID: "other",
                    baseOffset: 9_999,
                    chunkBytesWritten: 0
                ),
            ]
        )

        #expect(plan == StaticRangeReattachPlan(
            candidateBaseOffset: 512,
            disposition: .suppressForExisting(existingTaskIdentifier: 31, existingBaseOffset: 512)
        ))
    }
}
