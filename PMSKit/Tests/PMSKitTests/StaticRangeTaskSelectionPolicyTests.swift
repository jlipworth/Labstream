import Testing
@testable import PMSKit

@Suite("Static range task selection policy")
struct StaticRangeTaskSelectionPolicyTests {

    @Test("Duplicate decision keeps the furthest checkpoint task")
    func furthestCheckpointWins() {
        let candidate = StaticRangeTaskSnapshot(
            taskIdentifier: 3,
            downloadID: "plex:movie",
            baseOffset: 128,
            chunkBytesWritten: 0
        )
        let existing = [
            StaticRangeTaskSnapshot(taskIdentifier: 1, downloadID: "plex:movie", baseOffset: 64, chunkBytesWritten: 20),
            StaticRangeTaskSnapshot(taskIdentifier: 2, downloadID: "other", baseOffset: 1_000, chunkBytesWritten: 0),
        ]

        let decision = StaticRangeTaskSelectionPolicy.duplicateDecision(
            candidate: candidate,
            existingTasks: existing
        )

        #expect(decision == StaticRangeDuplicateTaskDecision(
            existingTaskIdentifier: 1,
            existingBaseOffset: 64,
            shouldReplaceExisting: true
        ))
    }

    @Test("Duplicate decision keeps the task with more chunk bytes when checkpoints tie")
    func chunkBytesBreakTies() {
        let candidate = StaticRangeTaskSnapshot(
            taskIdentifier: 4,
            downloadID: "jellyfin:item",
            baseOffset: 64,
            chunkBytesWritten: 10
        )
        let existing = [
            StaticRangeTaskSnapshot(taskIdentifier: 5, downloadID: "jellyfin:item", baseOffset: 64, chunkBytesWritten: 40),
        ]

        let decision = StaticRangeTaskSelectionPolicy.duplicateDecision(
            candidate: candidate,
            existingTasks: existing
        )

        #expect(decision == StaticRangeDuplicateTaskDecision(
            existingTaskIdentifier: 5,
            existingBaseOffset: 64,
            shouldReplaceExisting: false
        ))
    }

    @Test("Newer task lookup ignores other rows and the current task")
    func newerTaskLookup() {
        let current = StaticRangeTaskSnapshot(
            taskIdentifier: 10,
            downloadID: "emby:item",
            baseOffset: 64,
            chunkBytesWritten: 50
        )
        let newer = StaticRangeTaskSnapshot(
            taskIdentifier: 11,
            downloadID: "emby:item",
            baseOffset: 128,
            chunkBytesWritten: 0
        )
        let other = StaticRangeTaskSnapshot(
            taskIdentifier: 12,
            downloadID: "other",
            baseOffset: 512,
            chunkBytesWritten: 0
        )

        #expect(StaticRangeTaskSelectionPolicy.newerTaskIdentifier(
            than: current,
            in: [current, newer, other]
        ) == 11)
    }

    @Test("Equal progress is not newer")
    func equalProgressIsNotNewer() {
        let current = StaticRangeTaskSnapshot(
            taskIdentifier: 20,
            downloadID: "row",
            baseOffset: 64,
            chunkBytesWritten: 10
        )
        let equal = StaticRangeTaskSnapshot(
            taskIdentifier: 21,
            downloadID: "row",
            baseOffset: 64,
            chunkBytesWritten: 10
        )

        #expect(!StaticRangeTaskSelectionPolicy.isNewer(equal, than: current))
        #expect(StaticRangeTaskSelectionPolicy.newerTaskIdentifier(than: current, in: [equal]) == nil)
    }
}
