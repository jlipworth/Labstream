import Foundation

/// `GET /activities` — the server's live background-activity list, used to surface
/// optimize/transcode progress during the "Preparing on server…" download phase.
///
/// **Port notes (python-plexapi `PlexServer.activities`):** `Activity.key = /activities`,
/// authenticated with `X-Plex-Token`. With `Accept: application/json` (which
/// `PlexHeaders.standard` sets) PMS returns JSON; otherwise XML. The container is a
/// `MediaContainer` carrying an array under key `Activity` that is **omitted entirely
/// when zero activities are running**.
///
/// Each `Activity` carries `uuid`, `type` (dotted, e.g. `media.optimize`,
/// `library.update.section`), `cancellable` (0/1), `userID`, `title`, `subtitle`,
/// `progress` (int 0…100, `-1` = indeterminate), and a type-specific nested `Context`.
///
/// ⚠️ The optimize/conversion activity `type` is **undocumented and version-dependent**.
/// We match leniently (see `Activities.optimizeActivity`). The shape this decoder assumes
/// is best-known from python-plexapi + plexopedia; only a live probe confirms the real
/// field names/casing the user's PMS emits, so this decoder NEVER throws on drift.
public enum ActivitiesRequest {
    /// Build the `GET /activities` request. `PlexHeaders.standard` sets
    /// `Accept: application/json` so PMS returns JSON (it defaults to XML, which would
    /// fail the decode — the same trap the optimize-decision call hits).
    public static func list(server: URL, token: String, identity: ClientIdentity) -> PlexRequest {
        PlexRequest(url: server.appendingPathComponent("/activities"),
                    method: "GET",
                    queryItems: [],
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }
}

/// A single live server activity. Lenient decode: every field is optional and tolerant of
/// name/casing drift; an unexpected shape yields nils rather than throwing.
public struct PlexActivity: Decodable, Sendable, Equatable {
    public let uuid: String?
    public let type: String?
    /// 0…100, or `-1` for indeterminate. `nil` when the server omitted it.
    public let progress: Int?
    public let cancellable: Bool?
    /// Human title — **PRIVACY-SENSITIVE** (carries media/library names). Never log it.
    public let title: String?
    /// Human subtitle — **PRIVACY-SENSITIVE** (carries media/library names). Never log it.
    public let subtitle: String?
    /// Source ratingKey, when the server threads one through the nested `Context`.
    public let contextRatingKey: String?
    /// Library metadata id from the nested `Context` (`metadataID`). On a real PMS the
    /// `media.download` conversion activity carries this instead of `ratingKey`, and it
    /// equals the source item's ratingKey — so it is the reliable correlator here.
    public let contextMetadataID: String?

    public init(uuid: String? = nil, type: String? = nil, progress: Int? = nil,
                cancellable: Bool? = nil, title: String? = nil, subtitle: String? = nil,
                contextRatingKey: String? = nil, contextMetadataID: String? = nil) {
        self.uuid = uuid
        self.type = type
        self.progress = progress
        self.cancellable = cancellable
        self.title = title
        self.subtitle = subtitle
        self.contextRatingKey = contextRatingKey
        self.contextMetadataID = contextMetadataID
    }

    enum CodingKeys: String, CodingKey {
        case uuid, type, progress, cancellable, title, subtitle
        case context = "Context"
        // Drift-tolerant alternates seen across PMS versions / casings.
        case UUID, Title, Subtitle
        case typeCapitalized = "Type"
    }

