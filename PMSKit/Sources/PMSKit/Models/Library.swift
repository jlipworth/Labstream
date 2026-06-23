import Foundation

// MARK: - Library sections (`/library/sections`)

public struct SectionsResponse: Decodable, Sendable {
    public let mediaContainer: Container
    enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }

    public struct Container: Decodable, Sendable {
        public let size: Int?
        public let directory: [Section]
        enum CodingKeys: String, CodingKey {
            case size
            case directory = "Directory"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.size = try c.decodeIfPresent(Int.self, forKey: .size)
            // Empty/no-access library responses can omit Directory entirely.
            self.directory = try c.decodeIfPresent([Section].self, forKey: .directory) ?? []
        }
    }
}

public struct Section: Decodable, Sendable, Identifiable {
    public let key: String
    public let title: String
    public let type: String
    public var id: String { key }

    /// True for music libraries (Plex uses the "artist" section type). The app hides
    /// these until a dedicated Plexamp-style music experience exists (issue #15).
    public var isMusic: Bool { type == "artist" }

    public init(key: String, title: String, type: String) {
        self.key = key
        self.title = title
        self.type = type
    }
}

// MARK: - Metadata (`/library/metadata/<id>`, section items)

public struct MetadataResponse: Decodable, Sendable {
    public let mediaContainer: Container
    enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }

    public struct Container: Decodable, Sendable {
        public let size: Int?
        /// Full result count across ALL pages of a paged listing (PMS `totalSize`,
        /// present when the request was paged with `X-Plex-Container-Start/-Size`).
        /// Lets a grid pre-size its scroll range to the whole library.
        public let totalSize: Int?
        public let metadata: [MediaItem]
        enum CodingKeys: String, CodingKey {
            case size
            case totalSize
            case metadata = "Metadata"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.size = try c.decodeIfPresent(Int.self, forKey: .size)
            self.totalSize = try c.decodeIfPresent(Int.self, forKey: .totalSize)
            // `Metadata` may be absent (e.g. an empty container); treat as [].
            // Decode LOSSILY, element by element: some endpoints mix in rows that
            // don't fit `MediaItem` — `/status/sessions/history/all` keeps entries
            // for since-DELETED items with no `ratingKey` — and an all-or-nothing
            // array decode would let one such row throw away the whole response.
            guard c.contains(.metadata) else { self.metadata = []; return }
            var rows = try c.nestedUnkeyedContainer(forKey: .metadata)
            var items: [MediaItem] = []
            while !rows.isAtEnd {
                if let item = try? rows.decode(MediaItem.self) {
                    items.append(item)
                } else if (try? rows.decode(OpaqueRow.self)) == nil {
                    // Skipping requires decoding *something* to advance the index;
                    // if even an opaque object won't decode, bail with what we have
                    // rather than spin (a failed decode does not consume the row).
                    break
                }
            }
            self.metadata = items
        }
    }
}

/// Consumes one arbitrary element of an unkeyed container so lossy array decodes
/// can advance past rows that don't fit the expected model.
private struct OpaqueRow: Decodable {}

public struct MediaItem: Decodable, Sendable, Identifiable {
    public let ratingKey: String
    public let key: String?
    public let title: String
    public let type: String
    public let duration: Int?
    public let viewOffset: Int?
    public let viewCount: Int?
    public let year: Int?
    public let summary: String?
    public let thumb: String?
    public let art: String?
    public let media: [Media]?
    public let librarySectionID: Int?
    public let librarySectionKey: String?
    /// Chapter markers, when PMS provides them (`Chapter` elements on the metadata).
    /// Absent for most items; the player hides chapter UI when this is empty/nil so the
    /// control degrades gracefully.
    public let chapters: [Chapter]?
    /// Intro/credits/commercial markers (`Marker` elements), when PMS provides them
    /// (`includeMarkers=1`). Drives Skip Intro / Skip Credits. Absent for most items.
    public let markers: [Marker]?

    /// Critic/aggregate rating on a 0–10 scale (PMS `rating`). The DetailView renders it
    /// as e.g. "7.8" next to a star glyph. `nil` for items PMS doesn't rate.
    public let rating: Double?
    /// Content/age rating string (PMS `contentRating`), e.g. "PG-13", "TV-MA". Surfaced
    /// as a small capsule on the detail header so the viewer sees the certification.
    public let contentRating: String?
    /// One-line tagline (PMS `tagline`), shown under the title when present.
    public let tagline: String?
    /// Genre tags (`Genre` elements). Joined into a comma list on the detail header.
    /// Empty/nil when the item carries no genres.
    public let genres: [Tag]?

