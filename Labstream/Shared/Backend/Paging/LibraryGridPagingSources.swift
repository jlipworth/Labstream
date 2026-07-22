import Foundation
import PMSKit

@MainActor
extension LibraryPagingSource {
    init(gridSource source: LibraryGridSource,
         query: LibraryBrowseQuery = .default,
         appModel: AppModel) {
        switch source {
        case .plex(let section):
            self = .plex(section: section, query: query, appModel: appModel)
        case .plexCollections(let section):
            self = .plexCollections(section: section, appModel: appModel)
        case .jellyfin(let view):
            self = .jellyfin(view: view, query: query, appModel: appModel)
        case .emby(let view):
            self = .emby(view: view, query: query, appModel: appModel)
        }
    }

    static func plex(section: PlexSection,
                     query: LibraryBrowseQuery = .default,
                     appModel: AppModel) -> LibraryPagingSource {
        LibraryPagingSource(
            title: section.title,
            identity: libraryPagingIdentity(libraryID: section.key,
                                            sessionKey: appModel.browseSessionKey(for: .plex),
                                            query: query),
            backendLabel: "Plex",
            cacheEmptyFirstPage: true,
            // Plex's first-character endpoint can be noticeably slower than page 0 on a
            // physical device. Publish the grid as soon as page 0 arrives, then attach the
            // rail when the independent alphabet request completes.
            awaitAlphabetBeforeInitialLoad: false,
            supportsAlphabetRail: query.supportsAlphabetRail,
            fetchPage: { start, limit in
                guard let service = try? PlexBrowseService(appModel: appModel) else {
                    throw LibraryPagingError.missingPlexServer
                }
                let page = try await service.sectionPage(sectionKey: section.key,
                                                         startIndex: start,
                                                         limit: limit,
                                                         browseQuery: query)
                SpotlightIndexer.index(page.items, server: service.session.baseURL)
                return LibraryPagingPage(items: page.items, reportedTotal: page.total)
            },
            fetchAlphabetCounts: {
                guard query.supportsAlphabetRail else { return [] }
                guard let service = try? PlexBrowseService(appModel: appModel) else { return [] }
                return (try? await service.alphabetCounts(sectionKey: section.key)) ?? []
            }
        )
    }

    /// Backend-defined Plex collections for one section (#199), via
    /// `/library/sections/{key}/collections`. Collection grids deliberately keep the
    /// default ordering and omit the alphabet jump because Plex's first-character
    /// endpoint does not cover this route.
    static func plexCollections(section: PlexSection, appModel: AppModel) -> LibraryPagingSource {
        LibraryPagingSource(
            title: section.title,
            identity: "\(libraryPagingIdentity(libraryID: section.key, sessionKey: appModel.browseSessionKey(for: .plex))):collections",
            backendLabel: "Plex",
            cacheEmptyFirstPage: true,
            awaitAlphabetBeforeInitialLoad: false,
            supportsAlphabetRail: false,
            fetchPage: { start, limit in
                guard let server = appModel.serverBaseURL,
                      let token = appModel.serverToken else {
                    throw LibraryPagingError.missingPlexServer
                }
                let req = CollectionRequest.plexCollections(server: server,
                                                            token: token,
                                                            identity: appModel.identity,
                                                            sectionKey: section.key,
                                                            containerStart: start,
                                                            containerSize: limit)
                let resp = try await appModel.client.send(req, as: MetadataResponse.self)
                return LibraryPagingPage(items: resp.mediaContainer.metadata,
                                         reportedTotal: resp.mediaContainer.totalSize)
            },
            fetchAlphabetCounts: { [] }
        )
    }

    static func jellyfin(view: JellyfinLibraryLink,
                         query: LibraryBrowseQuery = .default,
                         appModel: AppModel) -> LibraryPagingSource {
        mediaBrowser(view: view, backend: .jellyfin, query: query, appModel: appModel)
    }

    static func emby(view: EmbyLibraryLink,
                     query: LibraryBrowseQuery = .default,
                     appModel: AppModel) -> LibraryPagingSource {
        mediaBrowser(view: view, backend: .emby, query: query, appModel: appModel)
    }

