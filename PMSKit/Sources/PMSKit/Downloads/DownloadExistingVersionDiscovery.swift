import Foundation

/// How the download planner discovers server-prepared (existing) versions of an item.
public enum DownloadExistingVersionDiscoveryMode: Sendable, Equatable {
    /// Single-item sheet (#126/#133): fetch; if nothing is visible, ask the server to refresh the
    /// item, then poll twice with one short wait between polls.
    case refreshAndPoll
    /// Season planner (B68): fetch exactly once. Running the refresh plus wait for every episode
    /// made a 22-episode season take minutes and fired one server refresh per episode.
    case fetchOnce
}

/// Pure sequencing of existing-version discovery. The caller supplies the backend requests.
public enum DownloadExistingVersionDiscovery {
    public static let pollDelay: Duration = .seconds(5)

    public static func discover<Version>(
        mode: DownloadExistingVersionDiscoveryMode,
        isolation: isolated (any Actor)? = #isolation,
        fetch: () async throws -> [Version],
        refresh: () async throws -> Void,
        sleep: (Duration) async -> Void
    ) async throws -> [Version] {
        let initial = try await fetch()
        guard initial.isEmpty, mode == .refreshAndPoll else { return initial }
        try await refresh()
        for attempt in 0..<2 {
            let versions = try await fetch()
            if !versions.isEmpty { return versions }
            if attempt == 0 { await sleep(pollDelay) }
        }
        return []
    }
}