    // MARK: - Extended metadata (#76 — cast/studios/critic rating, title logo)

    /// Separate backend-supplied critic/aggregate rating where available. Jellyfin/Emby
    /// expose this as `CriticRating`; Plex `audienceRating` is an audience score, not a
    /// critic score, so the Plex decoder deliberately leaves this nil.
    public let criticRating: Double?
    /// Cast (`Role` on Plex, `People` of type Actor on Jellyfin/Emby). Surfaced as a
    /// "Cast" line on the detail header. Empty/nil when absent.
    public let roles: [Tag]?
    /// Directors (`Director` on Plex, `People` of type Director on Jellyfin/Emby).
    public let directors: [Tag]?
    /// Production studios (`Country`/`Studio` on Plex, `Studios` on Jellyfin/Emby).
    public let studios: [Tag]?
    /// Title/clear-logo artwork key, when the backend exposes one (Plex `Image` of type
    /// `clearLogo`; Jellyfin/Emby `Logo`). Drives an optional title-art overlay. `nil` for
    /// items with no logo.
    public let logo: String?

    // MARK: - TV hierarchy (show → season → episode)
    //
    // PMS decorates an *episode* with its season (`parent…`) and show (`grandparent…`)
    // context, and a *season* with its show context. These let an episode row read like
    // "{grandparentTitle} · S{parentIndex}E{index} · {title}" and let the UI drill the
    // hierarchy / resolve the correct leaf ratingKey to play/download. All optional —
    // a `movie` carries none of them and they decode to `nil`.

    /// Show title for an episode/season (PMS `grandparentTitle`), e.g. "Breaking Bad".
    public let grandparentTitle: String?
    /// Show ratingKey for an episode/season (PMS `grandparentRatingKey`).
    public let grandparentRatingKey: String?
    /// Show artwork key for an episode/season (PMS `grandparentThumb`).
    public let grandparentThumb: String?
    /// Season title for an episode (PMS `parentTitle`), e.g. "Season 1".
    public let parentTitle: String?
    /// Season ratingKey for an episode (PMS `parentRatingKey`).
    public let parentRatingKey: String?
    /// Season artwork key for an episode (PMS `parentThumb`).
    public let parentThumb: String?
    /// Season number — `parentIndex` on an episode, and the season's own number on a
    /// `season` item.
    public let parentIndex: Int?
    /// Episode number within its season (PMS `index`); also the season number on a
    /// `season` item.
    public let index: Int?

    // MARK: - Music fields (all optional; absent on video items)

    /// Per-track artist override on compilation albums (PMS `originalTitle`) —
    /// the actual performer when `grandparentTitle` is "Various Artists".
    public let originalTitle: String?
    /// Epoch seconds of the last play (PMS `lastViewedAt`). Drives Recently Played.
    public let lastViewedAt: Int?
    /// Album release year on a track (PMS `parentYear`).
    public let parentYear: Int?
    /// Aggregate rating count (PMS `ratingCount`) — the popularity signal behind
    /// an artist's Popular tracks.
    public let ratingCount: Int?
    /// Playlist mosaic artwork path (PMS `composite`, e.g.
    /// `/playlists/{rk}/composite/{ts}`). Playlists carry no `thumb` of their own.
    public let composite: String?
    /// Number of leaf items in a container (PMS `leafCount`) — on a playlist,
    /// its track count ("N tracks" in the pivot rows).
    public let leafCount: Int?
    /// Playlist flavor (PMS `playlistType`: `audio` / `video` / `photo`). Routing
    /// uses it to keep video playlists OUT of the music module.
    public let playlistType: String?
    /// Primary-image aspect ratio (width / height) reported by the backend, when known.
    /// Jellyfin/Emby expose this as `PrimaryImageAspectRatio` (e.g. ~1.778 for 16:9 YouTube
    /// art, ~1.0 for square channel art, ~0.667 for a 2:3 movie poster); Plex does not, so
    /// it decodes nil there. Poster rendering falls back to the canonical 2:3 when nil. See
    /// GH #101.
    public let primaryImageAspectRatio: Double?

    // MARK: - Movie-version grouping (#108)

