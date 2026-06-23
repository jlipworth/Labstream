import Foundation
import Testing
@testable import PMSKit

@Suite("Paging page window")
struct PagingPageWindowTests {
    @Test func mapsIndicesToPagesAndStarts() {
        let window = PagingPageWindow(pageSize: 200)
        #expect(window.page(containing: 0) == 0)
        #expect(window.page(containing: 199) == 0)
        #expect(window.page(containing: 200) == 1)
        #expect(window.startOffset(forPage: 0) == 0)
        #expect(window.startOffset(forPage: 2) == 400)
    }

    @Test func rejectsNegativeIndicesAndPages() {
        let window = PagingPageWindow(pageSize: 200)
        #expect(window.page(containing: -1) == nil)
        #expect(window.startOffset(forPage: -1) == nil)
    }

    @Test func normalizesReportedTotalAgainstReturnedCount() {
        #expect(PagingPageWindow.normalizedTotal(reported: nil, returnedCount: 3) == 3)
        #expect(PagingPageWindow.normalizedTotal(reported: 10, returnedCount: 3) == 10)
        #expect(PagingPageWindow.normalizedTotal(reported: 1, returnedCount: 3) == 3)
    }

    @Test func createsSparseSlotsAndClampsInsertionToBounds() {
        let slots = PagingPageWindow.slots(total: 5, inserting: ["A", "B", "C"], at: 3)
        #expect(slots.map { $0 ?? "_" } == ["_", "_", "_", "A", "B"])
    }

    @Test func insertIgnoresNegativeStarts() {
        var slots = [String?](repeating: nil, count: 2)
        PagingPageWindow.insert(["A"], into: &slots, at: -1)
        #expect(slots.allSatisfy { $0 == nil })
    }
}
