import Foundation

/// Who owns the publication of one finished forward-only body.
public enum ForwardOnlyPublicationOwner: Sendable, Equatable {
    /// A publication is queued, waiting for the lease or running.
    case worker
    /// A publication timed out on the lease and waits to be asked again.
    case parkedRetry
}

/// Who owns the publication of a finished forward-only body, per body.
///
/// Between the URLSession temp file and the working path a finished body has exactly one owner
/// in the process: a worker (a publication that is queued, waiting for the working path's lease
/// or running), or a parked retry (a publication that could not get the lease before its
/// deadline and waits to be asked again). `Key` names the body: the path it waits at, which for
/// a captured body is derived from its attempt. The ledger makes three things true:
///
/// - Only one publication of a body exists at a time. The delegate claims before it moves the
///   body to its capture path, so launch recovery, which looks for a body at that path, can
///   never claim the same body in between and queue a second publication.
/// - A claim always has an owner that will act. A worker that times out on the lease parks its
///   work here instead of leaving the claim behind with nothing queued.
/// - A parked retry is woken by the lease release it waited for, or by anyone asking for that
///   body again, and becomes a worker again in the same step.
///
/// `Work` is whatever the owner needs to run the publication again. The ledger never runs it.
public final class ForwardOnlyPublicationLedger<Key: Hashable, Work>: @unchecked Sendable {
    public typealias Owner = ForwardOnlyPublicationOwner

    private enum Entry {
        case worker
        case parked(path: String, work: Work)
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]

    public init() {}

    /// Take the publication for a new worker. False when a worker or a parked retry already
    /// owns it: the caller must not queue a second publication.
    public func claim(_ key: Key) -> Bool {
        lock.withLock {
            guard entries[key] == nil else { return false }
            entries[key] = .worker
            return true
        }
    }

    /// The worker could not get the lease on `path` in time. Its work is kept, and the claim
    /// now belongs to the retry. False when `key` has no worker (the claim was released).
    @discardableResult
    public func park(_ key: Key, waitingFor path: String, work: Work) -> Bool {
        lock.withLock {
            guard case .worker? = entries[key] else { return false }
            entries[key] = .parked(path: path, work: work)
            return true
        }
    }

    /// A lease on `paths` was released: every retry parked on one of them becomes a worker
    /// again, and its work is handed back to be run.
    public func resume(releasedPaths paths: Set<String>) -> [(key: Key, work: Work)] {
        lock.withLock {
            var resumed: [(key: Key, work: Work)] = []
            for (key, entry) in entries {
                guard case .parked(let path, let work) = entry, paths.contains(path) else { continue }
                entries[key] = .worker
                resumed.append((key, work))
            }
            return resumed
        }
    }

    /// Someone asked for `key` again (a recovery pass, or the backstop timer). A parked retry
    /// becomes a worker and its work is handed back; nil when a worker already owns it or
    /// nothing does.
    public func resume(_ key: Key) -> Work? {
        lock.withLock {
            guard case .parked(_, let work)? = entries[key] else { return nil }
            entries[key] = .worker
            return work
        }
    }

    /// The publication ended (published, discarded or failed): nothing owns it any more.
    public func release(_ key: Key) {
        lock.withLock { _ = entries.removeValue(forKey: key) }
    }

    public func owner(of key: Key) -> Owner? {
        lock.withLock {
            switch entries[key] {
            case .worker?: return .worker
            case .parked?: return .parkedRetry
            case nil: return nil
            }
        }
    }

    public var parkedKeys: [Key] {
        lock.withLock {
            entries.compactMap { key, entry in
                if case .parked = entry { return key }
                return nil
            }
        }
    }
}
