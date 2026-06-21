import Foundation

/// Records, across a Home-rails fetch, whether any individual rail request *failed*
/// (threw) as opposed to legitimately returning no items.
///
/// Background (#93): the Jellyfin/Emby Home builders fetch each rail — Continue
/// Watching, Next Up, and one "Recently Added <library>" per view — independently and
/// swallow per-rail errors with `try?`. A run where, say, Continue Watching succeeds but
/// every "Recently Added" request 401s during a re-auth window yields a *partial* Home
/// that looks fully loaded. Worse, the view used to cache that partial result as the
/// authoritative `.loaded` state, so navigating away and back would not re-fetch.
///
/// This tracker lets the loader distinguish "the server genuinely has no Continue
/// Watching items" (empty, not degraded) from "the Continue Watching request errored"
/// (degraded). The view consults `isDegraded` to decide whether to pin the loaded
/// identity: a degraded load is shown but NOT pinned, so pop-back / a later `.task`
/// re-fires the fetch and can recover the missing rails without a manual pull-to-refresh.
public struct HomeRailsLoadTracker: Sendable {
    /// True once any rail request has thrown. Empty (but successful) rails do not set it.
    public private(set) var isDegraded: Bool = false

    public init() {}

    /// Run `operation` and unwrap its result, recording a failure if it threw.
    /// Returns the produced value on success, or `nil` if the operation threw —
    /// matching the old `try?` behaviour while also marking the load degraded.
    ///
    /// The `isolation` parameter (defaulting to the caller's actor) lets a `@MainActor`
    /// browse service pass a main-actor-isolated closure without a Sendable violation.
    public mutating func attempt<T>(isolation: isolated (any Actor)? = #isolation,
                                    _ operation: () async throws -> T) async -> T? {
        do {
            return try await operation()
        } catch {
            isDegraded = true
            return nil
        }
    }

    /// Wrap an async throwing operation in a `Result` so it can be launched as an
    /// `async let` (whose binding cannot itself be `do/catch`-ed) and folded back in with
    /// `record(_:)` once awaited. `Result`'s own initializer is synchronous-only, hence this.
    public static func resultOf<T>(isolation: isolated (any Actor)? = #isolation,
                                   _ operation: () async throws -> T) async -> Result<T, Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }

    /// Fold an already-resolved `Result` (e.g. from an `async let`) into the tracker,
    /// returning the success value or `nil`. A `.failure` marks the load degraded.
    public mutating func record<T>(_ result: Result<T, Error>) -> T? {
        switch result {
        case .success(let value):
            return value
        case .failure:
            isDegraded = true
            return nil
        }
    }
}

/// The outcome of a Home-rails fetch: the rails that loaded, plus whether the load was
/// degraded (one or more rail requests errored). Generic over the backend's rail type so
/// both Jellyfin and Emby share the same contract. Consumed on the main actor by the
/// Home view, so it does not require `Sendable` of the rail type.
public struct HomeRailsLoad<Rail> {
    public let rails: [Rail]
    public let isDegraded: Bool

    public init(rails: [Rail], isDegraded: Bool) {
        self.rails = rails
        self.isDegraded = isDegraded
    }
}
