import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PMSKit

/// Headless probe for the Plex watched-only browse filter (issue #200) against a REAL PMS.
/// `LibraryBrowseFilter.watched` emits the negated boolean `unwatched!=1` (query item name
/// "unwatched!", value "1") because `unwatched=0` is not a facet PMS reliably honors. This
/// probe proves the negated form on the live wire and measures what the legacy `unwatched=0`
/// control actually does, using the REAL `PlexLibraryBrowseRequest.sectionItems` builder —
/// the exact request the app's grid sends.
///
/// OPT-IN: runs only when `PLEX_LIVE_SERVER` / `PLEX_LIVE_TOKEN` are present, otherwise
/// returns immediately so plain `swift test` and CI stay hermetic. The movie section is
/// discovered from `/library/sections`, so no extra env var is needed.
///
/// PROOF DISCIPLINE: legs that cannot establish their precondition (no movie section, or a
/// section without BOTH watched and unwatched items — where the filters are indistinguishable)
/// SKIP loudly rather than pass trivially. Logs counts/keys only — never titles or the host
/// (see `LiveProbeConfig.redact`).
///
/// Run:
///   set -a; source scripts/plex-live.env; set +a
///   cd PMSKit && swift test --filter LiveWatchedFilterProbe
struct LiveWatchedFilterProbeTests {

    private func send(_ req: PlexRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: req.urlRequest())
        return (data, (response as? HTTPURLResponse)?.statusCode ?? -1)
    }

    /// Fetch one section page via the real browse builder; nil (with a diagnostic) on non-200
    /// or an undecodable body so a bad leg is a SKIP, never a silent pass.
    private func fetchPage(_ label: String,
                           cfg: LiveProbeConfig,
                           sectionKey: String,
                           browseQuery: LibraryBrowseQuery = .default,
                           extraQueryItems: [URLQueryItem] = []) async throws -> MetadataResponse.Container? {
        let req = PlexLibraryBrowseRequest.sectionItems(server: cfg.server,
                                                        token: cfg.token,
                                                        identity: cfg.identity,
                                                        sectionKey: sectionKey,
                                                        containerStart: 0,
                                                        containerSize: 50,
                                                        browseQuery: browseQuery,
                                                        extraQueryItems: extraQueryItems)
        let (data, status) = try await send(req)
        print(">>> WATCHED [\(label)] HTTP \(status), \(data.count) bytes")
        guard status == 200 else { return nil }
        guard let decoded = try? JSONDecoder().decode(MetadataResponse.self, from: data) else {
            print(">>> WATCHED [\(label)] HTTP 200 but body did not decode as MetadataResponse — skipping.")
            return nil
        }
        return decoded.mediaContainer
    }

    private func total(_ container: MetadataResponse.Container) -> Int {
        container.totalSize ?? container.metadata.count
    }

    @Test func liveWatchedFilterProbe() async throws {
        guard let cfg = LiveProbeConfig(deviceName: "Labstream Watched Probe") else {
            print(">>> WATCHED skipped: set PLEX_LIVE_SERVER / PLEX_LIVE_TOKEN to run.")
            return
        }

        // Discover a movie section (the filter is a video-grid facet; movies give the cleanest
        // per-item viewCount semantics — show rows aggregate leaf counts).
        let sectionsReq = PlexRequest(url: cfg.server.appendingPathComponent("/library/sections"),
                                      method: "GET",
                                      headers: PlexHeaders.standard(identity: cfg.identity, token: cfg.token))
        let (sectionsData, sectionsStatus) = try await send(sectionsReq)
        print(">>> WATCHED [sections] HTTP \(sectionsStatus), \(sectionsData.count) bytes")
        guard sectionsStatus == 200,
              let sections = try? JSONDecoder().decode(SectionsResponse.self, from: sectionsData)
        else {
            Issue.record("sections leg failed — HTTP \(sectionsStatus) or undecodable body; cannot locate a movie section.")
            return
        }
        guard let movieSection = sections.mediaContainer.directory.first(where: { $0.type == "movie" }) else {
            print(">>> WATCHED VERDICT: SKIP — no movie section on this server; cannot exercise the watched facet.")
            return
        }
        let key = movieSection.key
        print(">>> WATCHED using movie section key=\(key)")

        // Leg A: baseline (no filter) and Leg B: unwatched=1 — establish the precondition that
        // the section actually contains both watched and unwatched items.
        guard let baseline = try await fetchPage("baseline", cfg: cfg, sectionKey: key),
              let unwatched = try await fetchPage("unwatched=1", cfg: cfg, sectionKey: key,
                                                  browseQuery: .init(filter: .unwatched))
        else {
            Issue.record("baseline/unwatched legs failed — cannot establish the discrimination precondition.")
            return
        }
        let totalAll = total(baseline), totalUnwatched = total(unwatched)
        let expectedWatched = totalAll - totalUnwatched
        print(">>> WATCHED [counts] all=\(totalAll) unwatched=\(totalUnwatched) → expected watched=\(expectedWatched)")
        guard totalAll > 0, totalUnwatched > 0, expectedWatched > 0 else {
            print(">>> WATCHED VERDICT: SKIP — section lacks both watched and unwatched items; the filter forms are indistinguishable here.")
            return
        }

        // Leg C: the SHIPPING form — LibraryBrowseFilter.watched → `unwatched!=1` via the real
        // builder and encoder. Must return only watched items and the complementary total.
        guard let watched = try await fetchPage("unwatched!=1 (shipping)", cfg: cfg, sectionKey: key,
                                                browseQuery: .init(filter: .watched)) else {
            Issue.record("watched (unwatched!=1) leg failed — HTTP error or undecodable body.")
            return
        }
        let totalWatched = total(watched)
        let pageViewCounts = watched.metadata.map { $0.viewCount ?? 0 }
        let unwatchedOnPage = pageViewCounts.filter { $0 < 1 }.count
        print(">>> WATCHED [unwatched!=1] total=\(totalWatched) pageItems=\(watched.metadata.count) unwatchedOnPage=\(unwatchedOnPage)")
        #expect(totalWatched == expectedWatched,
                "unwatched!=1 total (\(totalWatched)) should equal all−unwatched (\(expectedWatched))")
        #expect(unwatchedOnPage == 0,
                "unwatched!=1 page should contain only watched items; found \(unwatchedOnPage) with viewCount<1")

        // Leg D: the LEGACY control `unwatched=0` (what the code emitted before the fix), sent
        // as a raw extra item. Diagnostic only — records what PMS actually does with it.
        if let legacy = try await fetchPage("unwatched=0 (legacy control)", cfg: cfg, sectionKey: key,
                                            extraQueryItems: [URLQueryItem(name: "unwatched", value: "0")]) {
            let totalLegacy = total(legacy)
            let verdict: String
            if totalLegacy == totalAll { verdict = "IGNORED by PMS (returns the full section — the original bug)" }
            else if totalLegacy == expectedWatched { verdict = "honored as watched-only on this PMS version" }
            else { verdict = "neither full nor watched-only (unexpected: \(totalLegacy))" }
            print(">>> WATCHED [unwatched=0] total=\(totalLegacy) → \(verdict)")
        }

        print(">>> WATCHED VERDICT: OK — unwatched!=1 returned \(totalWatched)/\(expectedWatched) expected watched items, page purity confirmed.")
    }
}
