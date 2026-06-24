import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PMSKit

/// Headless browse + TV-hierarchy probe against a REAL Plex Media Server (issue #75 — the Plex
/// counterpart to `LiveEmbyProbe`, which proves Emby browse + DTO mapping). This hits the network,
/// so it is OPT-IN: it runs only when the required env vars are present and otherwise returns
/// immediately, leaving plain `swift test` and CI hermetic. NOTHING here is hardcoded — server,
/// token, section key and show key all arrive via the environment, so no secret is ever committed.
///
/// Why this faithfully reproduces the app: the sections list (`GET /library/sections`), a section's
/// item grid (`GET /library/sections/{key}/all`) and the TV `/children` traversal are sent through
/// a bare `URLSession.shared.data(for:)` with `PlexHeaders.standard` — the exact wire shape the
/// app's browse layer produces. The `/children` request uses the real `ChildrenRequest` builder.
/// Decoding the live bodies here proves the PMSKit decoders (`SectionsResponse`, `MetadataResponse`)
/// match the live wire, and the hierarchy assertions prove ids/types are coherent (a season's
/// `grandparentRatingKey` chains back to its show; an episode's `parentRatingKey`/
/// `grandparentRatingKey` chain back to its season/show) — the specific wire-shape invariant that
/// a mock can't prove because it depends on the live server's actual hierarchy linkage.
///
/// PROOF DISCIPLINE: every decode is lenient (`try?` → nil → skip with a diagnostic) so a 200 with
/// an unexpected body is a clear SKIP, never a false RED; any leg that can't establish its
/// precondition records/skips loudly rather than passing trivially.
///
/// Run it (creds live in a gitignored env file — see scripts/plex-live.env.example):
///   ./scripts/live-plex-browse-probe.sh
/// or directly:
///   set -a; source scripts/plex-live.env; set +a
///   cd PMSKit && swift test --filter LivePlexBrowseProbe
///
/// SECURITY: never prints the token or the live scheme/host (see `LiveProbeConfig.redact`); logs
/// item ids/types/counts only — never media titles, library names, or paths. The repo goes public.
///
/// Inputs (env):
///   PLEX_LIVE_SERVER / PLEX_LIVE_TOKEN          (required, shared with the decision probe)
///   PLEX_LIVE_SECTION_KEY                        (required — a library section key, e.g. "1")
///   PLEX_LIVE_SHOW_METADATA_KEY                  (required — a TV show item key, bare ratingKey
///                                                or "/library/metadata/<id>"; the probe extracts
///                                                the bare ratingKey for the /children traversal)
struct LivePlexBrowseProbeTests {

    private struct Config {
        let base: LiveProbeConfig
        let sectionKey: String
        let showRatingKey: String

        var server: URL { base.server }
        var token: String { base.token }
        var identity: ClientIdentity { base.identity }

        init?() {
            guard let base = LiveProbeConfig() else { return nil }
            let env = ProcessInfo.processInfo.environment
            guard let sectionKey = env["PLEX_LIVE_SECTION_KEY"], !sectionKey.isEmpty,
                  let showKey = env["PLEX_LIVE_SHOW_METADATA_KEY"], !showKey.isEmpty
            else { return nil }
            self.base = base
            self.sectionKey = sectionKey
            // Accept either a bare ratingKey ("123") or a metadata path
            // ("/library/metadata/123"); ChildrenRequest wants the bare key.
            self.showRatingKey = showKey.split(separator: "/").last.map(String.init) ?? showKey
        }
    }