    private static func mediaBrowser(view: MediaBrowserLibraryLink,
                                     backend: MediaBackendID,
                                     query: LibraryBrowseQuery = .default,
                                     appModel: AppModel) -> LibraryPagingSource {
        precondition(backend == .jellyfin || backend == .emby)
        return LibraryPagingSource(
            title: view.title,
            identity: libraryPagingIdentity(libraryID: view.id,
                                            sessionKey: appModel.browseSessionKey(for: backend),
                                            query: query),
            backendLabel: backend.displayName,
            cacheEmptyFirstPage: false,
            awaitAlphabetBeforeInitialLoad: false,
            collapsesMovieVersions: MediaBrowserLibraryGridPolicy.collapsesMovieVersions(collectionType: view.collectionType),
            supportsAlphabetRail: query.supportsAlphabetRail,
            fetchPage: { start, limit in
                let recursive = MediaBrowserLibraryGridPolicy.recursive(collectionType: view.collectionType)
                let itemTypes = MediaBrowserLibraryGridPolicy.itemTypes(collectionType: view.collectionType)
                let page = try await mediaBrowserItemsPage(
                    backend: backend, view: view, appModel: appModel,
                    recursive: recursive, startIndex: start, limit: limit,
                    includeItemTypes: itemTypes, browseQuery: query
                )
                if let session = appModel.backendSession(for: backend) {
                    SpotlightIndexer.index(page.items, backend: backend, server: session.baseURL)
                }
                let gridPage = LibraryPagingPage(items: page.items, reportedTotal: page.total)
                recordGridPageDiagnostics(page.items,
                                          backend: backend.displayName,
                                          sourceID: view.id,
                                          sourceName: view.title,
                                          sourceKind: view.collectionType,
                                          recursive: recursive,
                                          includeItemTypes: itemTypes,
                                          startIndex: start,
                                          limit: limit,
                                          total: start == 0 ? gridPage.total : page.total)
                return gridPage
            },
            fetchAlphabetCounts: {
                guard query.supportsAlphabetRail else { return [] }
                return await mediaBrowserAlphabetCounts(backend: backend, appModel: appModel, view: view)
            }
        )
    }
}

@MainActor
private func libraryPagingIdentity(libraryID: String,
                                   sessionKey: String,
                                   query: LibraryBrowseQuery = .default) -> String {
    // UI cache/stale-result guard. The centralized browse key is token-free, host-free,
    // server/user scoped, and includes a non-secret auth revision for same-server re-auth (#136).
    "\(sessionKey):library:\(libraryID):\(query.identityComponent)"
}

private func recordGridPageDiagnostics(_ items: [MediaItem],
                                       backend: String,
                                       sourceID: String,
                                       sourceName: String,
                                       sourceKind: String?,
                                       recursive: Bool,
                                       includeItemTypes: String,
                                       startIndex: Int,
                                       limit: Int,
                                       total: Int?) {
    let summary = BrowseDiagnostics.libraryGridPage(items: items,
                                                    backend: backend,
                                                    sourceID: sourceID,
                                                    sourceName: sourceName,
                                                    sourceKind: sourceKind,
                                                    recursive: recursive,
                                                    includeItemTypes: includeItemTypes,
                                                    startIndex: startIndex,
                                                    limit: limit,
                                                    total: total)
    AppDiagnostics.record(.browse, "library_grid.page", fields: summary.fields)
    #if DEBUG
    NSLog("%@", "library.grid.items \(summary.consoleLine)")
    #endif
}

@MainActor
private func mediaBrowserItemsPage(backend: MediaBackendID,
                                   view: MediaBrowserLibraryLink,
                                   appModel: AppModel,
                                   recursive: Bool,
                                   startIndex: Int?,
                                   limit: Int?,
                                   nameStartsWith: String? = nil,
                                   includeItemTypes: String,
                                   browseQuery: LibraryBrowseQuery = .default) async throws -> (items: [MediaItem], total: Int?) {
    switch backend {
    case .jellyfin:
        return try await JellyfinBrowseService(appModel: appModel).itemsPage(
            parentId: view.id, recursive: recursive, startIndex: startIndex, limit: limit,
            nameStartsWith: nameStartsWith, includeItemTypes: includeItemTypes,
            fields: MediaBrowserMetadataFieldProfiles.grid.fields, browseQuery: browseQuery
        )
    case .emby:
        return try await EmbyBrowseService(appModel: appModel).itemsPage(
            parentId: view.id, recursive: recursive, startIndex: startIndex, limit: limit,
            nameStartsWith: nameStartsWith, includeItemTypes: includeItemTypes,
            fields: MediaBrowserMetadataFieldProfiles.grid.fields, browseQuery: browseQuery
        )
    case .plex:
        preconditionFailure("Plex does not use MediaBrowser paging")
    }
}

/// Probe each A-Z letter's MediaBrowser item count with a four-request bound (GH #96). Individual
/// probe failures remain degraded to zero while stable letter order is preserved.
@MainActor
private func mediaBrowserAlphabetCounts(backend: MediaBackendID,
                                        appModel: AppModel,
                                        view: MediaBrowserLibraryLink) async -> [(display: String, count: Int)] {
    let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init)
    let itemTypes = MediaBrowserLibraryGridPolicy.itemTypes(collectionType: view.collectionType)
    let recursive = MediaBrowserLibraryGridPolicy.recursive(collectionType: view.collectionType)
    return (try? await AlphabetCountFanout.counts(letters: letters) { letter in
        let page = try await mediaBrowserItemsPage(
            backend: backend, view: view, appModel: appModel,
            recursive: recursive, startIndex: nil, limit: 1,
            nameStartsWith: letter, includeItemTypes: itemTypes
        )
        return page.total ?? 0
    }) ?? []
}
