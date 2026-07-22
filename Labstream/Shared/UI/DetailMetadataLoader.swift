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
        let snapshot: MetadataSnapshot?

        static func success(_ item: MediaItem, snapshot: MetadataSnapshot? = nil) -> Result {
            Result(item: item, errorLabel: nil, snapshot: snapshot)
        }

        static func failure(_ errorLabel: String) -> Result {
            Result(item: nil, errorLabel: errorLabel, snapshot: nil)
        }
    }

    static func load(ratingKey: String,
                     backend: MediaBackendKind,
                     appModel: AppModel,
                     repository: MetadataRepository? = nil,
                     policy: MetadataReadPolicy = .display) async -> Result {
        if let repository {
            do {
                let snapshot = try await repository.metadata(appModel: appModel,
                                                             backend: backend,
                                                             itemID: ratingKey,
                                                             policy: policy)
                return .success(snapshot.item, snapshot: snapshot)
            } catch {
                return .failure(errorLabel(for: error, backend: backend))
            }
        }

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
            guard let service = try? PlexBrowseService(appModel: appModel) else {
                return .failure("missing_plex_server")
            }
            if let full = try? await service.metadata(ratingKey: ratingKey) {
                return .success(full)
            }
            return .failure("metadata_unavailable")
        }
    }

    private static func errorLabel(for error: Error, backend: MediaBackendKind) -> String {
        if error is CancellationError { return "cancelled" }
        if let repositoryError = error as? MetadataRepositoryError {
            switch repositoryError {
            case .noAuthenticatedSession:
                return backend == .plex ? "missing_plex_server" : "metadata_unavailable"
            case .backendMismatch: return "metadata_backend_mismatch"
            case .authorityMismatch: return "metadata_authority_mismatch"
            case .authorityExpired: return "metadata_authority_expired"
            }
        }
        return "metadata_unavailable"
    }
}