    /// Selectable alternate versions of the SAME logical movie, when the library grid
    /// collapsed several distinct backend items (one per physical file/edition, distinct
    /// `ratingKey` but identical title/year/art) into one tile. The representative tile
    /// carries the full ordered group here (including itself); the detail screen offers a
    /// version chooser and plays the chosen entry's `ratingKey`. `nil` for ordinary items
    /// with a single version — this is NOT decoded from any backend payload (it is a purely
    /// client-side, UI-layer grouping carrier), so it stays out of `CodingKeys` and the
    /// decoder, and defaults to `nil` everywhere else.
    public let versions: [MediaItem]?

    /// Backend external-provider ids (`ProviderIds` on Jellyfin/Emby, e.g.
    /// `{"Tmdb": "603", "Imdb": "tt0133093"}`), used to robustly identify the SAME logical
    /// movie across distinct backend file/edition items for grid de-dup (#108). Lets the
    /// collapser key on a real cross-edition identity (`tmdb:603`) instead of the fragile
    /// `title|year`, so it neither false-merges different films sharing a title+year nor
    /// mass-collapses year-less same-title items. `nil` for Plex (and for any item whose
    /// payload omits it). This is NOT a required `CodingKeys` entry — the decoder leaves it
    /// `nil` when absent so existing fixtures/tests decode unchanged; Jellyfin/Emby populate
    /// it via the synthetic mapper in `MediaBrowserBaseItemDto.toMediaItem()`.
    public let providerIds: [String: String]?

    public var id: String { ratingKey }

    enum CodingKeys: String, CodingKey {
        case ratingKey
        case key
        case title
        case type
        case duration
        case viewOffset
        case viewCount
        case year
        case summary
        case thumb
        case art
        case media = "Media"
        case librarySectionID
        case librarySectionKey
        case chapters = "Chapter"
        case markers = "Marker"
        case rating
        case contentRating
        case tagline
        case genres = "Genre"
        case criticRating
        case roles = "Role"
        case directors = "Director"
        case studios = "Country"
        case logo
        case images = "Image"
        case grandparentTitle
        case grandparentRatingKey
        case grandparentThumb
        case parentTitle
        case parentRatingKey
        case parentThumb
        case parentIndex
        case index
        case originalTitle
        case lastViewedAt
        case parentYear
        case ratingCount
        case composite
        case leafCount
        case playlistType
        case primaryImageAspectRatio
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ratingKey = try c.decode(String.self, forKey: .ratingKey)
        key = try c.decodeIfPresent(String.self, forKey: .key)
        title = try c.decode(String.self, forKey: .title)
        type = try c.decode(String.self, forKey: .type)
        duration = try c.decodeIfPresent(Int.self, forKey: .duration)
        viewOffset = try c.decodeIfPresent(Int.self, forKey: .viewOffset)
        viewCount = try c.decodeIfPresent(Int.self, forKey: .viewCount)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        thumb = try c.decodeIfPresent(String.self, forKey: .thumb)
        art = try c.decodeIfPresent(String.self, forKey: .art)
        media = try c.decodeIfPresent([Media].self, forKey: .media)
        librarySectionID = try c.decodeIfPresent(Int.self, forKey: .librarySectionID)
        librarySectionKey = try c.decodeIfPresent(String.self, forKey: .librarySectionKey)
        chapters = try c.decodeIfPresent([Chapter].self, forKey: .chapters)
        markers = try c.decodeIfPresent([Marker].self, forKey: .markers)
        rating = try c.decodeIfPresent(Double.self, forKey: .rating)
        contentRating = try c.decodeIfPresent(String.self, forKey: .contentRating)
        tagline = try c.decodeIfPresent(String.self, forKey: .tagline)
        genres = try c.decodeIfPresent([Tag].self, forKey: .genres)
        // Plex does not expose a same-semantics top-level critic field in the payloads we use.
        // Do NOT map `audienceRating` here: that produced bogus orange critic badges on Plex
        // detail pages (for example an audience score of 36 rendering as `36.0`).
        criticRating = try c.decodeIfPresent(Double.self, forKey: .criticRating)
        roles = try c.decodeIfPresent([Tag].self, forKey: .roles)
        directors = try c.decodeIfPresent([Tag].self, forKey: .directors)
        studios = try c.decodeIfPresent([Tag].self, forKey: .studios)
        // Plex exposes a clear/title logo only as one entry in the `Image` array
        // (`{ alt, type: "clearLogo", url }`); there is no top-level `logo` key. Prefer a
        // literal `logo` if a backend ever sends one, else lift the clearLogo URL.
        if let direct = try c.decodeIfPresent(String.self, forKey: .logo) {
            logo = direct
        } else {
            let images = try c.decodeIfPresent([PlexImage].self, forKey: .images) ?? []
            logo = images.first { $0.type == "clearLogo" }?.url
        }
        grandparentTitle = try c.decodeIfPresent(String.self, forKey: .grandparentTitle)
        grandparentRatingKey = try c.decodeIfPresent(String.self, forKey: .grandparentRatingKey)
        grandparentThumb = try c.decodeIfPresent(String.self, forKey: .grandparentThumb)
        parentTitle = try c.decodeIfPresent(String.self, forKey: .parentTitle)
        parentRatingKey = try c.decodeIfPresent(String.self, forKey: .parentRatingKey)
        parentThumb = try c.decodeIfPresent(String.self, forKey: .parentThumb)
        parentIndex = try c.decodeIfPresent(Int.self, forKey: .parentIndex)
        index = try c.decodeIfPresent(Int.self, forKey: .index)
        originalTitle = try c.decodeIfPresent(String.self, forKey: .originalTitle)
        lastViewedAt = try c.decodeIfPresent(Int.self, forKey: .lastViewedAt)
        parentYear = try c.decodeIfPresent(Int.self, forKey: .parentYear)
        ratingCount = try c.decodeIfPresent(Int.self, forKey: .ratingCount)
        composite = try c.decodeIfPresent(String.self, forKey: .composite)
        leafCount = try c.decodeIfPresent(Int.self, forKey: .leafCount)
        playlistType = try c.decodeIfPresent(String.self, forKey: .playlistType)
        // Plex payloads omit this key (→ nil → 2:3 fallback); Jellyfin/Emby supply it via
        // the synthetic mapper in MediaBrowserBaseItemDto.toMediaItem(). See GH #101.
        primaryImageAspectRatio = try c.decodeIfPresent(Double.self, forKey: .primaryImageAspectRatio)
        // `versions` is a client-side movie-grid grouping carrier (#108), never on the wire.
        versions = nil
        // `providerIds` is intentionally absent from `CodingKeys`: Plex payloads (and any
        // existing JSON fixture) don't carry it, so the decoder defaults it to nil and all
        // prior decoding behavior is preserved. Jellyfin/Emby fill it via `toMediaItem()`.
        providerIds = nil
    }

