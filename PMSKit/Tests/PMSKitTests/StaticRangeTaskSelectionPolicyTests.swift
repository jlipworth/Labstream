import Testing
@testable import PMSKit

@Suite("Static range task selection policy")
struct StaticRangeTaskSelectionPolicyTests {
    @Test("Duplicate decision keeps the furthest durable offset task")
    func furthestOffsetWins() {
        let candidate = StaticRangeTaskSnapshot(
            taskIdentifier: 3,
            downloadID: "plex:movie",
            baseOffset: 128,
            bodyBytesWritten: 0
        )
        let existing = [
            StaticRangeTaskSnapshot(taskIdentifier: 1, downloadID: "plex:movie", baseOffset: 64, bodyBytesWritten: 20),
            StaticRangeTaskSnapshot(taskIdentifier: 2, downloadID: "other", baseOffset: 1_000, bodyBytesWritten: 0),
        ]

        #expect(StaticRangeTaskSelectionPolicy.duplicateDecision(
            candidate: candidate,
            existingTasks: existing
        ) == StaticRangeDuplicateTaskDecision(
            existingTaskIdentifier: 1,
            existingBaseOffset: 64,
            shouldReplaceExisting: true
        ))
    }

    @Test("Duplicate decision keeps the task with more body bytes when offsets tie")
    func bodyBytesBreakTies() {
        let candidate = StaticRangeTaskSnapshot(
            taskIdentifier: 4,
            downloadID: "jellyfin:item",
            baseOffset: 64,
            bodyBytesWritten: 10
        )
        let existing = [
            StaticRangeTaskSnapshot(taskIdentifier: 5, downloadID: "jellyfin:item", baseOffset: 64, bodyBytesWritten: 40),
        ]

        #expect(StaticRangeTaskSelectionPolicy.duplicateDecision(
            candidate: candidate,
            existingTasks: existing
        ) == StaticRangeDuplicateTaskDecision(
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
            baseOffset: 100,
            bodyBytesWritten: 50
        )
        let newer = StaticRangeTaskSnapshot(
            taskIdentifier: 11,
            downloadID: "emby:item",
            baseOffset: 200,
            bodyBytesWritten: 0
        )
        let other = StaticRangeTaskSnapshot(
            taskIdentifier: 12,
            downloadID: "other",
            baseOffset: 10_000,
            bodyBytesWritten: 0
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
            baseOffset: 100,
            bodyBytesWritten: 10
        )
        let equal = StaticRangeTaskSnapshot(
            taskIdentifier: 21,
            downloadID: "row",
            baseOffset: 100,
            bodyBytesWritten: 10
        )
        #expect(!StaticRangeTaskSelectionPolicy.isNewer(equal, than: current))
    }
}
