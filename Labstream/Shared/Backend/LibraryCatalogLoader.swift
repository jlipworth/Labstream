import Foundation
import PMSKit

/// One backend-neutral library/section descriptor in the server's native order.
///
/// This is deliberately only the common enumeration boundary. Visibility, Music filtering,
/// destinations, Home rail policies, Search, and presentation remain owned by their surfaces.
struct LibraryCatalogDescriptor: Identifiable, Hashable, Sendable {
    let backend: MediaBackendKind
    let sourceID: String
    let title: String
    let kind: LibrarySectionKind
    /// Plex `Section.type` or MediaBrowser `collectionType`, retained so existing native browse
    /// destinations can be reconstructed without widening this loader into a paging repository.
    let sourceKind: String?

    var id: String { "\(backend.rawValue):\(sourceID)" }

    init(plex section: PlexSection) {
        backend = .plex
        sourceID = section.key
        title = section.title
        kind = LibrarySectionKind(plexType: section.type)
        sourceKind = section.type
    }

    init(mediaBrowser view: MediaBrowserLibraryLink, backend: MediaBackendKind) {
        precondition(backend == .jellyfin || backend == .emby,
                     "MediaBrowser catalog descriptors require Jellyfin or Emby")
        self.backend = backend
        sourceID = view.id
        title = view.title
        kind = LibrarySectionKind(collectionType: view.collectionType)
        sourceKind = view.collectionType
    }

    var plexSection: PlexSection? {
        guard backend == .plex, let sourceKind else { return nil }
        return PlexSection(key: sourceID, title: title, type: sourceKind)
    }

    var mediaBrowserLink: MediaBrowserLibraryLink? {
        guard backend == .jellyfin || backend == .emby else { return nil }
        return MediaBrowserLibraryLink(id: sourceID, title: title, collectionType: sourceKind)
    }
}

/// Behavior-neutral execution seam for the section/view enumeration shared by several surfaces.
///
/// Every `load()` still performs exactly one native backend read. This type intentionally owns no
/// cache, stale policy, or in-flight coalescing; those are separate Phase 2 semantic changes.
@MainActor
struct LibraryCatalogLoader {
    typealias Fetch = @MainActor @Sendable () async throws -> [LibraryCatalogDescriptor]

    let backend: MediaBackendKind
    /// Opaque authority of the immutable session captured by `fetch`. Keeping this beside the
    /// executable closure prevents a same-backend loader from being filed under another login.
    let authority: BrowseSessionAuthority
    private let fetch: Fetch

    init(appModel: AppModel, authority: BrowseSessionAuthority) {
        let backend = appModel.activeBackend
        self.backend = backend
        self.authority = authority
        switch backend {
        case .plex:
            // Snapshot the service now, before any repository task can suspend. It owns the exact
            // immutable BackendSession + identity represented by the caller's authority.
            let service = try? PlexBrowseService(appModel: appModel)
            fetch = {
                guard let service else {
                    throw PlexBrowseService.ServiceError.missingSession
                }
                return try await service.libraries().map(LibraryCatalogDescriptor.init(plex:))
            }
        case .jellyfin:
            let core = try? JellyfinBrowseService(appModel: appModel).browseCore()
            fetch = {
                guard let core else { throw JellyfinBrowseService.ServiceError.notAuthenticated }
                return try await core.userViewLinks().map {
                    LibraryCatalogDescriptor(mediaBrowser: $0, backend: .jellyfin)
                }
            }
        case .emby:
            let core = try? EmbyBrowseService(appModel: appModel).browseCore()
            fetch = {
                guard let core else { throw EmbyBrowseService.ServiceError.notAuthenticated }
                return try await core.userViewLinks().map {
                    LibraryCatalogDescriptor(mediaBrowser: $0, backend: .emby)
                }
            }
        }
    }

    init(backend: MediaBackendKind,
         authority: BrowseSessionAuthority,
         fetch: @escaping Fetch) {
        self.backend = backend
        self.authority = authority
        self.fetch = fetch
    }

    func load() async throws -> [LibraryCatalogDescriptor] {
        try await fetch()
    }
}