    public init(ratingKey: String,
                key: String? = nil,
                title: String,
                type: String,
                duration: Int? = nil,
                viewOffset: Int? = nil,
                viewCount: Int? = nil,
                year: Int? = nil,
                summary: String? = nil,
                thumb: String? = nil,
                art: String? = nil,
                media: [Media]? = nil,
                librarySectionID: Int? = nil,
                librarySectionKey: String? = nil,
                chapters: [Chapter]? = nil,
                markers: [Marker]? = nil,
                rating: Double? = nil,
                contentRating: String? = nil,
                tagline: String? = nil,
                genres: [Tag]? = nil,
                criticRating: Double? = nil,
                roles: [Tag]? = nil,
                directors: [Tag]? = nil,
                studios: [Tag]? = nil,
                logo: String? = nil,
                grandparentTitle: String? = nil,
                grandparentRatingKey: String? = nil,
                grandparentThumb: String? = nil,
                parentTitle: String? = nil,
                parentRatingKey: String? = nil,
                parentThumb: String? = nil,
                parentIndex: Int? = nil,
                index: Int? = nil,
                originalTitle: String? = nil,
                lastViewedAt: Int? = nil,
                parentYear: Int? = nil,
                ratingCount: Int? = nil,
                composite: String? = nil,
                leafCount: Int? = nil,
                playlistType: String? = nil,
                primaryImageAspectRatio: Double? = nil,
                versions: [MediaItem]? = nil,
                providerIds: [String: String]? = nil) {
        self.ratingKey = ratingKey
        self.key = key
        self.title = title
        self.type = type
        self.duration = duration
        self.viewOffset = viewOffset
        self.viewCount = viewCount
        self.year = year
        self.summary = summary
        self.thumb = thumb
        self.art = art
        self.media = media
        self.librarySectionID = librarySectionID
        self.librarySectionKey = librarySectionKey
        self.chapters = chapters
        self.markers = markers
        self.rating = rating
        self.contentRating = contentRating
        self.tagline = tagline
        self.genres = genres
        self.criticRating = criticRating
        self.roles = roles
        self.directors = directors
        self.studios = studios
        self.logo = logo
        self.grandparentTitle = grandparentTitle
        self.grandparentRatingKey = grandparentRatingKey
        self.grandparentThumb = grandparentThumb
        self.parentTitle = parentTitle
        self.parentRatingKey = parentRatingKey
        self.parentThumb = parentThumb
        self.parentIndex = parentIndex
        self.index = index
        self.originalTitle = originalTitle
        self.lastViewedAt = lastViewedAt
        self.parentYear = parentYear
        self.ratingCount = ratingCount
        self.composite = composite
        self.leafCount = leafCount
        self.playlistType = playlistType
        self.primaryImageAspectRatio = primaryImageAspectRatio
        self.versions = versions
        self.providerIds = providerIds
    }

