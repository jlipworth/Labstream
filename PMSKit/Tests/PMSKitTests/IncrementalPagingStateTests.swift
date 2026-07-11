import Testing
@testable import PMSKit

struct IncrementalPagingStateTests {
    @Test func initialRequestStartsAtZeroAndRejectsDuplicates() {
        var state = IncrementalPagingState(identity: "a", pageSize: 2)
        #expect(state.nextOffset == 0)
        #expect(state.beginRequest(offset: 0) != nil)
        #expect(state.beginRequest(offset: 0) == nil)
    }

    @Test func fullUnknownPageContinuesAndShortOrEmptyPageEnds() {
        var state = IncrementalPagingState(identity: "a", pageSize: 2)
        let first = state.beginRequest(offset: 0)!
        let acceptedFirst = state.acceptPage(["1", "2"], reportedTotal: nil, token: first)
        #expect(acceptedFirst)
        #expect(!state.isTerminal)
        #expect(state.nextOffset == 2)
        let second = state.beginRequest(offset: 2)!
        let acceptedSecond = state.acceptPage(["3"], reportedTotal: nil, token: second)
        #expect(acceptedSecond)
        #expect(state.isTerminal)

        state.refresh(identity: "a")
        let empty = state.beginRequest(offset: 0)!
        let acceptedEmpty = state.acceptPage([], reportedTotal: nil, token: empty)
        #expect(acceptedEmpty)
        #expect(state.isTerminal)
    }

    @Test func coveredReportedTotalEndsPaging() {
        var state = IncrementalPagingState(identity: "a", pageSize: 2)
        let token = state.beginRequest(offset: 0)!
        let accepted = state.acceptPage(["1", "2"], reportedTotal: 2, token: token)
        #expect(accepted)
        #expect(state.isTerminal)
    }

    @Test func laterFailureRetainsItemsAndCanRetry() {
        var state = IncrementalPagingState(identity: "a", pageSize: 2)
        let first = state.beginRequest(offset: 0)!
        _ = state.acceptPage(["1", "2"], reportedTotal: nil, token: first)
        let failed = state.beginRequest(offset: 2)!
        let acceptedFailure = state.acceptFailure(token: failed)
        #expect(acceptedFailure)
        #expect(state.loadedIDs == ["1", "2"])
        #expect(state.failedOffset == 2)
        let retry = state.beginRequest(offset: 2)
        #expect(retry != nil)
        #expect(state.failedOffset == nil)
    }

    @Test func refreshRejectsOldGenerationAndIdentityResults() {
        var state = IncrementalPagingState(identity: "a", pageSize: 2)
        let old = state.beginRequest(offset: 0)!
        state.refresh(identity: "b")
        #expect(state.generation == 1)
        let acceptedOld = state.acceptPage(["old"], reportedTotal: nil, token: old)
        #expect(!acceptedOld)
        #expect(state.loadedIDs.isEmpty)
    }

    @Test func duplicateIDsAreNotAppendedTwice() {
        var state = IncrementalPagingState(identity: "a", pageSize: 3)
        let token = state.beginRequest(offset: 0)!
        _ = state.acceptPage(["1", "1", "2"], reportedTotal: nil, token: token)
        #expect(state.loadedIDs == ["1", "2"])
        #expect(state.nextOffset == 3)
    }
}