    private func send(_ req: PlexRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: req.urlRequest())
        return (data, (response as? HTTPURLResponse)?.statusCode ?? -1)
    }

    /// `GET /library/sections` — the same request the app's library picker loads. Built directly as
    /// a `PlexRequest` (PMSKit exposes no dedicated sections builder; the wire shape is a bare GET
    /// with the standard identity headers), decoded with the real `SectionsResponse`.
    private func sectionsRequest(_ cfg: Config) -> PlexRequest {
        PlexRequest(url: cfg.server.appendingPathComponent("/library/sections"),
                    method: "GET",
                    headers: PlexHeaders.standard(identity: cfg.identity, token: cfg.token))
    }

    /// `GET /library/sections/{key}/all` — a section's item grid, paged with the same
    /// `X-Plex-Container-Start/-Size` headers the app's grid uses. Decoded with `MetadataResponse`.
    private func sectionGridRequest(_ cfg: Config, start: Int, size: Int) -> PlexRequest {
        var headers = PlexHeaders.standard(identity: cfg.identity, token: cfg.token)
        headers["X-Plex-Container-Start"] = String(start)
        headers["X-Plex-Container-Size"] = String(size)
        return PlexRequest(url: cfg.server.appendingPathComponent("/library/sections/\(cfg.sectionKey)/all"),
                           method: "GET",
                           headers: headers)
    }

    /// Fetch `req`, require HTTP 200, and decode leniently. nil (with a diagnostic) on non-200 or an
    /// undecodable body — so a control leg never silently passes and a bad body is a SKIP, not RED.
    private func fetchMetadata(_ label: String, _ req: PlexRequest) async throws -> MetadataResponse.Container? {
        let (data, status) = try await send(req)
        print(">>> BROWSE [\(label)] HTTP \(status), \(data.count) bytes")
        guard status == 200 else { return nil }
        guard let decoded = try? JSONDecoder().decode(MetadataResponse.self, from: data) else {
            print(">>> BROWSE [\(label)] HTTP 200 but body did not decode as MetadataResponse — skipping.")
            return nil
        }
        return decoded.mediaContainer
    }

    @Test func livePlexBrowseProbe() async throws {
        guard let cfg = Config() else {
            print(">>> BROWSE skipped: set PLEX_LIVE_SERVER / PLEX_LIVE_TOKEN / PLEX_LIVE_SECTION_KEY / PLEX_LIVE_SHOW_METADATA_KEY to run.")
            return
        }

        // (a) Library sections list. Proves SectionsResponse parses and the configured section
        //     actually exists. Log key + type only (never the library title — it can be a media name).
        do {
            let (data, status) = try await send(sectionsRequest(cfg))
            print(">>> BROWSE [sections] HTTP \(status), \(data.count) bytes")
            #expect(status == 200, "sections expected HTTP 200, got \(status)")
            guard status == 200, let decoded = try? JSONDecoder().decode(SectionsResponse.self, from: data) else {
                Issue.record("sections leg failed — HTTP \(status) or body did not decode as SectionsResponse; cannot validate browse.")
                return
            }
            let sections = decoded.mediaContainer.directory
            print(">>> BROWSE [sections] decoded \(sections.count) section(s); keys=\(sections.map(\.key)) types=\(Set(sections.map(\.type)).sorted())")
            #expect(!sections.isEmpty, "library should expose at least one section")
            #expect(sections.contains { $0.key == cfg.sectionKey },
                    "PLEX_LIVE_SECTION_KEY=\(cfg.sectionKey) was not in the live sections list")
        }

        // (b) Section item grid (first page). Proves MetadataResponse parses a real listing and that
        //     paging headers are honored. Log ids/types/counts only.
        guard let grid = try await fetchMetadata("grid", sectionGridRequest(cfg, start: 0, size: 20)) else {
            Issue.record("section grid leg failed — cannot validate the item grid.")
            return
        }
        let gridItems = grid.metadata
        print(">>> BROWSE [grid] decoded \(gridItems.count) item(s) (page size 20); totalSize=\(grid.totalSize.map(String.init) ?? "nil") types=\(Set(gridItems.map(\.type)).sorted())")
        #expect(!gridItems.isEmpty, "section grid should return items")
        #expect(gridItems.allSatisfy { !$0.ratingKey.isEmpty }, "every grid item should carry a ratingKey")

        // (c) TV hierarchy: show → seasons → episodes, via the REAL ChildrenRequest builder.
        //     Asserts parent/grandparent ids chain back coherently.
        let showReq = ChildrenRequest.children(server: cfg.server, token: cfg.token,
                                               identity: cfg.identity, ratingKey: cfg.showRatingKey)
        guard let seasonContainer = try await fetchMetadata("seasons", showReq) else {
            Issue.record("show children leg failed — cannot traverse the TV hierarchy.")
            return
        }
        let seasons = seasonContainer.metadata
        print(">>> BROWSE [seasons] decoded \(seasons.count) child(ren); types=\(Set(seasons.map(\.type)).sorted())")
        #expect(!seasons.isEmpty, "show should have at least one season")

        // Pick the first real season (skip non-season rows like "All episodes" specials if any).
        guard let season = seasons.first(where: { $0.type == "season" }) ?? seasons.first else {
            print(">>> BROWSE [seasons] VERDICT: no usable season row to traverse."); return
        }
        // The season's grandparent (its show) must point back at the show we queried.
        if let gp = season.grandparentRatingKey {
            print(">>> BROWSE [seasons] season ratingKey=\(season.ratingKey) grandparentRatingKey=\(gp) (show=\(cfg.showRatingKey))")
            #expect(gp == cfg.showRatingKey,
                    "season.grandparentRatingKey (\(gp)) should equal the queried show (\(cfg.showRatingKey))")
        } else {
            print(">>> BROWSE [seasons] season ratingKey=\(season.ratingKey) has no grandparentRatingKey (PMS omitted it on season rows).")
        }

        let episodeReq = ChildrenRequest.children(server: cfg.server, token: cfg.token,
                                                  identity: cfg.identity, ratingKey: season.ratingKey)
        guard let episodeContainer = try await fetchMetadata("episodes", episodeReq) else {
            Issue.record("season children leg failed — cannot validate episodes.")
            return
        }
        let episodes = episodeContainer.metadata
        let realEpisodes = episodes.filter { $0.type == "episode" }
        print(">>> BROWSE [episodes] decoded \(episodes.count) child(ren), \(realEpisodes.count) episode(s); indices=\(realEpisodes.compactMap(\.index).prefix(8).map(String.init))")
        #expect(!realEpisodes.isEmpty, "season should contain episodes")

        // Each episode must chain back: parentRatingKey == season, grandparentRatingKey == show.
        if let ep = realEpisodes.first {
            print(">>> BROWSE [episodes] first episode ratingKey=\(ep.ratingKey) parent=\(ep.parentRatingKey ?? "nil") grandparent=\(ep.grandparentRatingKey ?? "nil") index=\(ep.index.map(String.init) ?? "nil")")
            if let parent = ep.parentRatingKey {
                #expect(parent == season.ratingKey,
                        "episode.parentRatingKey (\(parent)) should equal its season (\(season.ratingKey))")
            }
            if let grand = ep.grandparentRatingKey {
                #expect(grand == cfg.showRatingKey,
                        "episode.grandparentRatingKey (\(grand)) should equal the show (\(cfg.showRatingKey))")
            }
        }
        print(">>> BROWSE VERDICT: OK — sections + grid + TV hierarchy (show→season→episode) all decode and chain coherently against the live server.")
    }
}
