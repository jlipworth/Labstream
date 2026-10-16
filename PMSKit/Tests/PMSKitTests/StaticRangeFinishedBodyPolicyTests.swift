import Testing
@testable import PMSKit

@Suite("Static range finished body policy")
struct StaticRangeFinishedBodyPolicyTests {
    @Test("Cancel halt discards a finished body before stashing")
    func cancelHaltDiscards() {
        #expect(StaticRangeFinishedBodyPolicy.shouldDiscardBeforeStash(haltKind: .cancel))
        #expect(StaticRangeFinishedBodyPolicy.disposition(haltKind: .cancel) == .discardTemp)
    }

    @Test("Pause halt preserves a finished body and then stays paused (even before `.paused` is persisted)")
    func pauseHaltPreserves() {
        // The halt KIND is recorded synchronously at the halt site; the row status lands only at
        // the end of the pause chain. A body finishing inside that window must still be preserved.
        #expect(!StaticRangeFinishedBodyPolicy.shouldDiscardBeforeStash(haltKind: .pause))
        #expect(StaticRangeFinishedBodyPolicy.disposition(haltKind: .pause) == .writeThenPause)
    }

    @Test("Unhalted finished body continues normally")
    func unhaltedContinues() {
        #expect(!StaticRangeFinishedBodyPolicy.shouldDiscardBeforeStash(haltKind: nil))
        #expect(StaticRangeFinishedBodyPolicy.disposition(haltKind: nil) == .writeThenContinue)
    }
}
