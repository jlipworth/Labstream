import Testing
@testable import PMSKit

@Suite("Static range finished body policy")
struct StaticRangeFinishedBodyPolicyTests {
    @Test("Cancel halt discards a finished body before stashing")
    func cancelHaltDiscards() {
        #expect(StaticRangeFinishedBodyPolicy.shouldDiscardBeforeStash(haltKind: .cancel))
        #expect(StaticRangeFinishedBodyPolicy.disposition(haltKind: .cancel) == .discardTemp)
    }

    @Test("Pause halt preserves a finished body and then stays paused")
    func pauseHaltPreserves() {
        #expect(!StaticRangeFinishedBodyPolicy.shouldDiscardBeforeStash(haltKind: .pause))
        #expect(StaticRangeFinishedBodyPolicy.disposition(haltKind: .pause) == .writeThenPause)
    }

    @Test("Pause halt preserves even before the async pause chain persists `.paused`")
    func pauseHaltPreservesBeforeStatusWrite() {
        // The halt KIND is recorded synchronously at the halt site; the row status lands only at
        // the end of the pause chain. A body finishing inside that window must still be preserved.
        #expect(StaticRangeFinishedBodyPolicy.disposition(haltKind: .pause) == .writeThenPause)
        #expect(!StaticRangeFinishedBodyPolicy.shouldDiscardBeforeStash(haltKind: .pause))
    }

    @Test("Unhalted finished body continues normally")
    func unhaltedContinues() {
        #expect(!StaticRangeFinishedBodyPolicy.shouldDiscardBeforeStash(haltKind: nil))
        #expect(StaticRangeFinishedBodyPolicy.disposition(haltKind: nil) == .writeThenContinue)
    }
}
