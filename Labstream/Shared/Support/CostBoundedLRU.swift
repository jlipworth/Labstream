/// In-memory LRU with explicit cost and optional entry ceilings. Values can vary by orders of
/// magnitude, so a fixed entry count alone is not a meaningful memory bound.
struct CostBoundedLRU<Key: Hashable, Value> {
    private struct Entry {
        var value: Value
        let cost: Int
        var access: UInt64
    }

    private let costLimit: Int
    private let countLimit: Int
    private var entries: [Key: Entry] = [:]
    private var nextAccess: UInt64 = 0
    private(set) var totalCost = 0

    init(costLimit: Int, countLimit: Int = .max) {
        self.costLimit = max(0, costLimit)
        self.countLimit = max(0, countLimit)
    }

    var count: Int { entries.count }
    var keys: [Key] { Array(entries.keys) }

    mutating func value(for key: Key) -> Value? {
        guard var entry = entries[key] else { return nil }
        nextAccess &+= 1
        entry.access = nextAccess
        entries[key] = entry
        return entry.value
    }

    mutating func insert(_ value: Value, for key: Key, cost: Int) {
        if let old = entries.removeValue(forKey: key) { totalCost -= old.cost }
        guard costLimit > 0, countLimit > 0 else { return }
        let normalizedCost = max(1, cost)
        guard normalizedCost <= costLimit else { return }

        // Make room before addition so even an intentionally extreme test budget near `Int.max`
        // cannot overflow the accounting value.
        while totalCost > costLimit - normalizedCost || entries.count >= countLimit {
            guard evictLeastRecentlyUsed() else { break }
        }
        nextAccess &+= 1
        entries[key] = Entry(value: value, cost: normalizedCost, access: nextAccess)
        totalCost += normalizedCost
    }

    mutating func removeValue(for key: Key) {
        if let removed = entries.removeValue(forKey: key) {
            totalCost -= removed.cost
        }
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: false)
        totalCost = 0
    }

    @discardableResult
    private mutating func evictLeastRecentlyUsed() -> Bool {
        guard let victim = entries.min(by: { $0.value.access < $1.value.access })?.key,
              let removed = entries.removeValue(forKey: victim) else { return false }
        totalCost = max(0, totalCost - removed.cost)
        return true
    }
}
