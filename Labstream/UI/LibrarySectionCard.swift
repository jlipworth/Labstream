import SwiftUI
import PMSKit

/// One Libraries-menu tile, shared by Plex, Jellyfin, and Emby (GH #94).
///
/// The Libraries menu used to render two different presentations — a `List` of
/// labelled rows for Plex versus a `LazyVGrid` of material cards for Jellyfin/Emby —
/// which made the same screen look like a different app per backend. All three section
/// models carry the same display signal (a title plus a type/`collectionType`), so the
/// menu is now one card grid fed by this single component. Backend differences are
/// confined to the per-backend `kind` mapping (`LibrarySectionKind`), not the layout.
struct LibrarySectionCard: View {
    let title: String
    let kind: LibrarySectionKind

    @Environment(\.labstreamCompactWidth) private var compactWidth

    /// Icon tile side: the 76-pt visionOS/iPad tile makes a phone list row look like a
    /// kiosk button, so compact width uses a standard-list-scale 56-pt tile.
    private var tileSide: CGFloat {
        #if os(tvOS)
        96
        #else
        compactWidth ? 56 : 76
        #endif
    }

    var body: some View {
        HStack(spacing: cardSpacing) {
            ZStack {
                RoundedRectangle(cornerRadius: compactWidth ? DS.Radius.chip + 4 : DS.Radius.card,
                                 style: .continuous)
                    .fill(.tint.opacity(0.18))
                Image(systemName: kind.systemImage)
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            .frame(width: tileSide, height: tileSide)

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(title)
                    .font(titleFont)
                    .lineLimit(1)
                Text(kind.subtitle)
                    .font(subtitleFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(cardPadding)
        // Rigid 300pt on regular width (see the #124 note at the grid); compact width
        // stretches the card to the single full-width column instead.
        .frame(maxWidth: compactWidth ? .infinity : nil, alignment: .leading)
        .frame(width: cardWidth, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
        )
        .posterHover()
    }

    private var cardSpacing: CGFloat {
        #if os(tvOS)
        24
        #else
        DS.Space.lg
        #endif
    }

    private var iconSize: CGFloat {
        #if os(tvOS)
        42
        #else
        compactWidth ? 25 : 34
        #endif
    }

    private var titleFont: Font {
        #if os(tvOS)
        .title2.weight(.semibold)
        #else
        .title3.weight(.semibold)
        #endif
    }

    private var subtitleFont: Font {
        #if os(tvOS)
        .body
        #else
        .callout
        #endif
    }

    private var cardPadding: CGFloat {
        #if os(tvOS)
        24
        #else
        compactWidth ? DS.Space.md : DS.Space.lg
        #endif
    }

    private var cardWidth: CGFloat? {
        #if os(tvOS)
        440
        #else
        compactWidth ? nil : 300
        #endif
    }
}

/// The backend-agnostic library kind that drives a `LibrarySectionCard`'s icon and
/// subtitle. Plex `Section.type` and Jellyfin/Emby `collectionType` both map here, so
/// the card never branches on backend.
enum LibrarySectionKind: Hashable {
    case movies
    case tvShows
    case music
    case collections
    case homeVideos
    case liveTV
    case photos
    case folders
    case other

    /// Maps a Jellyfin/Emby `collectionType` (e.g. "movies", "tvshows").
    init(collectionType: String?) {
        switch collectionType?.lowercased() {
        case "movies": self = .movies
        case "tvshows": self = .tvShows
        case "music": self = .music
        case "boxsets": self = .collections
        case "homevideos": self = .homeVideos
        case "livetv": self = .liveTV
        case "photos": self = .photos
        case "folders": self = .folders
        default: self = .other
        }
    }

    /// Maps a Plex `Section.type` (e.g. "movie", "show", "artist", "photo").
    init(plexType: String) {
        switch plexType {
        case "movie": self = .movies
        case "show": self = .tvShows
        case "artist": self = .music
        case "photo": self = .photos
        default: self = .other
        }
    }

    /// Lower-cased token matching `LibraryVisibility.noiseKinds` (#104), so the first-run
    /// picker's noise pre-selection shares one vocabulary with this enum.
    var visibilityKindToken: String {
        switch self {
        case .movies: return "movies"
        case .tvShows: return "tvshows"
        case .music: return "music"
        case .collections: return "collections"
        case .homeVideos: return "homevideos"
        case .liveTV: return "livetv"
        case .photos: return "photos"
        case .folders: return "folders"
        case .other: return "other"
        }
    }

    var systemImage: String {
        switch self {
        case .movies: return "film"
        case .tvShows: return "tv"
        case .music: return "music.note"
        case .collections: return "square.stack.3d.up"
        case .homeVideos, .liveTV: return "play.rectangle"
        case .photos: return "photo"
        case .folders: return "folder"
        case .other: return "rectangle.stack"
        }
    }

    var subtitle: String {
        switch self {
        case .movies: return "Movies"
        case .tvShows: return "TV shows"
        case .music: return "Music"
        case .collections: return "Collections"
        case .homeVideos: return "Home videos"
        case .liveTV: return "Live TV"
        case .photos: return "Photos"
        case .folders: return "Folder"
        case .other: return "Library"
        }
    }
}
