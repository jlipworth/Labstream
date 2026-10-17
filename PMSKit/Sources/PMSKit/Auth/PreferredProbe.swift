import Foundation

/// Concurrent probing of candidates that are ranked by preference.
///
/// Callers such as Plex connection resolution rank candidates (LAN before remote before
/// relay) and must use the *most preferred* candidate that answers, not merely the fastest.
/// Probing them one at a time makes every dead candidate cost a full timeout; probing them
/// all and draining the group makes the slowest dead candidate gate every result.
public enum PreferredProbe {
    /// Run `probe` for every index in `0..<count` concurrently and return the lowest index
    /// whose probe produced a value.
    ///
    /// The result is decided as soon as every lower-ranked index has failed and one index
    /// has succeeded; the remaining probes are then cancelled, so a dead lower-preference
    /// candidate never delays a preferred success. Selection is identical to waiting for
    /// every probe and taking the lowest successful index. Returns nil when every probe fails.
    public static func firstSuccess<T: Sendable>(
        count: Int,
        _ probe: @escaping @Sendable (Int) async -> T?
    ) async -> (index: Int, value: T)? {
        guard count > 0 else { return nil }
        return await withTaskGroup(of: (Int, T?).self) { group in
            for index in 0..<count {
                group.addTask { (index, await probe(index)) }
            }
            // nil = still pending; .some(nil) = failed; .some(value) = succeeded.
            var outcomes = [T??](repeating: nil, count: count)
            var frontier = 0
            while let (index, value) = await group.next() {
                outcomes[index] = .some(value)
                while frontier < count, case let .some(resolved) = outcomes[frontier] {
                    if let resolved {
                        group.cancelAll()
                        return (frontier, resolved)
                    }
                    frontier += 1
                }
            }
            return nil
        }
    }
}
