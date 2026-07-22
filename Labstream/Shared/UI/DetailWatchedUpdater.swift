import Foundation
import PMSKit

/// Exact identity captured before an asynchronous Detail watched mutation begins.
///
/// A collapsed movie's selected version can change while the backend request is in flight. The
/// server/repository result still belongs to the item that was actually mutated, while mounted UI
/// state may be updated only if that same detail version remains selected at completion.
struct DetailWatchedMutationTarget: Equatable, Sendable {
    let backend: MediaBackendKind
    let authority: BrowseSessionAuthority
    let itemID: String
    let detailVersionID: String

    func isStillMounted(backend currentBackend: MediaBackendKind,
                        authority currentAuthority: BrowseSessionAuthority?,
                        activeVersionID: String,
                        detailedItemID: String) -> Bool {
        backend == currentBackend
            && authority == currentAuthority
            && detailVersionID == activeVersionID
            && itemID == detailedItemID
    }
}

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
