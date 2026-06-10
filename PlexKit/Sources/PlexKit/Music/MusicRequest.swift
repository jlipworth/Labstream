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

    /// List all artists in a music section:
    /// `GET /library/sections/{sectionKey}/all?type=8`.
    public static func artists(server: URL,
                               token: String,
                               identity: ClientIdentity,
                               sectionKey: String) -> PlexRequest {
        sectionAll(server: server, token: token, identity: identity,
                   sectionKey: sectionKey, type: 8)
    }

    /// List all albums in a music section:
    /// `GET /library/sections/{sectionKey}/all?type=9`.
    public static func albums(server: URL,
                              token: String,
                              identity: ClientIdentity,
                              sectionKey: String) -> PlexRequest {
        sectionAll(server: server, token: token, identity: identity,
                   sectionKey: sectionKey, type: 9)
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
}
