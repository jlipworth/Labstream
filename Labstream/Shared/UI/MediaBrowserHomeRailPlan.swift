import Foundation
import PMSKit

/// Stable request and presentation plan for Jellyfin/Emby Home rails.
///
/// The plan is deliberately separate from execution. It gives every independent request a
/// durable key and canonical display position while the provider feeds bounded task-group
/// completions into the reducer and progressively publishes each resulting snapshot.
struct MediaBrowserHomeRailPlan {
    enum Key: Hashable, Sendable {
        case continueWatching
        case nextUp
        case latest(libraryID: String)

        var stableID: String {
            switch self {
            case .continueWatching:
                return "continue-watching"
            case .nextUp:
                return "next-up"
            case .latest(let libraryID):
                return "latest-\(libraryID)"
            }
        }
    }

    enum Request: Hashable, Sendable {
        case resume(limit: Int)
        case nextUp(limit: Int)
        case latest(parentID: String, itemTypes: String, limit: Int)
    }

    struct Entry {
        let key: Key
        let title: String
        let request: Request
        let destination: RailViewAllDestination
    }

    struct Work: Sendable {
        let key: Key
        let request: Request
    }

    let entries: [Entry]

    var work: [Work] {
        entries.map { Work(key: $0.key, request: $0.request) }
    }

    var latestEntries: [Entry] {
        entries.filter {
            if case .latest = $0.key { return true }
            return false
        }
    }

    func request(for key: Key) -> Request? {
        entries.first { $0.key == key }?.request
    }

    init(libraries: [MediaBrowserHomeLibraryLink],
         backend: MediaBackendKind,
         sessionIdentity: String) {
        var entries: [Entry] = [
            Entry(
                key: .continueWatching,
                title: "Continue Watching",
                request: .resume(limit: 20),
                destination: RailViewAllDestination(
                    title: "Continue Watching",
                    backend: backend,
                    sessionIdentity: sessionIdentity,
                    query: .mediaBrowserResume(parentID: nil)
                )
            ),
            Entry(
                key: .nextUp,
                title: "Next Up",
                request: .nextUp(limit: 20),
                destination: RailViewAllDestination(
                    title: "Next Up",
                    backend: backend,
                    sessionIdentity: sessionIdentity,
                    query: .mediaBrowserNextUp(parentID: nil)
                )
            ),
        ]

        // MediaBrowser servers should expose unique view ids, but malformed responses can repeat
        // one. First occurrence wins in native server order, and duplicates do not consume one of
        // the eight Latest request slots.
        var seenLibraryIDs: Set<String> = []
        let uniqueLibraries = libraries.filter { seenLibraryIDs.insert($0.id).inserted }
        entries.append(contentsOf: uniqueLibraries.prefix(8).map { library in
            let title = "Recently Added \(library.title)"
            let itemTypes = MediaBrowserHomeProvider.latestItemTypes(for: library)
            return Entry(
                key: .latest(libraryID: library.id),
                title: title,
                request: .latest(parentID: library.id, itemTypes: itemTypes, limit: 20),
                destination: RailViewAllDestination(
                    title: title,
                    backend: backend,
                    sessionIdentity: sessionIdentity,
                    query: .mediaBrowserRecentlyAdded(parentID: library.id,
                                                       itemTypes: itemTypes)
                )
            )
        })

        self.entries = entries
    }
}

/// Identity for one Home rail execution. The opaque authenticated authority prevents work from a
/// retired login/server lane from publishing, while the generation distinguishes two attempts on
/// the same authority (for example a force refresh overtaking an earlier load).
struct MediaBrowserHomeRailAttempt: Hashable, Sendable {
    let authority: BrowseSessionAuthority
    private let generation = UUID()
}

/// Per-key state retained by the reducer. An empty successful response remains observably
/// different from a failed request, which is required for degraded-load and future retry policy.
enum MediaBrowserHomeRailResolution {
    case pending
    case success([MediaItem])
    case failure
}

