import Foundation

/// Request builder for a metadata item's children:
/// `GET /library/metadata/{ratingKey}/children`.
///
/// On PMS this single endpoint walks the TV hierarchy one level at a time:
///   - children of a `show`   → its `season`s
///   - children of a `season` → its `episode`s
///
/// The response is the standard `MetadataResponse` (`MediaContainer.Metadata`), so the
/// caller decodes it exactly like a section/hub listing. We request markers/chapters so
/// a resolved episode arrives ready for the player without an extra round-trip; these
/// are additive params PMS ignores when absent.
///
/// Kept pure (no networking) so the URL/params are unit-testable, mirroring the other
/// PlexKit builders (`TimelineRequest`, `OptimizeRequest`, …). The UI's `BrowseAPI`
/// delegates to this so all child-fetch wiring has one source of truth.
public enum ChildrenRequest {
    public static func children(server: URL,
                                token: String,
                                identity: ClientIdentity,
                                ratingKey: String) -> PlexRequest {
        let url = server.appendingPathComponent("/library/metadata/\(ratingKey)/children")
        return PlexRequest(url: url,
                           method: "GET",
                           queryItems: [
                               .init(name: "includeChapters", value: "1"),
                               .init(name: "includeMarkers", value: "1"),
                           ],
                           headers: PlexHeaders.standard(identity: identity, token: token))
    }
}