    /// Return a copy of `self` carrying `versions` as its selectable movie-version group
    /// (#108), every other field preserved verbatim. Centralizing the copy here — next to
    /// the memberwise init — means a future `MediaItem` field is preserved automatically
    /// instead of being silently dropped by a hand-maintained field-by-field copy at the
    /// call site (finding 9). Used by the grid collapser on the surviving representative tile.
    public func with(versions: [MediaItem]?) -> MediaItem {
        MediaItem(ratingKey: ratingKey, key: key, title: title, type: type,
                  duration: duration, viewOffset: viewOffset, viewCount: viewCount,
                  year: year, summary: summary, thumb: thumb, art: art, media: media,
                  librarySectionID: librarySectionID, librarySectionKey: librarySectionKey,
                  chapters: chapters, markers: markers, rating: rating,
                  contentRating: contentRating, tagline: tagline, genres: genres,
                  criticRating: criticRating, roles: roles, directors: directors,
                  studios: studios, logo: logo,
                  grandparentTitle: grandparentTitle, grandparentRatingKey: grandparentRatingKey,
                  grandparentThumb: grandparentThumb, parentTitle: parentTitle,
                  parentRatingKey: parentRatingKey, parentThumb: parentThumb,
                  parentIndex: parentIndex, index: index, originalTitle: originalTitle,
                  lastViewedAt: lastViewedAt, parentYear: parentYear,
                  ratingCount: ratingCount, composite: composite, leafCount: leafCount,
                  playlistType: playlistType,
                  primaryImageAspectRatio: primaryImageAspectRatio,
                  versions: versions,
                  providerIds: providerIds)
    }
}

/// A Plex `Image` child element (`{ alt, type, url }`). Plex carries clear/title logos
/// only here (type `clearLogo`); we lift the matching `url` into `MediaItem.logo`. (#76)
struct PlexImage: Decodable, Sendable {
    let alt: String?
    let type: String?
    let url: String?
}

/// A simple Plex tag element (`Genre`, `Director`, `Role`, …). PMS represents each as a
/// `<Genre tag="Action"/>`-style child; we only need the human `tag` for display.
public struct Tag: Decodable, Sendable, Identifiable, Hashable {
    public let tag: String
    public var id: String { tag }

    enum CodingKeys: String, CodingKey { case tag }

    public init(tag: String) { self.tag = tag }
}

/// One chapter marker on a `MediaItem`.
///
/// PMS emits `Chapter` elements with millisecond `startTimeOffset`/`endTimeOffset`
/// boundaries and an optional human `tag` (e.g. "Chapter 1").
///
/// NOTE: visionOS's AVKit does NOT expose `AVNavigationMarkersGroup` /
/// `AVPlayerItem.navigationMarkerGroups` (those are tvOS/iOS only), so there are no
/// native scrubber chapter ticks here. Instead the player surfaces these chapters via a
/// custom "Chapters" info-panel tab whose rows seek the `AVPlayer` playhead directly to
/// each chapter's `startTimeOffset`.
public struct Chapter: Decodable, Sendable, Identifiable {
    /// PMS chapter id, when present. Real PMS data is unreliable here — container-derived
    /// chapters frequently OMIT this or repeat a single value (e.g. `0`) across every
    /// chapter, so it is NOT safe as a list identity. Use the synthesized `id` for that.
    /// (Mirrors `Marker.markerID`, which hit the same PMS quirk.)
    public let chapterID: Int?
    public let tag: String?
    /// Chapter start, in milliseconds from the start of the item.
    public let startTimeOffset: Int?
    /// Chapter end, in milliseconds from the start of the item.
    public let endTimeOffset: Int?
    /// A thumbnail key for the chapter card, when present.
    public let thumb: String?

