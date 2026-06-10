import Foundation

/// Request builders for the music library (Plex `artist` sections).
///
/// PMS exposes flat music listings on the standard section-listing endpoint
/// `GET /library/sections/{sectionKey}/all`, filtered by the numeric item `type`:
/// `8` == artist, `9` == album, `10` == track. Artist→album and album→track
/// drill-down reuses `ChildrenRequest.children` (the same endpoint that walks
/// show→season→episode), so only the top-level listings live here.
///
/// Kept pure (no networking) so the URLs/params are unit-testable, mirroring the
/// other PlexKit builders (`ChildrenRequest`, `OptimizeRequest`, …).
public enum MusicRequest {

    /// List artists in a music section:
    /// `GET /library/sections/{sectionKey}/all?type=8[&sort=…]` with optional
    /// `X-Plex-Container-Start/Size` paging for the pivot grids. Defaults keep
    /// the original unfiltered, unpaged shape for existing call sites.
    public static func artists(server: URL,
                               token: String,
                               identity: ClientIdentity,
                               sectionKey: String,
                               sort: String? = nil,
                               containerStart: Int? = nil,
                               containerSize: Int? = nil) -> PlexRequest {
        sectionAll(server: server, token: token, identity: identity,
                   sectionKey: sectionKey, type: 8,
                   extraQueryItems: sortAndPaging(sort: sort,
                                                  containerStart: containerStart,
                                                  containerSize: containerSize))
    }

    /// List albums in a music section:
    /// `GET /library/sections/{sectionKey}/all?type=9[&sort=…]` with optional
    /// container paging, same shape as ``artists``.
    public static func albums(server: URL,
                              token: String,
                              identity: ClientIdentity,
                              sectionKey: String,
                              sort: String? = nil,
                              containerStart: Int? = nil,
                              containerSize: Int? = nil) -> PlexRequest {
        sectionAll(server: server, token: token, identity: identity,
                   sectionKey: sectionKey, type: 9,
                   extraQueryItems: sortAndPaging(sort: sort,
                                                  containerStart: containerStart,
                                                  containerSize: containerSize))
    }

