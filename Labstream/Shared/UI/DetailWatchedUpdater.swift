import Foundation
import PMSKit

/// Backend-specific watched/unwatched mutation for `DetailView`.
///
/// `DetailView` owns optimistic UI state and rollback. This helper owns only the backend request
/// fan-out so the view does not carry Plex/Jellyfin/Emby mutation details inline.
@MainActor
enum DetailWatchedUpdater {
    static func setPlayed(item: MediaItem,
                          backend: MediaBackendKind,
                          appModel: AppModel,
                          played: Bool) async throws {
        switch backend {
        case .plex:
            guard let service = try? PlexBrowseService(appModel: appModel) else {
                throw DetailWatchedUpdateError.missingPlexSession
            }
            try await service.setPlayed(ratingKey: item.ratingKey, played: played)
        case .jellyfin:
            try await JellyfinBrowseService(appModel: appModel)
                .setPlayed(itemId: item.ratingKey, played: played)
        case .emby:
            try await EmbyBrowseService(appModel: appModel)
                .setPlayed(itemId: item.ratingKey, played: played)
        }
    }
}

enum DetailWatchedUpdateError: Error {
    case missingPlexSession
}