    private struct Context: Decodable {
        let ratingKey: String?
        let metadataID: String?
        let key: String?
        enum CodingKeys: String, CodingKey { case ratingKey, metadataID, key }
        /// Decode an id that may arrive as a `String` or an `Int`.
        private static func id(_ c: KeyedDecodingContainer<CodingKeys>, _ k: CodingKeys) -> String? {
            if let s = (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil { return s }
            if let i = (try? c.decodeIfPresent(Int.self, forKey: k)) ?? nil { return String(i) }
            return nil
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.ratingKey = Context.id(c, .ratingKey)
            self.metadataID = Context.id(c, .metadataID)
            self.key = try? c.decodeIfPresent(String.self, forKey: .key)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.uuid = (try? c.decodeIfPresent(String.self, forKey: .uuid))
            ?? (try? c.decodeIfPresent(String.self, forKey: .UUID)) ?? nil
        self.type = (try? c.decodeIfPresent(String.self, forKey: .type))
            ?? (try? c.decodeIfPresent(String.self, forKey: .typeCapitalized)) ?? nil
        // progress is documented as Int but tolerate a String/Double-encoded value.
        if let p = (try? c.decodeIfPresent(Int.self, forKey: .progress)) ?? nil {
            self.progress = p
        } else if let d = (try? c.decodeIfPresent(Double.self, forKey: .progress)) ?? nil {
            self.progress = Int(d)
        } else if let s = (try? c.decodeIfPresent(String.self, forKey: .progress)) ?? nil,
                  let p = Int(s) {
            self.progress = p
        } else {
            self.progress = nil
        }
        // cancellable arrives as 0/1 (Int) or a Bool; tolerate both.
        if let b = (try? c.decodeIfPresent(Bool.self, forKey: .cancellable)) ?? nil {
            self.cancellable = b
        } else if let i = (try? c.decodeIfPresent(Int.self, forKey: .cancellable)) ?? nil {
            self.cancellable = i != 0
        } else {
            self.cancellable = nil
        }
        self.title = (try? c.decodeIfPresent(String.self, forKey: .title))
            ?? (try? c.decodeIfPresent(String.self, forKey: .Title)) ?? nil
        self.subtitle = (try? c.decodeIfPresent(String.self, forKey: .subtitle))
            ?? (try? c.decodeIfPresent(String.self, forKey: .Subtitle)) ?? nil
        let context = (try? c.decodeIfPresent(Context.self, forKey: .context)) ?? nil
        self.contextRatingKey = context?.ratingKey
        self.contextMetadataID = context?.metadataID
    }

    /// The source library id this activity is tied to, if any: `Context.ratingKey` (some
    /// PMS versions) or `Context.metadataID` (the `media.download` conversion activity).
    /// Both equal the source item's ratingKey.
    public var correlationID: String? {
        if let r = contextRatingKey, !r.isEmpty { return r }
        if let m = contextMetadataID, !m.isEmpty { return m }
        return nil
    }

    /// `true` when this activity looks like an optimize/transcode/conversion job. The real
    /// `type` is undocumented + version-dependent, so we match leniently against the known
    /// candidate strings AND any type containing "optimize".
    public var looksLikeOptimize: Bool {
        guard let t = type?.lowercased() else { return false }
        if t.contains("optimize") { return true }
        let candidates = [
            // `media.download` is the CONFIRMED type a live PMS emits for the server-side
            // conversion that backs an offline download (verified via /activities probe).
            "media.download",
            "media.optimize",
            "library.optimize",
            "media.convert",
            "provider.subscriptions.process",
            "media.generate",
        ]
        return candidates.contains { t.hasPrefix($0) || t == $0 }
    }

    /// `true` when this activity's human title/subtitle matches the **bare** media title
    /// (e.g. `"Blade Runner"`, NOT our suffixed optimize-queue title `"Blade Runner
    /// [Labstream abc12345]"` — the server activity never carries that suffix). Normalized
    /// equality first, then a containment fallback for `"Title (year)"`-style subtitles.
    /// In-memory only — the title is NEVER logged (see `PlexActivity.title` doc).
    public func matchesTitle(_ mediaTitle: String?) -> Bool {
        guard let needle = mediaTitle?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
              !needle.isEmpty else { return false }
        for field in [subtitle, title] {
            guard let f = field?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
                  !f.isEmpty else { continue }
            if f == needle || f.contains(needle) { return true }
        }
        return false
    }

    /// `true` when this activity is plausibly tied to the given ratingKey or bare media
    /// title: exact `Context.ratingKey`, else a `matchesTitle` hit. Per-activity predicate;
    /// ambiguity across multiple activities is resolved by `Activities.optimizeActivity`.
    public func matches(ratingKey: String?, title mediaTitle: String?) -> Bool {
        if let ratingKey, let id = correlationID,
           !ratingKey.isEmpty,
           id.trimmingCharacters(in: .whitespacesAndNewlines) == ratingKey.trimmingCharacters(in: .whitespacesAndNewlines) {
            return true
        }
        return matchesTitle(mediaTitle)
    }
}

/// `GET /activities` response. Lenient: the `Activity` array is omitted when empty, and
/// the whole shape may drift, so decode degrades to `[]` rather than throwing.
public struct Activities: Decodable, Sendable, Equatable {
    public let activities: [PlexActivity]

