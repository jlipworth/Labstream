#if os(macOS)
import Foundation
import Observation
import PMSKit

/// Stable, token-free identity for a Mac source-list destination. Persisted identities include
/// the backend/server/user scope so a coincidentally identical library id on another server can
/// never restore the wrong row.
struct MacSidebarRouteID: Codable, Hashable {
    enum Kind: String, Codable {
        case home
        case library
        case musicHome
        case musicArtists
        case musicAlbums
        case musicPlaylists
        case offline
    }

    let kind: Kind
    let serverIdentity: String?
    let libraryID: String?

    static let home = MacSidebarRouteID(kind: .home, serverIdentity: nil, libraryID: nil)
    static let offline = MacSidebarRouteID(kind: .offline, serverIdentity: nil, libraryID: nil)

    static func library(serverIdentity: String, id: String) -> Self {
        Self(kind: .library, serverIdentity: serverIdentity, libraryID: id)
    }

    static func music(_ pivot: MusicPivot, serverIdentity: String) -> Self {
        let kind: Kind = switch pivot {
        case .home: .musicHome
        case .artists: .musicArtists
        case .albums: .musicAlbums
        case .playlists: .musicPlaylists
        }
        return Self(kind: kind, serverIdentity: serverIdentity, libraryID: nil)
    }

    var musicPivot: MusicPivot? {
        switch kind {
        case .musicHome: .home
        case .musicArtists: .artists
        case .musicAlbums: .albums
        case .musicPlaylists: .playlists
        default: nil
        }
    }
}

struct MacSidebarLibraryDescriptor: Identifiable, Hashable {
    let id: String
    let title: String
    let kind: LibrarySectionKind
    let accessibilityTitle: String
}

struct MacSidebarCatalog: Equatable {
    static let empty = MacSidebarCatalog(serverIdentity: nil,
                                         libraries: [],
                                         musicLibraries: [],
                                         musicDestinations: [])

    let serverIdentity: String?
    let libraries: [MacSidebarLibraryDescriptor]
    let musicLibraries: [MacSidebarLibraryDescriptor]
    let musicDestinations: [MusicPivot]

    var validRouteIDs: Set<MacSidebarRouteID> {
        var routes: Set<MacSidebarRouteID> = [.home, .offline]
        guard let serverIdentity else { return routes }
        routes.formUnion(libraries.map { .library(serverIdentity: serverIdentity, id: $0.id) })
        routes.formUnion(musicDestinations.map { .music($0, serverIdentity: serverIdentity) })
        return routes
    }
}

enum MacSidebarDestinationPolicy {
    struct Candidate: Equatable {
        let id: String
        let title: String
        let kind: LibrarySectionKind
    }

    /// Applies visibility and media-kind policy while preserving the server's original order.
    static func catalog(serverIdentity: String?,
                        candidates: [Candidate],
                        hiddenIDs: Set<String>,
                        supportsPlaylists: Bool) -> MacSidebarCatalog {
        guard let serverIdentity else { return .empty }
        let visible = candidates.filter { !hiddenIDs.contains($0.id) }
        let duplicateTitles = Dictionary(grouping: visible, by: { $0.title }).filter { $0.value.count > 1 }

        func descriptor(_ candidate: Candidate) -> MacSidebarLibraryDescriptor {
            let accessibilityTitle: String
            if let duplicates = duplicateTitles[candidate.title],
               let index = duplicates.firstIndex(of: candidate) {
                accessibilityTitle = "\(candidate.title), \(candidate.kind.subtitle) library, \(index + 1) of \(duplicates.count)"
            } else {
                accessibilityTitle = candidate.title
            }
            return MacSidebarLibraryDescriptor(id: candidate.id,
                                               title: candidate.title,
                                               kind: candidate.kind,
                                               accessibilityTitle: accessibilityTitle)
        }

        let libraries = visible.filter { $0.kind != .music }.map(descriptor)
        let musicLibraries = visible.filter { $0.kind == .music }.map(descriptor)
        var musicDestinations: [MusicPivot] = []
        if !musicLibraries.isEmpty {
            musicDestinations = [.home, .artists, .albums]
            if supportsPlaylists { musicDestinations.append(.playlists) }
        }
        return MacSidebarCatalog(serverIdentity: serverIdentity,
                                 libraries: libraries,
                                 musicLibraries: musicLibraries,
                                 musicDestinations: musicDestinations)
    }

    /// Every stale/unsupported/foreign persisted route fails closed to Home.
    static func restoredRoute(_ persisted: MacSidebarRouteID?,
                              in catalog: MacSidebarCatalog) -> MacSidebarRouteID {
        guard let persisted, catalog.validRouteIDs.contains(persisted) else { return .home }
        return persisted
    }
}

enum MacSidebarDestination: Hashable {
    case home
    case library(String)
    case music(MusicPivot)
    case offline

    func routeID(serverIdentity: String?) -> MacSidebarRouteID {
        switch self {
        case .home: return .home
        case .offline: return .offline
        case .library(let id):
            guard let serverIdentity else { return .home }
            return .library(serverIdentity: serverIdentity, id: id)
        case .music(let pivot):
            guard let serverIdentity else { return .home }
            return .music(pivot, serverIdentity: serverIdentity)
        }
    }

    static func make(route: MacSidebarRouteID) -> Self {
        switch route.kind {
        case .home: .home
        case .offline: .offline
        case .library: route.libraryID.map(Self.library) ?? .home
        case .musicHome, .musicArtists, .musicAlbums, .musicPlaylists:
            route.musicPivot.map(Self.music) ?? .home
        }
    }
}

/// Small per-server persistence adapter. Keeping one route per stable server identity preserves
/// the user's place when switching backends without ever applying a route to the wrong server.
struct MacSidebarSelectionStore {
    private struct Payload: Codable {
        var routes: [String: MacSidebarRouteID] = [:]
    }

