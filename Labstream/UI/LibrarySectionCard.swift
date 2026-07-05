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

    var body: some View {
        HStack(spacing: DS.Space.lg) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(.tint.opacity(0.18))
                Image(systemName: kind.systemImage)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            .frame(width: 76, height: 76)

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(kind.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(DS.Space.lg)
        .frame(width: 300, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
        .posterHover()
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