    /// Stable, UNIQUE identity for SwiftUI lists. We key on `startTimeOffset` — chapters are
    /// strictly ordered and never share a start — because PMS `id` is often missing or a
    /// repeated `0`, which collapses a `ForEach(id: \.id)` into N copies of the first row
    /// (the "every chapter shows Chapter 1 / 0:00" bug). Falls back to the raw id, then end.
    public var id: String {
        if let startTimeOffset { return "start-\(startTimeOffset)" }
        if let chapterID { return "id-\(chapterID)" }
        return "end-\(endTimeOffset ?? -1)"
    }

    enum CodingKeys: String, CodingKey {
        case chapterID = "id"
        case tag
        case startTimeOffset
        case endTimeOffset
        case thumb
    }

    public init(id: Int? = nil,
                tag: String? = nil,
                startTimeOffset: Int? = nil,
                endTimeOffset: Int? = nil,
                thumb: String? = nil) {
        self.chapterID = id
        self.tag = tag
        self.startTimeOffset = startTimeOffset
        self.endTimeOffset = endTimeOffset
        self.thumb = thumb
    }
}

public extension Array where Element == Chapter {
    /// Index of the chapter the playhead `ms` (milliseconds) currently sits in:
    /// the last chapter (by position) whose `startTimeOffset <= ms`, independent
    /// of ordering. Returns `nil` when there are no chapters or `ms` precedes the
    /// first chapter's start. Chapters with a `nil` start are skipped.
    /// `endTimeOffset` is intentionally not used — PMS data for it is unreliable.
    func indexOfChapter(at ms: Int) -> Int? {
        var match: Int?
        for (index, chapter) in enumerated() {
            guard let start = chapter.startTimeOffset else { continue }
            if start <= ms { match = index }
        }
        return match
    }
}

/// The kind of a PMS `Marker` element, derived from its string `type`.
public enum MarkerType: Sendable, Equatable {
    case intro
    case credits
    case commercial
    /// Any marker type PMS may add that we don't model explicitly.
    case other(String)

    init(rawValue: String) {
        switch rawValue {
        case "intro": self = .intro
        case "credits": self = .credits
        case "commercial": self = .commercial
        default: self = .other(rawValue)
        }
    }
}

/// One PMS `Marker` element on a `MediaItem` — an intro/credits/commercial range
/// used to power Skip Intro / Skip Credits affordances.
///
/// Present only when the metadata request asks for `includeMarkers=1`. Offsets are
/// in milliseconds from the start of the item. The `final` flag (on credits markers)
/// indicates the credits run to the end of the item.
public struct Marker: Decodable, Sendable, Identifiable {
    /// PMS marker id, when present.
    public let markerID: Int?
    /// Raw PMS marker type string, e.g. "intro" | "credits" | "commercial". Prefer `kind`.
    public let type: String
    /// Marker start, in milliseconds from the start of the item.
    public let startTimeOffset: Int?
    /// Marker end, in milliseconds from the start of the item.
    public let endTimeOffset: Int?
    /// PMS `final` flag (on credits markers) — the marker runs to the item's end.
    /// Decoded from the JSON `final` key (a Swift keyword) via `CodingKeys`.
    public let isFinal: Bool?

    /// Stable identity: PMS `id` when present, else a synthesized type+offset key.
    public var id: String {
        if let markerID { return String(markerID) }
        return "\(type)-\(startTimeOffset ?? -1)"
    }

    /// Strongly-typed marker kind.
    public var kind: MarkerType { MarkerType(rawValue: type) }

    enum CodingKeys: String, CodingKey {
        case markerID = "id"
        case type
        case startTimeOffset
        case endTimeOffset
        case isFinal = "final"
    }

    public init(id: Int? = nil,
                type: String,
                startTimeOffset: Int? = nil,
                endTimeOffset: Int? = nil,
                isFinal: Bool? = nil) {
        self.markerID = id
        self.type = type
        self.startTimeOffset = startTimeOffset
        self.endTimeOffset = endTimeOffset
        self.isFinal = isFinal
    }
}

public struct Media: Decodable, Sendable, Identifiable {
    public let id: Int
    public let duration: Int?
    public let bitrate: Int?
    public let width: Int?
    public let height: Int?
    public let videoCodec: String?
    public let audioCodec: String?
    public let container: String?
    public let part: [Part]

