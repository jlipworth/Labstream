import Foundation
import PMSKit

/// Backend-specific metadata refresh seam for `DetailView`.
///
/// `DetailView` owns presentation state (selection clamping, watched overrides, task cancellation),
/// but the backend fetch shape is not view state. Keeping the request fan-out here makes future
/// metadata/detail decomposition smaller without touching downloads or offline playback wiring.
@MainActor
enum DetailMetadataLoader {
    struct Result {
        let item: MediaItem?
        let errorLabel: String?

        static func success(_ item: MediaItem) -> Result {
            Result(item: item, errorLabel: nil)
        }

        static func failure(_ errorLabel: String) -> Result {
            Result(item: nil, errorLabel: errorLabel)
        }
    }

    static func load(ratingKey: String,
                     backend: MediaBackendKind,
                     appModel: AppModel) async -> Result {
        switch backend {
        case .jellyfin:
            if let full = try? await JellyfinBrowseService(appModel: appModel).metadata(itemId: ratingKey) {
                return .success(full)
            }
            return .failure("metadata_unavailable")

        case .emby:
            if let full = try? await EmbyBrowseService(appModel: appModel).metadata(itemId: ratingKey) {
                return .success(full)
            }
            return .failure("metadata_unavailable")

        case .plex:
            guard let server = appModel.serverBaseURL, let token = appModel.serverToken else {
                return .failure("missing_plex_server")
            }
            let request = BrowseAPI.metadata(server: server,
                                             token: token,
                                             identity: appModel.identity,
                                             ratingKey: ratingKey)
            if let response = try? await appModel.client.send(request, as: MetadataResponse.self),
               let full = response.mediaContainer.metadata.first {
                return .success(full)
            }
            return .failure("metadata_unavailable")
        }
    }
}
