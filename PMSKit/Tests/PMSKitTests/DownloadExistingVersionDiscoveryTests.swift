import Testing
@testable import PMSKit

/// B68: the Emby existing-version refresh-and-poll belongs to the single-item sheet. Season
/// planning fetches once per episode, with no server refresh and no sleep.
@Suite("Download existing-version discovery")
struct DownloadExistingVersionDiscoveryTests {
    @MainActor
    private final class Probe {
        var fetches = 0
        var refreshes = 0
        var sleeps = 0
        var results: [[Int]]

        init(results: [[Int]]) { self.results = results }

        func fetch() -> [Int] {
            fetches += 1
            return results.isEmpty ? [] : results.removeFirst()
        }
    }

    @Test("Fetch-once returns the first fetch without refreshing or sleeping")
    @MainActor
    func fetchOnceNeverRefreshes() async throws {
        let probe = Probe(results: [[], [7]])
        let versions = try await DownloadExistingVersionDiscovery.discover(
            mode: .fetchOnce,
            fetch: { probe.fetch() },
            refresh: { probe.refreshes += 1 },
            sleep: { _ in probe.sleeps += 1 })
        #expect(versions.isEmpty)
        #expect(probe.fetches == 1)
        #expect(probe.refreshes == 0)
        #expect(probe.sleeps == 0)
    }

    @Test("Refresh-and-poll refreshes once and polls twice when nothing is visible")
    @MainActor
    func refreshAndPollWhenEmpty() async throws {
        let probe = Probe(results: [[], [], [5]])
        let versions = try await DownloadExistingVersionDiscovery.discover(
            mode: .refreshAndPoll,
            fetch: { probe.fetch() },
            refresh: { probe.refreshes += 1 },
            sleep: { _ in probe.sleeps += 1 })
        #expect(versions == [5])
        #expect(probe.fetches == 3)
        #expect(probe.refreshes == 1)
        #expect(probe.sleeps == 1)
    }

    @Test("Refresh-and-poll skips the refresh when versions are already visible")
    @MainActor
    func refreshAndPollShortCircuits() async throws {
        let probe = Probe(results: [[3]])
        let versions = try await DownloadExistingVersionDiscovery.discover(
            mode: .refreshAndPoll,
            fetch: { probe.fetch() },
            refresh: { probe.refreshes += 1 },
            sleep: { _ in probe.sleeps += 1 })
        #expect(versions == [3])
        #expect(probe.fetches == 1)
        #expect(probe.refreshes == 0)
    }
}