    enum CodingKeys: String, CodingKey {
        case id
        case duration
        case bitrate
        case width
        case height
        case videoCodec
        case audioCodec
        case container
        case part = "Part"
    }

    public init(id: Int,
                duration: Int? = nil,
                bitrate: Int? = nil,
                width: Int? = nil,
                height: Int? = nil,
                videoCodec: String? = nil,
                audioCodec: String? = nil,
                container: String? = nil,
                part: [Part]) {
        self.id = id
        self.duration = duration
        self.bitrate = bitrate
        self.width = width
        self.height = height
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.container = container
        self.part = part
    }
}

public struct Part: Decodable, Sendable, Identifiable {
    public let id: Int
    public let key: String
    public let duration: Int?
    public let file: String?
    public let size: Int?
    public let container: String?
    /// Plex `Part.indexes` advertises trick-play indexes such as `sd` when a BIF endpoint is available.
    public let indexes: String?
    /// Per-part media tracks (`Stream` elements): video, audio and subtitle tracks.
    /// PMS only emits these on full metadata requests (and often only the selected
    /// streams unless `includeStreams`/extended params are sent), so this is optional
    /// and lenient. Use the `audioStreams`/`subtitleStreams`/`videoStreams` accessors
    /// to filter by kind for the player's track-selection UI.
    public let streams: [Stream]?

    enum CodingKeys: String, CodingKey {
        case id
        case key
        case duration
        case file
        case size
        case container
        case indexes
        case streams = "Stream"
    }

    public init(id: Int,
                key: String,
                duration: Int? = nil,
                file: String? = nil,
                size: Int? = nil,
                container: String? = nil,
                indexes: String? = nil,
                streams: [Stream]? = nil) {
        self.id = id
        self.key = key
        self.duration = duration
        self.file = file
        self.size = size
        self.container = container
        self.indexes = indexes
        self.streams = streams
    }

    /// Video tracks on this part (`streamType == 1`), in PMS order.
    public var videoStreams: [Stream] { (streams ?? []).filter { $0.kind == .video } }
    /// Audio tracks on this part (`streamType == 2`), in PMS order.
    public var audioStreams: [Stream] { (streams ?? []).filter { $0.kind == .audio } }
    /// Subtitle tracks on this part (`streamType == 3`), in PMS order.
    public var subtitleStreams: [Stream] { (streams ?? []).filter { $0.kind == .subtitle } }

    /// True when Plex says `/library/parts/{id}/indexes/sd` should be available.
    public var hasStandardDefinitionBIFIndex: Bool {
        guard let indexes else { return false }
        return indexes
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .contains("sd")
    }
}

/// The kind of a media `Stream`, derived from PMS's numeric `streamType`.
public enum StreamType: Int, Sendable, Equatable {
    case video = 1
    case audio = 2
    case subtitle = 3
}

/// One media track inside a `Part` (`Stream` element): a video, audio or subtitle
/// track. PMS attaches many optional attributes depending on the request and the
/// track kind, so every field beyond `id`/`streamType` is optional and lenient.
public struct Stream: Decodable, Sendable, Identifiable {
    public let id: Int
    /// Raw PMS stream type: 1=video, 2=audio, 3=subtitle. Prefer `kind`.
    public let streamType: Int
    /// Track index within its kind, when PMS supplies it.
    public let index: Int?
    public let codec: String?
    /// Human language name, e.g. "English".
    public let language: String?
    /// BCP-47-ish language tag, e.g. "en".
    public let languageTag: String?
    /// ISO language code, e.g. "eng".
    public let languageCode: String?
    /// Backend-relative stream URL/key for externally stored streams such as sidecar subtitles.
    public let key: String?
    /// Short display label, e.g. "English (AAC Stereo)".
    public let displayTitle: String?
    /// Longer display label including codec/channel detail.
    public let extendedDisplayTitle: String?
    /// Whether this track is currently selected on the source. PMS sends this only
    /// for the active audio/subtitle track.
    public let selected: Bool?
    /// Whether this is the container's default track. Decoded from the JSON `default`
    /// key (a Swift keyword) via `CodingKeys`.
    public let isDefault: Bool?
    /// Whether this is a forced subtitle track.
    public let forced: Bool?
    /// Audio channel count (audio tracks only).
    public let channels: Int?
    /// Free-form track title, when present.
    public let title: String?

