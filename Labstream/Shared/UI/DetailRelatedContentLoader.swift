import Foundation
import PMSKit

/// Backend dispatch for the extra reads the iPhone/iPad detail pages make beyond the item's own
/// metadata: the "More Like This" rail and a show's episodes for its resume action. Every read
/// degrades to an empty result so a failed or unsupported call only removes that section.
@MainActor
enum DetailRelatedContentLoader {
    static let similarLimit = 20

    /// "More Like This" for a movie or show.
    static func similar(to item: MediaItem,
                        backend: MediaBackendKind,
                        appModel: AppModel) async -> [MediaItem] {
        #if DEBUG
        if DebugUIFixtureCatalog.isBrowseEnabled {
            return DebugUIFixtureCatalog.similarItems(for: item, backend: backend)
        }
        #endif
        switch backend {
        case .plex:
            guard let service = try? PlexBrowseService(appModel: appModel) else { return [] }
            return (try? await service.similar(ratingKey: item.ratingKey, count: similarLimit)) ?? []
        case .jellyfin:
            return await JellyfinBrowseService(appModel: appModel)
                .similarItems(itemId: item.ratingKey, limit: similarLimit)
        case .emby:
            return await EmbyBrowseService(appModel: appModel)
                .similarItems(itemId: item.ratingKey, limit: similarLimit)
        }
    }

    /// Every episode of a show with its view state, in season/episode order.
    static func episodes(ofShow show: MediaItem,
                         backend: MediaBackendKind,
                         appModel: AppModel) async -> [MediaItem] {
        #if DEBUG
        if let fixture = DebugUIFixtureCatalog.showEpisodes(for: show) { return fixture }
        #endif
        switch backend {
        case .plex:
            guard let service = try? PlexBrowseService(appModel: appModel) else { return [] }
            return (try? await service.showEpisodes(ratingKey: show.ratingKey)) ?? []
        case .jellyfin:
            return (try? await JellyfinBrowseService(appModel: appModel)
                .showEpisodes(seriesId: show.ratingKey)) ?? []
        case .emby:
            return (try? await EmbyBrowseService(appModel: appModel)
                .showEpisodes(seriesId: show.ratingKey)) ?? []
        }
    }
}
