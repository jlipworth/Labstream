import Foundation

/// Request builders for Plex playlists (read-only v1 — see docs/MUSIC-DESIGN.md §3.4).
///
/// Playlists live outside the section tree: `GET /playlists` lists them (filtered to
/// `playlistType=audio` for the Music pivot) and `GET /playlists/{ratingKey}/items`
/// returns the ordered tracks. Both decode through the existing `MetadataResponse`
/// (`Metadata` elements; a playlist item is `type == "playlist"`, its items are
/// ordinary `track`s). Pure URL constructors, unit-tested like the other builders.
public enum PlaylistRequest {

    /// List audio playlists: `GET /playlists?playlistType=audio`.
    public static func audioPlaylists(server: URL,
                                      token: String,
                                      identity: ClientIdentity) -> PlexRequest {
        PlexRequest(url: server.appendingPathComponent("/playlists"),
                    method: "GET",
                    queryItems: [.init(name: "playlistType", value: "audio")],
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// A playlist's ordered items: `GET /playlists/{ratingKey}/items`.
    public static func items(server: URL,
                             token: String,
                             identity: ClientIdentity,
                             ratingKey: String) -> PlexRequest {
        PlexRequest(url: server.appendingPathComponent("/playlists/\(ratingKey)/items"),
                    method: "GET",
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }
}