    enum RootKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
    enum ContainerKeys: String, CodingKey { case activity = "Activity" }

    public init(activities: [PlexActivity]) { self.activities = activities }

    public init(from decoder: Decoder) throws {
        guard let root = try? decoder.container(keyedBy: RootKeys.self),
              let container = try? root.nestedContainer(keyedBy: ContainerKeys.self,
                                                        forKey: .mediaContainer) else {
            self.activities = []
            return
        }
        self.activities = (try? container.decodeIfPresent([PlexActivity].self, forKey: .activity)) ?? []
    }

    /// Find the optimize/conversion activity for a given job. `title` is the **bare** media
    /// title (NOT a suffixed queue title). Conservative match chain — it never guesses when
    /// attribution would be ambiguous, so a wrong percentage is never shown for another job:
    /// 1. an optimize-typed activity whose `Context.ratingKey` == `ratingKey` (reliable);
    /// 2. else, if EXACTLY ONE optimize-typed activity matches the bare title, take it
    ///    (uniqueness guards against `"Alien"`/`"Aliens"` collisions and concurrent jobs);
    /// 3. else, ONLY when `allowSoleFallback` (caller asserts this client has a single active
    ///    optimize job) AND exactly one optimize activity is running, take it.
    /// Returns `nil` when nothing UNAMBIGUOUSLY matches (caller keeps current behavior).
    public func optimizeActivity(ratingKey: String?, title: String?,
                                 allowSoleFallback: Bool = false) -> PlexActivity? {
        let optimizers = activities.filter { $0.looksLikeOptimize }
        if let r = ratingKey?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty,
           let exact = optimizers.first(where: {
               $0.correlationID?.trimmingCharacters(in: .whitespacesAndNewlines) == r
           }) {
            return exact
        }
        if let title, !title.isEmpty {
            let titleMatches = optimizers.filter { $0.matchesTitle(title) }
            if titleMatches.count == 1 { return titleMatches.first }
        }
        if allowSoleFallback, optimizers.count == 1 { return optimizers.first }
        return nil
    }

    /// Redaction-safe shape descriptor of the raw decode for the live PMS probe.
    /// Emits ONLY structural facts (counts, field-presence flags, numeric progress,
    /// dotted types) — NEVER any `title`/`subtitle` VALUE. Safe to log.
    public func probeShape(ratingKey: String?, title: String?,
                           allowSoleFallback: Bool = false) -> [String: String] {
        let optimizers = activities.filter { $0.looksLikeOptimize }
        let match = optimizeActivity(ratingKey: ratingKey, title: title,
                                     allowSoleFallback: allowSoleFallback)
        var out: [String: String] = [
            "activity_count": String(activities.count),
            "optimize_count": String(optimizers.count),
            "types": activities.compactMap { $0.type }.joined(separator: ","),
            "matched": match == nil ? "none" : "yes",
        ]
        if let match {
            out["match_progress"] = match.progress.map(String.init) ?? "nil"
            out["match_has_uuid"] = (match.uuid != nil) ? "1" : "0"
            out["match_has_context_ratingkey"] = (match.contextRatingKey != nil) ? "1" : "0"
            out["match_has_metadata_id"] = (match.contextMetadataID != nil) ? "1" : "0"
            if let r = ratingKey?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty,
               let c = match.correlationID?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty {
                out["match_correlation_equal"] = (r == c) ? "1" : "0"
            }
            out["match_has_title"] = (match.title != nil) ? "1" : "0"
            out["match_has_subtitle"] = (match.subtitle != nil) ? "1" : "0"
            out["match_cancellable"] = match.cancellable.map { $0 ? "1" : "0" } ?? "nil"
        }
        return out
    }
}
