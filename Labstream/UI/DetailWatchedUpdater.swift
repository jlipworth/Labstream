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
            guard let server = appModel.serverBaseURL,
                  let token = appModel.serverToken else {
                throw DetailWatchedUpdateError.missingPlexSession
            }
            let request = played
                ? TimelineRequest.scrobble(server: server,
                                           token: token,
                                           identity: appModel.identity,
                                           ratingKey: item.ratingKey)
                : TimelineRequest.unscrobble(server: server,
                                             token: token,
                                             identity: appModel.identity,
                                             ratingKey: item.ratingKey)
            _ = try await appModel.client.send(request)
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
