import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Media Optimizer request builders + offline download URL builder.
///
/// Triggers a server-side "optimized version" (capped-bitrate transcode written
/// to disk on the server) that can then be downloaded for offline playback.
///
/// Optimize jobs are created on the server's background-processing playlist
/// (`/playlists?type=42`, see `backgroundProcessingRequest` / `createOnPlaylist`), matching
/// python-plexapi `Video.optimize`. The legacy flat `PUT /library/optimize` builder was removed
/// because the app never used it.
public enum OptimizeRequest {

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

    public enum CreateError: Error, Equatable, Sendable {
        /// Neither a library source URI nor the server's machine identifier was available, so
        /// there is no `Item[Location][uri]` PMS could resolve.
        case missingSourceLocation
    }

    /// `POST {backgroundProcessingKey}` — enqueue an optimize job using the nested `Item[...]`
    /// grammar python-plexapi sends. `targetTagID` is the SERVER-RESOLVED id (from the targets
    /// list), NOT a hardcoded enum default. SERVER-SPECIFIC: the accepted key + grammar are
    /// confirmed by Phase 0.
    ///
    /// `sourceURI` is the preferred `library://<section uuid>/item/...` location. Without it the
    /// fallback is `server://<serverMachineIdentifier>/...`, which must name the SERVER (its
    /// machine identifier), never this client. With neither, this throws
    /// `CreateError.missingSourceLocation` rather than sending a URI PMS cannot resolve.
    public static func createOnPlaylist(server: URL, token: String, identity: ClientIdentity,
                                        backgroundProcessingKey: String,
                                        ratingKey: String,
                                        sourceURI: String? = nil,
                                        serverMachineIdentifier: String? = nil,
                                        locationID: Int = -1,
                                        title: String,
                                        targetTagID: Int?,
                                        targetName: String? = nil,
                                        deviceProfile: String? = nil,
                                        mediaSettings: MediaSettings) throws -> PlexRequest {
        let locationURI: String
        if let sourceURI, !sourceURI.isEmpty {
            locationURI = sourceURI
        } else if let machine = serverMachineIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !machine.isEmpty {
            locationURI = PlayQueue.itemURI(machineIdentifier: machine, ratingKey: ratingKey)
        } else {
            throw CreateError.missingSourceLocation
        }
        let trimmed = backgroundProcessingKey.hasPrefix("/")
            ? String(backgroundProcessingKey.dropFirst()) : backgroundProcessingKey
        let url = server.appendingPathComponent(trimmed)
        var items: [URLQueryItem] = [
            .init(name: "Item[type]", value: "42"),
            .init(name: "Item[title]", value: title),
            .init(name: "Item[target]", value: targetName ?? ""),
            .init(name: "Item[targetTagID]", value: targetTagID.map(String.init) ?? ""),
            .init(name: "Item[Location][uri]", value: locationURI),
            .init(name: "Item[locationID]", value: String(locationID)),
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

    /// `DELETE {backgroundProcessingKey}/{itemID}` — remove a single queued optimize item
    /// (cancel/clear a stale job). `backgroundProcessingKey` is the type-42 items path
    /// (e.g. `/playlists/9/items`); `itemID` is the item's `id`. Mirrors python-plexapi
    /// `Optimized.remove` (`DELETE <items-key>/<id>`).
    public static func removeBackgroundItem(server: URL, token: String, identity: ClientIdentity,
                                            backgroundProcessingKey: String,
                                            itemID: String) -> PlexRequest {
        let trimmed = backgroundProcessingKey.hasPrefix("/")
            ? String(backgroundProcessingKey.dropFirst()) : backgroundProcessingKey
        return PlexRequest(url: server.appendingPathComponent("\(trimmed)/\(itemID)"),
                           method: "DELETE",
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

/// The type-42 background-processing queue items (`GET {backgroundProcessing.key}`), used to
/// find and clear stale optimize jobs that pile up when downloads are abandoned/cancelled and
/// make new jobs wait behind them. Lenient: degrades to `[]` rather than throwing.
public struct BackgroundProcessingItems: Decodable, Sendable, Equatable {
    public struct Item: Decodable, Sendable, Equatable {
        public let id: String?
        /// PRIVACY-SENSITIVE: carries the media title. Used in memory only — never logged.
        public let title: String?
        public let state: String?

        public init(id: String?, title: String?, state: String?) {
            self.id = id; self.title = title; self.state = state
        }

        enum CodingKeys: String, CodingKey { case id, title; case status = "Status" }
        private struct StatusBox: Decodable { let state: String? }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // id may arrive as a String or an Int.
            if let stringID = try? c.decode(String.self, forKey: .id) {
                self.id = stringID
            } else if let integerID = try? c.decode(Int.self, forKey: .id) {
                self.id = String(integerID)
            } else {
                self.id = nil
            }
            self.title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
            let status = (try? c.decodeIfPresent(StatusBox.self, forKey: .status)) ?? nil
            self.state = status?.state
        }
    }

    public let items: [Item]
    /// False when the response lacked a `MediaContainer` or carried an `Item` value that did not
    /// decode. The lenient `items` stays empty for existing callers, but an empty malformed list
    /// is not evidence that a queue item is absent (P2 cleanup).
    public let isWellFormed: Bool

    enum RootKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
    enum ContainerKeys: String, CodingKey { case item = "Item" }

    public init(items: [Item], isWellFormed: Bool = true) {
        self.items = items
        self.isWellFormed = isWellFormed
    }

    public init(from decoder: Decoder) throws {
        guard let root = try? decoder.container(keyedBy: RootKeys.self),
              let container = try? root.nestedContainer(keyedBy: ContainerKeys.self,
                                                        forKey: .mediaContainer) else {
            self.items = []
            self.isWellFormed = false
            return
        }
        guard container.contains(.item) else {
            self.items = []
            self.isWellFormed = true
            return
        }
        if let items = try? container.decode([Item].self, forKey: .item) {
            self.items = items
            self.isWellFormed = true
        } else {
            self.items = []
            self.isWellFormed = false
        }
    }

    /// What a delete-time cleanup may do with this row's queue item (P2.3).
    public enum CleanupOutcome: Equatable, Sendable {
        /// The response could not establish the queue contents.
        case malformed
        /// A well-formed list holds no item with this exact title.
        case absent
        /// The item finished; deleting it would delete the rendered version (D2 keeps it).
        case completed
        /// One exact match in a known active or failed state.
        case cancellable(id: String)
        /// Duplicate titles, a missing id, or a missing/unrecognized state.
        case uncertain
    }

    /// States known to be safe to cancel: still queued/running, or failed.
    static let cancellableStates: Set<String> = [
        "pending", "queued", "waiting", "processing", "transcoding", "running",
        "inprogress", "in_progress", "error", "failed",
    ]

    public func cleanupOutcome(queueTitle: String) -> CleanupOutcome {
        guard isWellFormed else { return .malformed }
        let matches = items.filter { $0.title == queueTitle }
        guard let item = matches.first else { return .absent }
        guard matches.count == 1, let id = item.id, !id.isEmpty,
              let state = item.state?.lowercased(), !state.isEmpty else { return .uncertain }
        if Self.completedStates.contains(state) { return .completed }
        return Self.cancellableStates.contains(state) ? .cancellable(id: id) : .uncertain
    }

    /// PMS states that mean the job finished. Deleting a completed background-processing item
    /// also deletes the rendered optimized version on the server, so the download pipeline must
    /// preserve these until the client has positively downloaded or explicitly removed them.
    static let completedStates: Set<String> = PlexOptimizeCompletionPolicy.completedStates

    /// IDs of items that are SAFE to delete: those whose title carries `marker` (i.e. this
    /// client created them), whose title is NOT in `protectedTitles` (a currently-active
    /// download), and whose state is NOT completed (a finished job's file may be in use).
    /// Never deletes another client's jobs, an in-flight one, or a completed one — only the
    /// pending/failed pileup that actually blocks the queue.
    ///
    /// NOTE: this *completed-skipping* variant is the conservative legacy behavior, kept for
    /// callers that cannot guarantee a completed item's rendered Part isn't being downloaded.
    /// The download pipeline now protects an in-flight job's title for its REAL download
    /// lifetime (not just the optimize kickoff). The download pipeline still uses this
    /// conservative helper because a relaunched app may need to rediscover completed items.
    public func staleItemIDs(marker: String, protectedTitles: Set<String>) -> [String] {
        items.compactMap { item in
            guard let id = item.id, !id.isEmpty,
                  let title = item.title, title.contains(marker),
                  !protectedTitles.contains(title) else { return nil }
            if let s = item.state?.lowercased(), Self.completedStates.contains(s) { return nil }
            return id
        }
    }

    /// The single queue item that a delete-time cancel may remove: the item whose title exactly
    /// matches the deleted row's persisted queue title AND whose state is NOT completed.
    ///
    /// Returns `nil` when no item matches or when the matching item already finished — deleting a
    /// COMPLETED type-42 item deletes the rendered optimized version on the server, which other
    /// rows (or a relaunched client) may still need, so a completed match must be left alone.
    public func cancellableItemID(queueTitle: String) -> String? {
        guard let item = items.first(where: { $0.title == queueTitle }),
              let id = item.id, !id.isEmpty else { return nil }
        if let s = item.state?.lowercased(), Self.completedStates.contains(s) { return nil }
        return id
    }

    /// Number of queue items whose title carries `marker` — privacy-safe COUNT only (never the
    /// title value). Used by diagnostics to tell "no items matched our marker" (server didn't
    /// preserve the title we submitted, or jobs predate the marker) apart from "matched but all
    /// protected/completed". A diagnostic signal, not a deletion gate.
    public func markedCount(marker: String) -> Int {
        items.filter { ($0.title?.contains(marker) ?? false) }.count
    }

    /// Number of items NOT in a completed state (the pending/failed pileup that blocks the queue),
    /// regardless of marker. Privacy-safe count.
    public var pendingCount: Int {
        items.filter { item in
            guard let s = item.state?.lowercased() else { return true }
            return !Self.completedStates.contains(s)
        }.count
    }
}
