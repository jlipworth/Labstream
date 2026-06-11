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

/// Decoded response from `POST /playQueues` (and `GET /playQueues/<id>`).
///
/// The interesting state lives on the `MediaContainer`: the queue id, the
/// currently-selected item id and its offset, plus the ordered list of queued
/// items (each a `MediaItem`, with a per-item `playQueueItemID` for selection /
/// reordering / removal).
public struct PlayQueueResponse: Decodable, Sendable {
    public let mediaContainer: Container
    enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }

    public struct Container: Decodable, Sendable {
        /// The created/fetched play-queue id.
        public let playQueueID: Int?
        /// The item id (`playQueueItemID`) of the currently-selected queue entry.
        public let playQueueSelectedItemID: Int?
        /// The selected item's offset within the queue (0-based index).
        public let playQueueSelectedItemOffset: Int?
        /// The metadata `ratingKey` of the selected item, when PMS supplies it.
        public let playQueueSelectedMetadataItemID: String?
        /// Whether the queue should auto-continue past the selected item.
        public let playQueueShuffled: Bool?
        public let size: Int?
        /// The ordered queued items.
        public let metadata: [MediaItem]

        enum CodingKeys: String, CodingKey {
            case playQueueID
            case playQueueSelectedItemID
            case playQueueSelectedItemOffset
            case playQueueSelectedMetadataItemID
            case playQueueShuffled
            case size
            case metadata = "Metadata"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.playQueueID = try c.decodeIfPresent(Int.self, forKey: .playQueueID)
            self.playQueueSelectedItemID = try c.decodeIfPresent(Int.self, forKey: .playQueueSelectedItemID)
            self.playQueueSelectedItemOffset = try c.decodeIfPresent(Int.self, forKey: .playQueueSelectedItemOffset)
            // PMS may serialize this as a string or a bare number; accept both.
            if let s = try? c.decodeIfPresent(String.self, forKey: .playQueueSelectedMetadataItemID) {
                self.playQueueSelectedMetadataItemID = s
            } else if let n = try? c.decodeIfPresent(Int.self, forKey: .playQueueSelectedMetadataItemID) {
                self.playQueueSelectedMetadataItemID = String(n)
            } else {
                self.playQueueSelectedMetadataItemID = nil
            }
            self.playQueueShuffled = try c.decodeIfPresent(Bool.self, forKey: .playQueueShuffled)
            self.size = try c.decodeIfPresent(Int.self, forKey: .size)
            self.metadata = try c.decodeIfPresent([MediaItem].self, forKey: .metadata) ?? []
        }
    }
}
