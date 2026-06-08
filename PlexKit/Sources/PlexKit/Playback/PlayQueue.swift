import Foundation

/// Play-queue request builder: `POST /playQueues`.
///
/// A play queue is what the player and timeline reporting reference for
/// continuous playback / "up next". The `uri` points at the source metadata via
/// the server's machine identifier.
public enum PlayQueue {

    /// `POST /playQueues` — create a play queue for a single item.
    ///
    /// - Parameters:
    ///   - server: base server URL (scheme+host+port).
    ///   - token: Plex auth token (query param + header).
    ///   - identity: client identity for standard `X-Plex-*` headers.
    ///   - machineIdentifier: the server's machine identifier; forms the
    ///     `server://<machineIdentifier>/...` source `uri`.
    ///   - ratingKey: bare numeric rating key of the item to enqueue.
    ///   - type: queue media type. Defaults to `"video"`.
    ///   - continuous: whether to auto-continue to the next item. Defaults to `true` (`1`).
    public static func createRequest(server: URL,
                                     token: String,
                                     identity: ClientIdentity,
                                     machineIdentifier: String,
                                     ratingKey: String,
                                     type: String = "video",
                                     continuous: Bool = true) -> PlexRequest {
        let url = server.appendingPathComponent("/playQueues")
        let sourceURI = "server://\(machineIdentifier)/com.plexapp.plugins.library/library/metadata/\(ratingKey)"
        var items: [URLQueryItem] = [
            .init(name: "type", value: type),
            .init(name: "uri", value: sourceURI),
            .init(name: "continuous", value: continuous ? "1" : "0"),
            .init(name: "X-Plex-Token", value: token),
        ]
        items.append(contentsOf: TimelineRequest.identityQueryItems(identity))
        return PlexRequest(url: url, method: "POST",
                           queryItems: items,
                           headers: PlexHeaders.standard(identity: identity, token: token))
    }
}
