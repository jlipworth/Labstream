import Foundation

/// Parsed components of a synthetic MediaBrowser image ref of the form
/// `<scheme>://item/<id>/<Type>?tag=<tag>` (the value stored in a `MediaItem`'s
/// `thumb`/`art` for Jellyfin/Emby items). The pure parse lives here in PMSKit so it
/// can be unit-tested without the app target; `PosterImage` (online) and the offline
/// download poster cache both go through it.
public struct MediaBrowserSyntheticImageRef: Sendable, Equatable {
    public let itemId: String
    public let type: MediaBrowserImageType
    public let tag: String?

    public init(itemId: String, type: MediaBrowserImageType, tag: String?) {
        self.itemId = itemId
        self.type = type
        self.tag = tag
    }

    /// Parse a synthetic image ref. `expectedScheme` is the backend's
    /// `Flavor.syntheticScheme` (`"jellyfin"` / `"emby"`). Returns nil when the ref is
    /// empty, uses a different scheme, or is otherwise malformed.
    public static func parse(_ ref: String?, scheme expectedScheme: String) -> MediaBrowserSyntheticImageRef? {
        guard let ref, !ref.isEmpty,
              let url = URL(string: ref),
              url.scheme == expectedScheme,
              url.host == "item" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2,
              let type = MediaBrowserImageType(rawValue: parts[1]) else { return nil }
        let tag = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "tag" }?
            .value
        return MediaBrowserSyntheticImageRef(itemId: parts[0], type: type, tag: tag)
    }
}

public extension JellyfinLibrary {
    /// Build an authenticated poster-image request for a synthetic Jellyfin image ref
    /// (`jellyfin://item/<id>/<Type>?tag=`). Used by the offline download poster cache —
    /// unlike Plex, the Jellyfin image endpoint requires the `Authorization` header, so
    /// the request must go through `authenticatedRequest`. Returns nil for an
    /// unparseable / non-Jellyfin ref.
    static func posterRequest(syntheticRef ref: String?,
                              server: URL,
                              token: String,
                              identity: JellyfinClientIdentity,
                              width: Int = 400,
                              height: Int = 600) throws -> URLRequest? {
        guard let parsed = MediaBrowserSyntheticImageRef.parse(ref, scheme: JellyfinFlavor.syntheticScheme) else {
            return nil
        }
        let url = try imageURL(server: server,
                               itemId: parsed.itemId,
                               imageType: parsed.type,
                               tag: parsed.tag,
                               width: width,
                               height: height)
        var req = authenticatedRequest(url: url, token: token, identity: identity)
        req.setValue("image/jpeg,*/*", forHTTPHeaderField: "Accept")
        return req
    }
}

public extension EmbyLibrary {
    /// Build an authenticated poster-image request for a synthetic Emby image ref
    /// (`emby://item/<id>/<Type>?tag=`). The Emby image endpoint authenticates via the
    /// `Authorization` header (which also carries `userId`), so the request must go
    /// through `authenticatedRequest`. Returns nil for an unparseable / non-Emby ref.
    static func posterRequest(syntheticRef ref: String?,
                              server: URL,
                              token: String,
                              identity: EmbyClientIdentity,
                              userId: String,
                              width: Int = 400,
                              height: Int = 600) throws -> URLRequest? {
        guard let parsed = MediaBrowserSyntheticImageRef.parse(ref, scheme: EmbyFlavor.syntheticScheme) else {
            return nil
        }
        let url = try imageURL(server: server,
                               itemId: parsed.itemId,
                               imageType: parsed.type,
                               tag: parsed.tag,
                               width: width,
                               height: height)
        var req = authenticatedRequest(url: url, token: token, identity: identity, userId: userId)
        req.setValue("image/jpeg,*/*", forHTTPHeaderField: "Accept")
        return req
    }
}
