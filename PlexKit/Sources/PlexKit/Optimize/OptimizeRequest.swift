import Foundation

/// Media Optimizer request builders + offline download URL builder.
///
/// Triggers a server-side "optimized version" (capped-bitrate transcode written
/// to disk on the server) that can then be downloaded for offline playback.
///
/// **Port notes (python-plexapi `Video.optimize`):**
/// python-plexapi posts a `PUT` to `{backgroundProcessing.key}/items`, where
/// `backgroundProcessing.key` is fetched at runtime from `/playlists?type=42`
/// (type 42 == the optimize/background-processing playlist). Its params use a
/// nested bracket grammar: `Item[title]`, `Item[target]`, `Item[targetTagID]`,
/// `Item[MediaSettings][maxVideoBitrate]`, `Item[MediaSettings][videoResolution]`,
/// `Item[Location][uri]`, etc. `targetTagID` is resolved from a live
/// `mediaProcessingTarget` tag lookup on the server.
///
/// That exact path is **version-dependent and requires a runtime fetch**, so it
/// can't be a pure builder. We keep this builder to the plan's contract (a flat
/// `/library/optimize` PUT carrying `title` + `target` + `targetTagID`) which is
/// the legacy endpoint shape, and expose the `Item[...]`-style params as well so
/// the live executor (app target) can switch to the playlist path once it has
/// fetched the background-processing key. See `notes` / research/11 — if the live
/// server diverges, record the actual shape and adjust the test (the test is our
/// contract).
public enum OptimizeRequest {

    /// Known optimize preset target tags. `rawValue` is the human target name;
    /// `tagID` is the `targetTagID` python-plexapi resolves from the server's
    /// `mediaProcessingTarget` tags. The IDs are the conventional Plex defaults;
    /// the live executor SHOULD confirm them against the server's tag list and
    /// override if the server reports different IDs (version drift).
    public enum Target: Sendable, Equatable {
        /// "Optimized for TV" preset, capped to ~8 Mbps 1080p (this app's default).
        case tv1080p8Mbps
        /// "Optimized for Mobile" preset.
        case mobile
        /// "Original Quality" preset.
        case original

        /// The `target` name string Plex matches case-insensitively.
        public var name: String {
            switch self {
            case .tv1080p8Mbps: return "Optimized for TV"
            case .mobile:       return "Optimized for Mobile"
            case .original:     return "Original Quality"
            }
        }

        /// Conventional `targetTagID` for the preset.
        public var tagID: Int {
            switch self {
            case .tv1080p8Mbps: return 2
            case .mobile:       return 1
            case .original:     return 3
            }
        }

        /// Capped video bitrate (kbps) baked into the preset, when applicable.
        public var maxVideoBitrateKbps: Int? {
            switch self {
            case .tv1080p8Mbps: return 8000
            case .mobile:       return 2000
            case .original:     return nil
            }
        }

        /// Target video resolution string, when applicable.
        public var videoResolution: String? {
            switch self {
            case .tv1080p8Mbps: return "1920x1080"
            case .mobile:       return "1280x720"
            case .original:     return nil
            }
        }
    }

    /// Build the optimize-create request.
    ///
    /// Emits a `PUT /library/optimize` carrying the flat `title`/`target`/
    /// `targetTagID` params (plan contract) plus the nested `Item[...]`
    /// MediaSettings params python-plexapi sends, plus the standard identity
    /// headers + token. `ratingKey` identifies the source item.
    public static func create(server: URL,
                              token: String,
                              identity: ClientIdentity,
                              ratingKey: String,
                              title: String,
                              targetTagID target: Target) -> PlexRequest {
        let url = server.appendingPathComponent("library/optimize")
        var items: [URLQueryItem] = [
            .init(name: "title", value: title),
            .init(name: "target", value: target.name),
            .init(name: "targetTagID", value: String(target.tagID)),
            .init(name: "Item[type]", value: "42"),
            .init(name: "Item[title]", value: title),
            .init(name: "Item[target]", value: target.name),
            .init(name: "Item[targetTagID]", value: String(target.tagID)),
            .init(name: "Item[Location][uri]",
                  value: "server://\(identity.clientIdentifier)/com.plexapp.plugins.library/library/metadata/\(ratingKey)"),
            .init(name: "Item[MediaSettings][videoQuality]", value: "100"),
            .init(name: "Item[MediaSettings][audioBoost]", value: ""),
            .init(name: "Item[MediaSettings][subtitleSize]", value: ""),
            .init(name: "Item[MediaSettings][musicBitrate]", value: ""),
            .init(name: "Item[MediaSettings][photoQuality]", value: ""),
            .init(name: "Item[MediaSettings][photoResolution]", value: ""),
        ]
        if let bitrate = target.maxVideoBitrateKbps {
            items.append(.init(name: "Item[MediaSettings][maxVideoBitrate]", value: String(bitrate)))
        }
        if let resolution = target.videoResolution {
            items.append(.init(name: "Item[MediaSettings][videoResolution]", value: resolution))
        }
        return PlexRequest(url: url,
                           method: "PUT",
                           queryItems: items,
                           headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// Poll the optimize / background-processing queue for status.
    ///
    /// python-plexapi reads progress from the `/playlists?type=42` background
    /// playlist; once an optimized version completes it appears as a new
    /// `Media`/`Part` on the source item. We poll the item's metadata so the
    /// executor can detect the new optimized `Part` and then download it.
    public static func statusRequest(server: URL,
                                     token: String,
                                     identity: ClientIdentity,
                                     ratingKey: String) -> PlexRequest {
        let url = server.appendingPathComponent("library/metadata/\(ratingKey)")
        return PlexRequest(url: url,
                           method: "GET",
                           queryItems: [],
                           headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// Build the offline-download URL for an optimized (or any) part.
    ///
    /// `<server><partKey>?download=1&X-Plex-Token=<token>` — token as query param
    /// since the background `URLSession` won't carry our API headers.
    public static func downloadURL(server: URL,
                                   token: String,
                                   partKey: String) -> URL {
        var components = URLComponents(
            url: server.appendingPathComponent(partKey.hasPrefix("/") ? String(partKey.dropFirst()) : partKey),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            .init(name: "download", value: "1"),
            .init(name: "X-Plex-Token", value: token),
        ]
        return components.url!
    }
}