    /// Section-scoped home hubs (Recently Played / Recently Added / …):
    /// `GET /hubs/sections/{sectionKey}?count=20&excludeFields=summary`.
    /// Decodes via the existing `HubsResponse`. Hub identifiers vary by PMS
    /// version, so callers must prefix-match `hubIdentifier`, never equal-match.
    public static func sectionHubs(server: URL,
                                   token: String,
                                   identity: ClientIdentity,
                                   sectionKey: String,
                                   count: Int = 20) -> PlexRequest {
        PlexRequest(url: server.appendingPathComponent("/hubs/sections/\(sectionKey)"),
                    method: "GET",
                    queryItems: [
                        .init(name: "count", value: String(count)),
                        .init(name: "excludeFields", value: "summary"),
                    ],
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// Play history for a section, newest first — the Recently-Played fallback
    /// when the section hubs don't carry (or don't advance) a played hub:
    /// `GET /status/sessions/history/all?sort=viewedAt:desc&librarySectionID={id}`.
    /// Paged: history grows unboundedly, a rail only needs the head.
    public static func playHistory(server: URL,
                                   token: String,
                                   identity: ClientIdentity,
                                   librarySectionID: String,
                                   count: Int = 20) -> PlexRequest {
        PlexRequest(url: server.appendingPathComponent("/status/sessions/history/all"),
                    method: "GET",
                    queryItems: [
                        .init(name: "sort", value: "viewedAt:desc"),
                        .init(name: "librarySectionID", value: librarySectionID),
                        .init(name: "X-Plex-Container-Start", value: "0"),
                        .init(name: "X-Plex-Container-Size", value: String(count)),
                    ],
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// One page of randomly-ordered tracks for Shuffle Library:
    /// `GET …/all?type=10&sort=random` with a single explicit container page.
    /// NEVER paged further — `sort=random` re-randomizes per request, so page 2
    /// would repeat/skip tracks. One request, queue it, done.
    public static func randomTracks(server: URL,
                                    token: String,
                                    identity: ClientIdentity,
                                    sectionKey: String,
                                    size: Int = 200) -> PlexRequest {
        sectionAll(server: server, token: token, identity: identity,
                   sectionKey: sectionKey, type: 10,
                   extraQueryItems: [
                       .init(name: "sort", value: "random"),
                       .init(name: "X-Plex-Container-Start", value: "0"),
                       .init(name: "X-Plex-Container-Size", value: String(size)),
                   ])
    }

    /// Every playable leaf under a container in one flat list — an artist's
    /// tracks across all albums (Play/Shuffle Artist):
    /// `GET /library/metadata/{ratingKey}/allLeaves`.
    public static func allLeaves(server: URL,
                                 token: String,
                                 identity: ClientIdentity,
                                 ratingKey: String) -> PlexRequest {
        PlexRequest(url: server.appendingPathComponent("/library/metadata/\(ratingKey)/allLeaves"),
                    method: "GET",
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// An artist's most-rated tracks (the "Popular" section), python-plexapi's
    /// query shape: `…/all?type=10&artist.id={rk}&group=title&ratingCount>>=0
    /// &sort=ratingCount:desc&limit={n}`. The `>>` (greater-than filter) lives
    /// in the query item NAME and URL-encodes to `ratingCount%3E%3E=0`.
    /// ⚠️ Provisional pending the Phase-0 live-PMS verification (MUSIC-DESIGN §8).
    public static func popularTracks(server: URL,
                                     token: String,
                                     identity: ClientIdentity,
                                     sectionKey: String,
                                     artistRatingKey: String,
                                     limit: Int = 5) -> PlexRequest {
        sectionAll(server: server, token: token, identity: identity,
                   sectionKey: sectionKey, type: 10,
                   extraQueryItems: [
                       .init(name: "artist.id", value: artistRatingKey),
                       .init(name: "group", value: "title"),
                       .init(name: "ratingCount>>", value: "0"),
                       .init(name: "sort", value: "ratingCount:desc"),
                       .init(name: "limit", value: String(limit)),
                   ])
    }

    /// List the 20 most recently added albums:
    /// `GET /library/sections/{sectionKey}/all?type=9&sort=addedAt:desc` with
    /// explicit container paging — without it PMS returns the ENTIRE album list
    /// for a "recently added" rail that only shows a handful.
    public static func recentlyAddedAlbums(server: URL,
                                           token: String,
                                           identity: ClientIdentity,
                                           sectionKey: String) -> PlexRequest {
        sectionAll(server: server, token: token, identity: identity,
                   sectionKey: sectionKey, type: 9,
                   extraQueryItems: [
                       .init(name: "sort", value: "addedAt:desc"),
                       .init(name: "X-Plex-Container-Start", value: "0"),
                       .init(name: "X-Plex-Container-Size", value: "20"),
                   ])
    }

    /// Build the direct-play stream URL for a track `Part`:
    /// `<server><partKey>?X-Plex-Token=<token>`.
    ///
    /// Token goes in the QUERY (streaming convention) since `AVPlayer`'s loader
    /// won't carry our API headers. Unlike `OptimizeRequest.downloadURL` this
    /// deliberately omits `download=1`: that flag forces an attachment
    /// content-disposition (save-to-disk semantics) and we want inline playback.
    /// No transcode decision is needed either — AVPlayer plays mp3/aac/alac/flac
    /// natively, so the original file streams as-is.
    public static func trackStreamURL(server: URL,
                                      token: String,
                                      partKey: String) -> URL {
        let partURL = server.appendingPathComponent(
            partKey.hasPrefix("/") ? String(partKey.dropFirst()) : partKey)
        guard var components = URLComponents(url: partURL, resolvingAgainstBaseURL: false) else {
            preconditionFailure("MusicRequest: part URL is not decomposable: \(partURL)")
        }
        components.queryItems = [
            .init(name: "X-Plex-Token", value: token),
        ]
        guard let url = components.url else {
            preconditionFailure("MusicRequest: could not rebuild stream URL for part \(partKey)")
        }
        return url
    }

    /// Shared `GET /library/sections/{sectionKey}/all` builder with a numeric
    /// `type` filter plus any extra query items.
    private static func sectionAll(server: URL,
                                   token: String,
                                   identity: ClientIdentity,
                                   sectionKey: String,
                                   type: Int,
                                   extraQueryItems: [URLQueryItem] = []) -> PlexRequest {
        let url = server.appendingPathComponent("/library/sections/\(sectionKey)/all")
        return PlexRequest(url: url,
                           method: "GET",
                           queryItems: [.init(name: "type", value: String(type))] + extraQueryItems,
                           headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// Optional `sort` + `X-Plex-Container-Start/Size` query items; start and
    /// size only emit together (a lone start or size is meaningless to PMS).
    private static func sortAndPaging(sort: String?,
                                      containerStart: Int?,
                                      containerSize: Int?) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let sort { items.append(.init(name: "sort", value: sort)) }
        if let containerStart, let containerSize {
            items.append(.init(name: "X-Plex-Container-Start", value: String(containerStart)))
            items.append(.init(name: "X-Plex-Container-Size", value: String(containerSize)))
        }
        return items
    }
}
