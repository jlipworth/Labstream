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
/// item grid (`GET /library/sections/{key}/all`) and the TV `/children` traversal are built by
/// `PlexBrowseRequest` and sent through a bare `URLSession.shared.data(for:)` — the exact PMSKit
/// builder + transport boundary used by the app's browse layer.
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

    /// `GET /library/sections` — the same authoritative PMSKit builder that the app's forwarding
    /// `BrowseAPI` facade uses.
    private func sectionsRequest(_ cfg: Config) -> PlexRequest {
        PlexBrowseRequest.sections(server: cfg.server,
                                   token: cfg.token,
                                   identity: cfg.identity)
    }

    /// `GET /library/sections/{key}/all` — a section's item grid, paged with the same
    /// `X-Plex-Container-Start/-Size` query items the app's grid uses. Decoded with
    /// `MetadataResponse`.
    private func sectionGridRequest(_ cfg: Config, start: Int, size: Int) -> PlexRequest {
        PlexBrowseRequest.sectionItems(server: cfg.server,
                                       token: cfg.token,
                                       identity: cfg.identity,
                                       sectionKey: cfg.sectionKey,
                                       containerStart: start,
                                       containerSize: size)
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

    private func fetchDecodable<T: Decodable>(_ label: String,
                                               _ request: PlexRequest,
                                               as type: T.Type) async throws -> T? {
        let (data, status) = try await send(request)
        print(">>> BROWSE [\(label)] HTTP \(status), \(data.count) bytes")
        guard status == 200 else { return nil }
        guard let decoded = try? JSONDecoder().decode(type, from: data) else {
            print(">>> BROWSE [\(label)] HTTP 200 but the expected response shape did not decode.")
            return nil
        }
        return decoded
    }

    @Test func livePlexBrowseProbe() async throws {
        guard let cfg = Config() else {
            print(">>> BROWSE VERDICT: SKIP — set PLEX_LIVE_SERVER / PLEX_LIVE_TOKEN / PLEX_LIVE_SECTION_KEY / PLEX_LIVE_SHOW_METADATA_KEY to run.")
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
            let configuredSectionPresent = sections.contains { $0.key == cfg.sectionKey }
            let hasSections = !sections.isEmpty
            print(">>> BROWSE [sections] decoded \(sections.count) section(s); types=\(Set(sections.map(\.type)).sorted()) configuredSectionPresent=\(configuredSectionPresent)")
            #expect(hasSections, "library should expose at least one section")
            #expect(configuredSectionPresent, "configured section key was not in the live sections list")
            guard hasSections, configuredSectionPresent else {
                throw URLError(.resourceUnavailable)
            }
        }

        // (b) Section item grid (first page). Proves MetadataResponse parses a real listing and that
        //     paging headers are honored. Log ids/types/counts only.
        guard let grid = try await fetchMetadata("grid", sectionGridRequest(cfg, start: 0, size: 20)) else {
            Issue.record("section grid leg failed — cannot validate the item grid.")
            return
        }
        let gridItems = grid.metadata
        print(">>> BROWSE [grid] decoded \(gridItems.count) item(s) (page size 20); totalSize=\(grid.totalSize.map(String.init) ?? "nil") types=\(Set(gridItems.map(\.type)).sorted())")
        let hasGridItems = !gridItems.isEmpty
        let allGridItemsHaveIDs = gridItems.allSatisfy { !$0.ratingKey.isEmpty }
        #expect(hasGridItems, "section grid should return items")
        #expect(allGridItemsHaveIDs, "every grid item should carry a ratingKey")
        guard hasGridItems, allGridItemsHaveIDs else {
            throw URLError(.cannotDecodeContentData)
        }

        // (c) Every other pure builder moved in 4C is read-only and safe to exercise live.
        // Keep logs shape-only: counts and types, never titles, ids, paths, hosts, or tokens.
        guard let characters = try await fetchDecodable(
            "firstCharacters",
            PlexBrowseRequest.firstCharacters(server: cfg.server,
                                              token: cfg.token,
                                              identity: cfg.identity,
                                              sectionKey: cfg.sectionKey),
            as: LiveFirstCharacterResponse.self
        ) else {
            Issue.record("authoritative firstCharacters builder did not return a decodable 200")
            return
        }
        print(">>> BROWSE [firstCharacters] decoded \(characters.mediaContainer.directory.count) bucket(s)")

        guard let hubs = try await fetchDecodable(
            "hubs",
            PlexBrowseRequest.hubs(server: cfg.server, token: cfg.token, identity: cfg.identity),
            as: HubsResponse.self
        ) else {
            Issue.record("authoritative hubs builder did not return a decodable 200")
            return
        }
        print(">>> BROWSE [hubs] decoded \(hubs.mediaContainer.hub.count) hub(s)")

        guard let onDeck = try await fetchMetadata(
            "onDeck",
            PlexBrowseRequest.onDeck(server: cfg.server, token: cfg.token, identity: cfg.identity)
        ) else {
            Issue.record("authoritative onDeck builder did not return a decodable 200")
            return
        }
        print(">>> BROWSE [onDeck] decoded \(onDeck.metadata.count) item(s)")

        guard let search = try await fetchDecodable(
            "search",
            PlexBrowseRequest.search(server: cfg.server,
                                     token: cfg.token,
                                     identity: cfg.identity,
                                     query: "LabstreamLiveProbeNoMatch"),
            as: HubsResponse.self
        ) else {
            Issue.record("authoritative search builder did not return a decodable 200")
            return
        }
        print(">>> BROWSE [search] decoded \(search.mediaContainer.hub.count) hub(s)")

        guard let metadata = try await fetchMetadata(
            "metadata",
            PlexBrowseRequest.metadata(server: cfg.server,
                                       token: cfg.token,
                                       identity: cfg.identity,
                                       ratingKey: cfg.showRatingKey)
        ) else {
            Issue.record("authoritative metadata builder did not return a decodable 200")
            return
        }
        let configuredMetadataPresent = metadata.metadata.contains { $0.ratingKey == cfg.showRatingKey }
        #expect(configuredMetadataPresent, "metadata response did not contain the configured show")
        guard configuredMetadataPresent else { throw URLError(.cannotParseResponse) }
        print(">>> BROWSE [metadata] decoded \(metadata.metadata.count) item(s); configuredItemPresent=true")

        // (d) TV hierarchy: show → seasons → episodes, via the authoritative children builder.
        //     Asserts parent/grandparent ids chain back coherently.
        let showReq = PlexBrowseRequest.children(server: cfg.server, token: cfg.token,
                                                 identity: cfg.identity, ratingKey: cfg.showRatingKey)
        guard let seasonContainer = try await fetchMetadata("seasons", showReq) else {
            Issue.record("show children leg failed — cannot traverse the TV hierarchy.")
            return
        }
        let seasons = seasonContainer.metadata
        print(">>> BROWSE [seasons] decoded \(seasons.count) child(ren); types=\(Set(seasons.map(\.type)).sorted())")
        let hasSeasons = !seasons.isEmpty
        #expect(hasSeasons, "show should have at least one season")
        guard hasSeasons else { throw URLError(.resourceUnavailable) }

        // Pick the first real season (skip non-season rows like "All episodes" specials if any).
        guard let season = seasons.first(where: { $0.type == "season" }) ?? seasons.first else {
            print(">>> BROWSE [seasons] VERDICT: no usable season row to traverse."); return
        }
        // The season's grandparent (its show) must point back at the show we queried.
        if let gp = season.grandparentRatingKey {
            let grandparentMatchesShow = gp == cfg.showRatingKey
            print(">>> BROWSE [seasons] season id=<set> grandparentMatchesShow=\(grandparentMatchesShow)")
            #expect(grandparentMatchesShow, "season grandparent should equal the queried show")
            guard grandparentMatchesShow else { throw URLError(.cannotParseResponse) }
        } else {
            print(">>> BROWSE [seasons] season id=<set> has no grandparentRatingKey (PMS omitted it on season rows).")
        }

        let episodeReq = PlexBrowseRequest.children(server: cfg.server, token: cfg.token,
                                                    identity: cfg.identity, ratingKey: season.ratingKey)
        guard let episodeContainer = try await fetchMetadata("episodes", episodeReq) else {
            Issue.record("season children leg failed — cannot validate episodes.")
            return
        }
        let episodes = episodeContainer.metadata
        let realEpisodes = episodes.filter { $0.type == "episode" }
        print(">>> BROWSE [episodes] decoded \(episodes.count) child(ren), \(realEpisodes.count) episode(s); indices=\(realEpisodes.compactMap(\.index).prefix(8).map(String.init))")
        let hasEpisodes = !realEpisodes.isEmpty
        #expect(hasEpisodes, "season should contain episodes")
        guard hasEpisodes else { throw URLError(.resourceUnavailable) }

        // Each episode must chain back: parentRatingKey == season, grandparentRatingKey == show.
        if let ep = realEpisodes.first {
            print(">>> BROWSE [episodes] first episode id=<set> parent=<\(ep.parentRatingKey == nil ? "nil" : "set")> grandparent=<\(ep.grandparentRatingKey == nil ? "nil" : "set")> index=\(ep.index.map(String.init) ?? "nil")")
            if let parent = ep.parentRatingKey {
                let parentMatchesSeason = parent == season.ratingKey
                #expect(parentMatchesSeason, "episode parent should equal its season")
                guard parentMatchesSeason else { throw URLError(.cannotParseResponse) }
            }
            if let grand = ep.grandparentRatingKey {
                let grandparentMatchesShow = grand == cfg.showRatingKey
                #expect(grandparentMatchesShow, "episode grandparent should equal the queried show")
                guard grandparentMatchesShow else { throw URLError(.cannotParseResponse) }
            }
        }
        print(">>> BROWSE VERDICT: PASS — all eight authoritative PlexBrowseRequest builder lanes returned decodable live responses.")
    }
}

/// Probe-local shape for `/firstCharacter`. The shipping decoder remains app-private; this live
/// proof only needs to establish that the moved PMSKit builder reaches a decodable endpoint.
private struct LiveFirstCharacterResponse: Decodable {
    let mediaContainer: Container
    enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }

    struct Container: Decodable {
        let directory: [Entry]
        enum CodingKeys: String, CodingKey { case directory = "Directory" }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            directory = try container.decodeIfPresent([Entry].self, forKey: .directory) ?? []
        }
    }

    struct Entry: Decodable {}
}
