import Foundation

/// Server-side background-conversion probes + the idle-pause toggle.
///
/// The Media Optimizer runs conversions off a SEPARATE ordered queue from the type-42
/// `Optimized` registry that `OptimizeRequest` reads. Per python-plexapi:
///   * `GET /status/sessions/background` → `TranscodeJob`s (the actively running/paused
///     optimization, "usually one item at a time").
///   * `GET /playQueues/1` → `Conversion`s (the ordered queue of items queued for or being
///     actively optimized; `move(after:'-1')` marks the active conversion).
///   * The server pref `BackgroundQueueIdlePaused` gates whether the queue runs at all
///     (`PlexServer.conversions(pause=…)` toggles it via `PUT /:/prefs`).
///
/// These let the client tell "completed-item clutter" (inert) apart from a genuinely stalled
/// or idle-paused server queue, and unpause it. All decoders are LENIENT — XML-vs-JSON drift,
/// missing keys, or an unexpected shape degrade to empty/nil rather than throwing.
public enum BackgroundQueueRequest {

    /// `GET /status/sessions/background` — the running/paused optimization jobs (`TranscodeJob`).
    public static func transcodeJobsRequest(server: URL, token: String,
                                            identity: ClientIdentity) -> PlexRequest {
        PlexRequest(url: server.appendingPathComponent("/status/sessions/background"),
                    method: "GET", queryItems: [],
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// `GET /playQueues/1` — the ordered conversion queue (`Conversion`).
    public static func conversionQueueRequest(server: URL, token: String,
                                              identity: ClientIdentity) -> PlexRequest {
        PlexRequest(url: server.appendingPathComponent("/playQueues/1"),
                    method: "GET", queryItems: [],
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// `GET /:/prefs` — the server preference list (carries `BackgroundQueueIdlePaused`).
    public static func prefsRequest(server: URL, token: String,
                                    identity: ClientIdentity) -> PlexRequest {
        PlexRequest(url: server.appendingPathComponent("/:/prefs"),
                    method: "GET", queryItems: [],
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// `PUT /:/prefs?BackgroundQueueIdlePaused=0` — clear the idle-pause so queued conversions
    /// run. Mirrors python-plexapi `PlexServer.conversions(pause=False)`. Only send this when a
    /// read showed the queue IS paused (conditional write — don't needlessly mutate a fine server).
    public static func setBackgroundQueueIdlePausedRequest(server: URL, token: String,
                                                           identity: ClientIdentity,
                                                           paused: Bool) -> PlexRequest {
        PlexRequest(url: server.appendingPathComponent("/:/prefs"),
                    method: "PUT",
                    queryItems: [.init(name: "BackgroundQueueIdlePaused", value: paused ? "1" : "0")],
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// `PUT /playQueues/1/items/{playQueueItemID}/move?after={afterItemID}` — reposition a queued
    /// conversion. Mirrors python-plexapi `Conversion.move(after)`: `after = -1` moves the item to
    /// the FRONT (the active-conversion position); any other value moves it to immediately after the
    /// item with that `playQueueItemID`. Best-effort write — the caller treats any failure as benign.
    public static func moveConversionRequest(server: URL, token: String, identity: ClientIdentity,
                                             playQueueItemID: String,
                                             afterItemID: String) -> PlexRequest {
        let path = "/playQueues/1/items/\(playQueueItemID)/move"
        return PlexRequest(url: server.appendingPathComponent(path),
                           method: "PUT",
                           queryItems: [.init(name: "after", value: afterItemID)],
                           headers: PlexHeaders.standard(identity: identity, token: token))
    }
}

/// `GET /status/sessions/background` → the running/paused optimization jobs. Lenient: degrades
/// to `[]` rather than throwing. We only surface privacy-safe facts (counts, numeric progress,
/// a short state token) — never a media `title`.
public struct BackgroundTranscodeJobs: Decodable, Sendable, Equatable {
    public struct Job: Decodable, Sendable, Equatable {
        /// 0…100, or `-1`/`nil` when absent/indeterminate.
        public let progress: Int?
        /// Short queued/running/paused-style state token (a server vocabulary word, NOT a title).
        public let state: String?
        /// Transcode realtime multiplier (e.g. `1.5` = 1.5× realtime), when the server reports
        /// one. `nil` when absent/indeterminate. Combined with the media duration + progress,
        /// this yields a much steadier transcode ETA than the progress-rate EMA fallback. The
        /// live shape's key is uncertain, so we decode defensively from the two most likely keys
        /// (`speed`, `transcodeSpeed`), tolerate Int/Double/String, and never throw.
        public let speed: Double?

        public init(progress: Int?, state: String?, speed: Double? = nil) {
            self.progress = progress; self.state = state; self.speed = speed
        }

        enum CodingKeys: String, CodingKey {
            case progress; case status = "Status"; case state
            case speed; case transcodeSpeed
        }
        private struct StatusBox: Decodable { let state: String? }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let i = (try? c.decodeIfPresent(Int.self, forKey: .progress)) ?? nil {
                self.progress = i
            } else if let d = (try? c.decodeIfPresent(Double.self, forKey: .progress)) ?? nil {
                self.progress = Int(d)
            } else if let s = (try? c.decodeIfPresent(String.self, forKey: .progress)) ?? nil,
                      let i = Int(s) {
                self.progress = i
            } else {
                self.progress = nil
            }
            // State may live at the top level or inside a nested `Status`.
            let nested = (try? c.decodeIfPresent(StatusBox.self, forKey: .status)) ?? nil
            self.state = ((try? c.decodeIfPresent(String.self, forKey: .state)) ?? nil)
                ?? nested?.state
            // Speed: prefer `speed`, fall back to `transcodeSpeed`. Tolerate Double/Int/String.
            self.speed = Self.decodeSpeed(c, .speed) ?? Self.decodeSpeed(c, .transcodeSpeed)
        }

        /// Lenient numeric decode for the speed multiplier: Double, then Int, then a parseable
        /// String. Returns `nil` for any absent/garbage value; only positive values are kept
        /// (a non-positive multiplier is meaningless for an ETA and would divide badly).
        private static func decodeSpeed(_ c: KeyedDecodingContainer<CodingKeys>,
                                        _ key: CodingKeys) -> Double? {
            let value: Double?
            if let d = (try? c.decodeIfPresent(Double.self, forKey: key)) ?? nil {
                value = d
            } else if let i = (try? c.decodeIfPresent(Int.self, forKey: key)) ?? nil {
                value = Double(i)
            } else if let s = (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil {
                value = Double(s)
            } else {
                value = nil
            }
            guard let v = value, v.isFinite, v > 0 else { return nil }
            return v
        }
    }

    public let jobs: [Job]

    enum RootKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
    enum ContainerKeys: String, CodingKey { case transcodeJob = "TranscodeJob" }

    public init(jobs: [Job]) { self.jobs = jobs }

    public init(from decoder: Decoder) throws {
        guard let root = try? decoder.container(keyedBy: RootKeys.self),
              let container = try? root.nestedContainer(keyedBy: ContainerKeys.self,
                                                        forKey: .mediaContainer) else {
            self.jobs = []
            return
        }
        self.jobs = (try? container.decodeIfPresent([Job].self, forKey: .transcodeJob)) ?? []
    }

    /// The first job's numeric progress, if any.
    public var firstProgress: Int? { jobs.first?.progress }
    /// The first job's short state token, if any (safe to log — not a title).
    public var firstState: String? { jobs.first?.state }
    /// The first job's transcode realtime multiplier, if reported (safe to log — a number).
    public var firstSpeed: Double? { jobs.first?.speed }
}

/// `GET /playQueues/1` → the ordered conversion queue. Lenient: degrades to `[]`. We surface
/// only counts, ids, and whether an active conversion is present — never a media `title`.
///
/// SHAPE (PMS JSON, verified against python-plexapi `PlexServer.conversions()` + `Conversion`):
/// python-plexapi `fetchItems('/playQueues/1', cls=Conversion)` reads elements whose XML `TAG`
/// is `Video`. The same elements arrive under the JSON key `Video` (Plex mirrors element names
/// to JSON keys). BUT generic playQueue endpoints commonly serialize their items under
/// `Metadata` instead, and some shapes use `Item`, so we accept all three. Each conversion
/// element carries `playQueueItemID` (the move handle) and a queue-order field that python-plexapi
/// does not expose but PMS includes as `playQueueItemOrder` (sometimes `order`). The ACTIVE
/// conversion is the head of the order — identified by the container's `playQueueSelectedItemID`
/// when present, else the lowest-order item, else (as a last resort) the first decoded element.
public struct ConversionQueue: Decodable, Sendable, Equatable {
    public struct Item: Decodable, Sendable, Equatable {
        /// Move handle; passed to `moveConversionRequest`. `-1` is python-plexapi's active marker.
        public let playQueueItemID: String?
        /// Queue order from `playQueueItemOrder` (or `order`). Lower = nearer the front.
        public let order: Int?
        /// Library item id — lets the client match its OWN just-enqueued conversion.
        public let ratingKey: String?

        public init(playQueueItemID: String?, order: Int?, ratingKey: String? = nil) {
            self.playQueueItemID = playQueueItemID; self.order = order; self.ratingKey = ratingKey
        }

        enum CodingKeys: String, CodingKey {
            case playQueueItemID, order, playQueueItemOrder, ratingKey
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.playQueueItemID = Self.string(c, .playQueueItemID)
            self.order = Self.int(c, .playQueueItemOrder) ?? Self.int(c, .order)
            self.ratingKey = Self.string(c, .ratingKey)
        }

        /// Lenient String decode tolerating String or Int (PMS JSON mixes both).
        private static func string(_ c: KeyedDecodingContainer<CodingKeys>,
                                   _ key: CodingKeys) -> String? {
            if let s = (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil { return s }
            if let i = (try? c.decodeIfPresent(Int.self, forKey: key)) ?? nil { return String(i) }
            return nil
        }

        /// Lenient Int decode tolerating Int, Double, or numeric String.
        private static func int(_ c: KeyedDecodingContainer<CodingKeys>,
                                _ key: CodingKeys) -> Int? {
            if let i = (try? c.decodeIfPresent(Int.self, forKey: key)) ?? nil { return i }
            if let d = (try? c.decodeIfPresent(Double.self, forKey: key)) ?? nil { return Int(d) }
            if let s = (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil { return Int(s) }
            return nil
        }
    }

    public let items: [Item]
    /// `playQueueSelectedItemID` from the container, when present — the head/active conversion.
    public let selectedItemID: String?

    enum RootKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
    enum ContainerKeys: String, CodingKey {
        case metadata = "Metadata"; case video = "Video"; case item = "Item"
        case playQueueSelectedItemID
    }

    public init(items: [Item], selectedItemID: String? = nil) {
        self.items = items; self.selectedItemID = selectedItemID
    }

    public init(from decoder: Decoder) throws {
        guard let root = try? decoder.container(keyedBy: RootKeys.self),
              let container = try? root.nestedContainer(keyedBy: ContainerKeys.self,
                                                        forKey: .mediaContainer) else {
            self.items = []; self.selectedItemID = nil
            return
        }
        // Accept whichever element key the live server uses: Metadata, Video, or Item.
        let metadata = (try? container.decodeIfPresent([Item].self, forKey: .metadata)) ?? []
        let video = (try? container.decodeIfPresent([Item].self, forKey: .video)) ?? []
        let item = (try? container.decodeIfPresent([Item].self, forKey: .item)) ?? []
        self.items = !metadata.isEmpty ? metadata : (!video.isEmpty ? video : item)
        // The selected/active item id may arrive as String or Int.
        if let s = (try? container.decodeIfPresent(String.self, forKey: .playQueueSelectedItemID)) ?? nil {
            self.selectedItemID = s
        } else if let i = (try? container.decodeIfPresent(Int.self, forKey: .playQueueSelectedItemID)) ?? nil {
            self.selectedItemID = String(i)
        } else {
            self.selectedItemID = nil
        }
    }

    public var count: Int { items.count }

    /// The item ordered first (lowest `order`); falls back to first decoded when no order field.
    public var headItem: Item? {
        if items.contains(where: { $0.order != nil }) {
            return items.min { ($0.order ?? .max) < ($1.order ?? .max) }
        }
        return items.first
    }

    /// The active conversion the server is working: the `playQueueSelectedItemID` element when
    /// the container names one, else the head of the order. `nil` for an empty queue.
    public var activeItem: Item? {
        if let sel = selectedItemID, let m = items.first(where: { $0.playQueueItemID == sel }) {
            return m
        }
        return headItem
    }

    /// `true` when the queue has an active conversion. python-plexapi's `-1` active marker, or a
    /// selected item, or simply a non-empty queue (its head is being worked / about to be).
    public var hasActiveConversion: Bool {
        if items.contains(where: { $0.playQueueItemID == "-1" }) { return true }
        if selectedItemID != nil { return true }
        return !items.isEmpty
    }
}

/// `GET /:/prefs` → the server `Setting` list. We read ONLY `BackgroundQueueIdlePaused`. Lenient:
/// XML-vs-JSON drift / missing key → `nil` (treated as "unknown / not paused"), never throws.
public struct ServerPrefs: Decodable, Sendable, Equatable {
    /// `BackgroundQueueIdlePaused` as a bool, or `nil` when the setting wasn't found.
    public let backgroundQueueIdlePaused: Bool?

    enum RootKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
    enum ContainerKeys: String, CodingKey { case setting = "Setting" }
    private struct Setting: Decodable {
        let id: String?
        let value: String?
        enum CodingKeys: String, CodingKey { case id, value }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil
            // `value` may arrive as a Bool, Int (0/1), or String.
            if let b = (try? c.decodeIfPresent(Bool.self, forKey: .value)) ?? nil {
                self.value = b ? "1" : "0"
            } else if let i = (try? c.decodeIfPresent(Int.self, forKey: .value)) ?? nil {
                self.value = String(i)
            } else {
                self.value = (try? c.decodeIfPresent(String.self, forKey: .value)) ?? nil
            }
        }
    }

    public init(backgroundQueueIdlePaused: Bool?) {
        self.backgroundQueueIdlePaused = backgroundQueueIdlePaused
    }

    public init(from decoder: Decoder) throws {
        guard let root = try? decoder.container(keyedBy: RootKeys.self),
              let container = try? root.nestedContainer(keyedBy: ContainerKeys.self,
                                                        forKey: .mediaContainer),
              let settings = (try? container.decodeIfPresent([Setting].self, forKey: .setting)) ?? nil
        else {
            self.backgroundQueueIdlePaused = nil
            return
        }
        guard let raw = settings.first(where: { $0.id == "BackgroundQueueIdlePaused" })?.value else {
            self.backgroundQueueIdlePaused = nil
            return
        }
        self.backgroundQueueIdlePaused = Self.truthy(raw)
    }

    private static func truthy(_ raw: String) -> Bool {
        let v = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return v == "1" || v == "true" || v == "yes"
    }
}
