import Foundation

/// Backend-agnostic paging math for sparse paged grids.
public struct PagingPageWindow: Sendable, Equatable {
    public let pageSize: Int

    public init(pageSize: Int) {
        precondition(pageSize > 0, "pageSize must be greater than zero")
        self.pageSize = pageSize
    }

    public func page(containing index: Int) -> Int? {
        guard index >= 0 else { return nil }
        return index / pageSize
    }

    public func startOffset(forPage page: Int) -> Int? {
        guard page >= 0 else { return nil }
        return page * pageSize
    }

    public static func normalizedTotal(reported: Int?, returnedCount: Int) -> Int {
        max(reported ?? returnedCount, returnedCount)
    }

    public static func slots<Item>(total: Int, inserting items: [Item], at start: Int = 0) -> [Item?] {
        var slots = [Item?](repeating: nil, count: max(total, 0))
        insert(items, into: &slots, at: start)
        return slots
    }

    public static func insert<Item>(_ items: [Item], into slots: inout [Item?], at start: Int) {
        guard start >= 0 else { return }
        for (index, item) in items.enumerated() where slots.indices.contains(start + index) {
            slots[start + index] = item
        }
    }
}