/// Current reduction snapshot. Completeness and failures are intentionally independent: pending
/// work is not a failed rail, but only a complete result with no failures is authoritative enough
/// for a view to pin as loaded.
struct MediaBrowserHomeRailLoad {
    let attempt: MediaBrowserHomeRailAttempt
    let rails: [MediaBrowserHomeRail]
    let pendingKeys: [MediaBrowserHomeRailPlan.Key]
    let failedKeys: [MediaBrowserHomeRailPlan.Key]
    /// True only before the provider has consumed its one automatic failed-key retry. A complete
    /// degraded initial pass is therefore not yet a terminal empty result.
    let hasFailedKeyRetryRemaining: Bool

    var isComplete: Bool { pendingKeys.isEmpty }
    var isDegraded: Bool { !failedKeys.isEmpty }
    var isTerminal: Bool {
        isComplete && (!isDegraded || !hasFailedKeyRetryRemaining)
    }
    var isAuthoritative: Bool { isComplete && !isDegraded }
}

/// Order-independent completion reducer for a `MediaBrowserHomeRailPlan`.
///
/// Completions may be recorded in any order; output always follows the plan's canonical order.
/// Empty successful rails are omitted without degrading the load, while failures are omitted and
/// mark it degraded, preserving the prior final-result semantics across progressive snapshots.
struct MediaBrowserHomeRailReducer {
    let plan: MediaBrowserHomeRailPlan
    private(set) var attempt: MediaBrowserHomeRailAttempt
    private var resolutions: [MediaBrowserHomeRailPlan.Key: MediaBrowserHomeRailResolution] = [:]
    private var hasFailedKeyRetryRemaining = true

    init(plan: MediaBrowserHomeRailPlan, attempt: MediaBrowserHomeRailAttempt) {
        self.plan = plan
        self.attempt = attempt
    }

    func resolution(for key: MediaBrowserHomeRailPlan.Key) -> MediaBrowserHomeRailResolution {
        resolutions[key] ?? .pending
    }

    @discardableResult
    mutating func record(_ result: Result<[MediaItem], Error>,
                         for key: MediaBrowserHomeRailPlan.Key,
                         attempt candidate: MediaBrowserHomeRailAttempt) -> Bool {
        guard candidate == attempt,
              plan.entries.contains(where: { $0.key == key }) else { return false }
        switch result {
        case .success(let items):
            resolutions[key] = .success(items)
        case .failure:
            resolutions[key] = .failure
        }
        return true
    }

    /// Start one new generation for only the currently failed keys. Successful and empty-success
    /// resolutions remain intact; failed keys become pending until their retry resolves. Reusing
    /// another authority is rejected so a retry can never bridge authenticated browse lanes.
    mutating func beginFailedKeyRetry(
        attempt candidate: MediaBrowserHomeRailAttempt
    ) -> [MediaBrowserHomeRailPlan.Key] {
        guard candidate.authority == attempt.authority,
              candidate != attempt else { return [] }
        let currentLoad = load
        guard hasFailedKeyRetryRemaining,
              currentLoad.isComplete else { return [] }
        let failedKeys = currentLoad.failedKeys
        guard !failedKeys.isEmpty else { return [] }
        attempt = candidate
        hasFailedKeyRetryRemaining = false
        for key in failedKeys {
            resolutions.removeValue(forKey: key)
        }
        return failedKeys
    }

    var load: MediaBrowserHomeRailLoad {
        var pendingKeys: [MediaBrowserHomeRailPlan.Key] = []
        var failedKeys: [MediaBrowserHomeRailPlan.Key] = []
        let rails = plan.entries.compactMap { entry -> MediaBrowserHomeRail? in
            switch resolution(for: entry.key) {
            case .pending:
                pendingKeys.append(entry.key)
                return nil
            case .failure:
                failedKeys.append(entry.key)
                return nil
            case .success(let items):
                guard !items.isEmpty else { return nil }
                return MediaBrowserHomeRail(id: entry.key.stableID,
                                            title: entry.title,
                                            items: items,
                                            destination: entry.destination)
            }
        }
        return MediaBrowserHomeRailLoad(attempt: attempt,
                                        rails: rails,
                                        pendingKeys: pendingKeys,
                                        failedKeys: failedKeys,
                                        hasFailedKeyRetryRemaining: hasFailedKeyRetryRemaining)
    }
}