    /// Strongly-typed kind, or `nil` for an unrecognised `streamType`.
    public var kind: StreamType? { StreamType(rawValue: streamType) }

    enum CodingKeys: String, CodingKey {
        case id
        case streamType
        case index
        case codec
        case language
        case languageTag
        case languageCode
        case key
        case displayTitle
        case extendedDisplayTitle
        case selected
        case isDefault = "default"
        case forced
        case channels
        case title
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(Int.self, forKey: .id)
        self.streamType = try c.decode(Int.self, forKey: .streamType)
        self.index = try c.decodeIfPresent(Int.self, forKey: .index)
        self.codec = try c.decodeIfPresent(String.self, forKey: .codec)
        self.language = try c.decodeIfPresent(String.self, forKey: .language)
        self.languageTag = try c.decodeIfPresent(String.self, forKey: .languageTag)
        self.languageCode = try c.decodeIfPresent(String.self, forKey: .languageCode)
        self.key = try c.decodeIfPresent(String.self, forKey: .key)
        self.displayTitle = try c.decodeIfPresent(String.self, forKey: .displayTitle)
        self.extendedDisplayTitle = try c.decodeIfPresent(String.self, forKey: .extendedDisplayTitle)
        self.selected = try c.decodeIfPresent(Bool.self, forKey: .selected)
        self.isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault)
        self.forced = try c.decodeIfPresent(Bool.self, forKey: .forced)
        self.channels = try c.decodeIfPresent(Int.self, forKey: .channels)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
    }

    public init(id: Int,
                streamType: Int,
                index: Int? = nil,
                codec: String? = nil,
                language: String? = nil,
                languageTag: String? = nil,
                languageCode: String? = nil,
                key: String? = nil,
                displayTitle: String? = nil,
                extendedDisplayTitle: String? = nil,
                selected: Bool? = nil,
                isDefault: Bool? = nil,
                forced: Bool? = nil,
                channels: Int? = nil,
                title: String? = nil) {
        self.id = id
        self.streamType = streamType
        self.index = index
        self.codec = codec
        self.language = language
        self.languageTag = languageTag
        self.languageCode = languageCode
        self.key = key
        self.displayTitle = displayTitle
        self.extendedDisplayTitle = extendedDisplayTitle
        self.selected = selected
        self.isDefault = isDefault
        self.forced = forced
        self.channels = channels
        self.title = title
    }
}

// MARK: - Hubs (`/hubs`, `/hubs/search`)

public struct HubsResponse: Decodable, Sendable {
    public let mediaContainer: Container
    enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }

    public struct Container: Decodable, Sendable {
        public let size: Int?
        public let hub: [Hub]
        enum CodingKeys: String, CodingKey {
            case size
            case hub = "Hub"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.size = try c.decodeIfPresent(Int.self, forKey: .size)
            self.hub = try c.decodeIfPresent([Hub].self, forKey: .hub) ?? []
        }
    }
}

public struct Hub: Decodable, Sendable, Identifiable {
    public let hubKey: String?
    public let key: String?
    public let title: String
    public let type: String?
    public let hubIdentifier: String?
    public let size: Int?
    public let metadata: [MediaItem]

    public var id: String { hubIdentifier ?? hubKey ?? key ?? title }

    enum CodingKeys: String, CodingKey {
        case hubKey
        case key
        case title
        case type
        case hubIdentifier
        case size
        case metadata = "Metadata"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.hubKey = try c.decodeIfPresent(String.self, forKey: .hubKey)
        self.key = try c.decodeIfPresent(String.self, forKey: .key)
        self.title = try c.decode(String.self, forKey: .title)
        self.type = try c.decodeIfPresent(String.self, forKey: .type)
        self.hubIdentifier = try c.decodeIfPresent(String.self, forKey: .hubIdentifier)
        self.size = try c.decodeIfPresent(Int.self, forKey: .size)
        self.metadata = try c.decodeIfPresent([MediaItem].self, forKey: .metadata) ?? []
    }

    public init(hubKey: String? = nil,
                key: String? = nil,
                title: String,
                type: String? = nil,
                hubIdentifier: String? = nil,
                size: Int? = nil,
                metadata: [MediaItem] = []) {
        self.hubKey = hubKey
        self.key = key
        self.title = title
        self.type = type
        self.hubIdentifier = hubIdentifier
        self.size = size
        self.metadata = metadata
    }
}
