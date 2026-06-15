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

    // MARK: - Real optimize contract (Phase-0-gated; see the redesign spec/plan)

    /// Settings for an optimize job's rendered output. `nil` fields are omitted from the
    /// request so PMS uses the preset's defaults.
    public struct MediaSettings: Sendable, Equatable {
        public let videoQuality: Int?
        public let maxVideoBitrateKbps: Int?
        public let videoResolution: String?
        public init(videoQuality: Int? = 100, maxVideoBitrateKbps: Int? = nil,
                    videoResolution: String? = nil) {
            self.videoQuality = videoQuality
            self.maxVideoBitrateKbps = maxVideoBitrateKbps
            self.videoResolution = videoResolution
        }
    }

    /// `GET /playlists?type=42` — the background-processing playlist that owns optimize jobs.
    /// Decode with `BackgroundProcessingPlaylist` and read its `key` (e.g. `/playlists/9/items`).
    /// `PlexHeaders.standard` sets `Accept: application/json` (PMS returns XML by default and
    /// the decode would fail — the same trap the decision call hits).
    public static func backgroundProcessingRequest(server: URL, token: String,
                                                   identity: ClientIdentity) -> PlexRequest {
        PlexRequest(url: server.appendingPathComponent("/playlists"),
                    method: "GET",
                    queryItems: [.init(name: "type", value: "42")],
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// `GET /media/processing/targets` — the server's real optimize presets (name + id).
    /// SERVER-SPECIFIC: the exact path/field names are confirmed by Phase 0; this is the
    /// best-known endpoint. Decode with `MediaProcessingTargets`.
    public static func mediaProcessingTargetsRequest(server: URL, token: String,
                                                    identity: ClientIdentity) -> PlexRequest {
        PlexRequest(url: server.appendingPathComponent("/media/processing/targets"),
                    method: "GET",
                    queryItems: [],
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// `POST {backgroundProcessingKey}` — enqueue an optimize job using the nested `Item[...]`
    /// grammar python-plexapi sends. `targetTagID` is the SERVER-RESOLVED id (from the targets
    /// list), NOT a hardcoded enum default. SERVER-SPECIFIC: the accepted key + grammar are
    /// confirmed by Phase 0.
    public static func createOnPlaylist(server: URL, token: String, identity: ClientIdentity,
                                        backgroundProcessingKey: String,
                                        ratingKey: String,
                                        sourceURI: String? = nil,
                                        title: String,
                                        targetTagID: Int?,
                                        targetName: String? = nil,
                                        deviceProfile: String? = nil,
                                        mediaSettings: MediaSettings) -> PlexRequest {
        let trimmed = backgroundProcessingKey.hasPrefix("/")
            ? String(backgroundProcessingKey.dropFirst()) : backgroundProcessingKey
        let url = server.appendingPathComponent(trimmed)
        var items: [URLQueryItem] = [
            .init(name: "Item[type]", value: "42"),
            .init(name: "Item[title]", value: title),
            .init(name: "Item[target]", value: targetName ?? ""),
            .init(name: "Item[targetTagID]", value: targetTagID.map(String.init) ?? ""),
            .init(name: "Item[Location][uri]",
                  value: sourceURI ?? "server://\(identity.clientIdentifier)/com.plexapp.plugins.library/library/metadata/\(ratingKey)"),
            .init(name: "Item[locationID]", value: "-1"),
            .init(name: "Item[Policy][scope]", value: "all"),
            .init(name: "Item[Policy][value]", value: "0"),
            .init(name: "Item[Policy][unwatched]", value: "0"),
        ]
        if let deviceProfile, !deviceProfile.isEmpty {
            items.append(.init(name: "Item[Device][profile]", value: deviceProfile))
        }
        if let q = mediaSettings.videoQuality {
            items.append(.init(name: "Item[MediaSettings][videoQuality]", value: String(q)))
        }
        if let b = mediaSettings.maxVideoBitrateKbps {
            items.append(.init(name: "Item[MediaSettings][maxVideoBitrate]", value: String(b)))
        }
        if let res = mediaSettings.videoResolution {
            items.append(.init(name: "Item[MediaSettings][videoResolution]", value: res))
        }
        items += [
            .init(name: "Item[MediaSettings][audioBoost]", value: ""),
            .init(name: "Item[MediaSettings][subtitleSize]", value: ""),
            .init(name: "Item[MediaSettings][musicBitrate]", value: ""),
            .init(name: "Item[MediaSettings][photoQuality]", value: ""),
            .init(name: "Item[MediaSettings][photoResolution]", value: ""),
        ]
        return PlexRequest(url: url, method: "PUT", queryItems: items,
                           headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// Build the offline-download URL for an optimized (or any) part.
    ///
    /// `<server><partKey>?download=1&X-Plex-Token=<token>` — token as query param
    /// since the background `URLSession` won't carry our API headers.
    public static func downloadURL(server: URL,
                                   token: String,
                                   partKey: String) -> URL {
        let partURL = server.appendingPathComponent(
            partKey.hasPrefix("/") ? String(partKey.dropFirst()) : partKey)
        guard var components = URLComponents(url: partURL, resolvingAgainstBaseURL: false) else {
            preconditionFailure("OptimizeRequest: part URL is not decomposable: \(partURL)")
        }
        PlexURLQueryEncoder.replaceQueryItems([
            .init(name: "download", value: "1"),
            .init(name: "X-Plex-Token", value: token),
        ], in: &components)
        guard let url = components.url else {
            preconditionFailure("OptimizeRequest: could not rebuild download URL for part \(partKey)")
        }
        return url
    }
}

/// The background-processing playlist (`GET /playlists?type=42`). We only need its `key`
/// (e.g. `/playlists/9/items`) to POST optimize jobs against. Lenient: server shapes vary.
public struct BackgroundProcessingPlaylist: Decodable, Sendable, Equatable {
    public let key: String?

    enum RootKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
    enum ContainerKeys: String, CodingKey { case metadata = "Metadata" }
    private struct Entry: Decodable { let key: String?; let playlistType: String? }

    public init(key: String?) { self.key = key }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)
        let container = try root.nestedContainer(keyedBy: ContainerKeys.self, forKey: .mediaContainer)
        let entries = try container.decodeIfPresent([Entry].self, forKey: .metadata) ?? []
        // Prefer the type-42 entry; fall back to the first with a key.
        self.key = entries.first(where: { $0.playlistType == "42" })?.key
            ?? entries.first(where: { $0.key != nil })?.key
    }
}

/// The server's media-processing (optimize) targets (`GET /media/processing/targets`).
/// SERVER-SPECIFIC shape — Phase 0 confirms the element + field names. Lenient.
public struct MediaProcessingTargets: Decodable, Sendable, Equatable {
    public struct Target: Decodable, Sendable, Equatable, Identifiable {
        public let id: Int
        public let name: String
        public init(id: Int, name: String) { self.id = id; self.name = name }

        enum CodingKeys: String, CodingKey { case id; case tag; case title }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = (try? c.decode(Int.self, forKey: .id)) ?? -1
            self.name = (try? c.decodeIfPresent(String.self, forKey: .tag))
                ?? (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        }
    }

    public let targets: [Target]

    enum RootKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
    enum ContainerKeys: String, CodingKey { case target = "MediaProcessingTarget" }

    public init(targets: [Target]) { self.targets = targets }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)
        let container = try root.nestedContainer(keyedBy: ContainerKeys.self, forKey: .mediaContainer)
        self.targets = (try container.decodeIfPresent([Target].self, forKey: .target)) ?? []
    }

    /// Case-insensitive name → targetTagID lookup (used to resolve a chosen preset name).
    public func tagID(forName name: String) -> Int? {
        targets.first { $0.name.lowercased() == name.lowercased() }?.id
    }
}