    private let defaults: UserDefaults
    private let key = "macSidebarSelection.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func route(for serverIdentity: String?) -> MacSidebarRouteID? {
        guard let serverIdentity else { return nil }
        return payload().routes[serverIdentity]
    }

    func save(_ route: MacSidebarRouteID, for serverIdentity: String?) {
        guard let serverIdentity else { return }
        var value = payload()
        value.routes[serverIdentity] = route
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private func payload() -> Payload {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Payload.self, from: data) else {
            return Payload()
        }
        return decoded
    }
}

@MainActor
@Observable
final class MacSidebarModel {
    private(set) var catalog: MacSidebarCatalog = .empty
    private(set) var librarySources: [String: LibraryGridSource] = [:]
    private(set) var loadError: String?
    private(set) var visibilityPrompt: LibraryVisibilityPrompt?

    private let visibilityStore = LibraryVisibilityStore()

    func load(appModel: AppModel) async {
        let capturedSession = appModel.activeBrowseSessionKey
        let stableIdentity = appModel.activeStableServerUserKey
        if catalog.serverIdentity != stableIdentity {
            // Never leave tappable routes from the previous backend/server visible while the new
            // catalog request is in flight.
            catalog = .empty
            librarySources = [:]
            loadError = nil
        }
        do {
            let candidates: [MacSidebarDestinationPolicy.Candidate]
            let promptCandidates: [MacSidebarDestinationPolicy.Candidate]
            let sources: [String: LibraryGridSource]
            let supportsPlaylists: Bool

            switch appModel.activeBackend {
            case .plex:
                guard let service = try? PlexBrowseService(appModel: appModel) else {
                    throw MacSidebarLoadError.noServer
                }
                let sections = try await service.libraries()
                candidates = sections.map {
                    .init(id: $0.key, title: $0.title, kind: LibrarySectionKind(plexType: $0.type))
                }
                promptCandidates = candidates.filter { $0.kind != .music }
                sources = Dictionary(uniqueKeysWithValues: sections.filter { !$0.isMusic }.map {
                    ($0.key, LibraryGridSource.plex($0))
                })
                // Plex exposes an account-level audio playlists endpoint for every music section.
                supportsPlaylists = true
            case .jellyfin:
                let views = try await JellyfinBrowseService(appModel: appModel).userViewLinks()
                candidates = views.map {
                    .init(id: $0.id, title: $0.title,
                          kind: LibrarySectionKind(collectionType: $0.collectionType))
                }
                promptCandidates = candidates
                sources = Dictionary(uniqueKeysWithValues: views.filter {
                    LibrarySectionKind(collectionType: $0.collectionType) != .music
                }.map { ($0.id, LibraryGridSource.jellyfin($0)) })
                supportsPlaylists = views.contains { $0.collectionType?.lowercased() == "playlists" }
            case .emby:
                let views = try await EmbyBrowseService(appModel: appModel).userViewLinks()
                candidates = views.map {
                    .init(id: $0.id, title: $0.title,
                          kind: LibrarySectionKind(collectionType: $0.collectionType))
                }
                promptCandidates = candidates
                sources = Dictionary(uniqueKeysWithValues: views.filter {
                    LibrarySectionKind(collectionType: $0.collectionType) != .music
                }.map { ($0.id, LibraryGridSource.emby($0)) })
                supportsPlaylists = views.contains { $0.collectionType?.lowercased() == "playlists" }
            }

            guard appModel.activeBrowseSessionKey == capturedSession, !Task.isCancelled else { return }
            appModel.migrateLibraryVisibilityKeysIfNeeded(store: visibilityStore)
            let hidden = visibilityStore.hiddenIDs(forBackendKey: stableIdentity)
            let nextCatalog = MacSidebarDestinationPolicy.catalog(serverIdentity: stableIdentity,
                                                                  candidates: candidates,
                                                                  hiddenIDs: hidden,
                                                                  supportsPlaylists: supportsPlaylists)
            maybePrepareVisibilityPrompt(candidates: promptCandidates,
                                         backendKey: stableIdentity)
            catalog = nextCatalog
            librarySources = sources
            loadError = nil
        } catch {
            guard appModel.activeBrowseSessionKey == capturedSession, !Task.isCancelled else { return }
            catalog = .empty
            librarySources = [:]
            loadError = friendlyMessage(error)
        }
    }

    func applyVisibility(_ hiddenIDs: Set<String>, backendKey: String) {
        visibilityStore.setHiddenIDs(hiddenIDs, forBackendKey: backendKey)
        visibilityStore.markPromptShown(forBackendKey: backendKey)
        visibilityPrompt = nil
    }

    func dismissVisibilityPrompt(backendKey: String) {
        visibilityStore.markPromptShown(forBackendKey: backendKey)
        visibilityPrompt = nil
    }

    private func maybePrepareVisibilityPrompt(candidates: [MacSidebarDestinationPolicy.Candidate],
                                              backendKey: String?) {
        guard let backendKey,
              !candidates.isEmpty,
              !visibilityStore.hasShownPrompt(forBackendKey: backendKey),
              visibilityPrompt == nil else { return }
        let promptCandidates = candidates.map {
            LibraryVisibility.Candidate(id: $0.id,
                                        title: $0.title,
                                        kind: $0.kind.visibilityKindToken)
        }
        visibilityPrompt = LibraryVisibilityPrompt(
            backendKey: backendKey,
            candidates: promptCandidates,
            preselectedHidden: LibraryVisibility.defaultHiddenSelection(from: promptCandidates)
        )
    }
}

private enum MacSidebarLoadError: LocalizedError {
    case noServer
    var errorDescription: String? { "No server selected." }
}
#endif
