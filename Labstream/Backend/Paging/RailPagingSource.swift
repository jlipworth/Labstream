import Foundation
import PMSKit

struct RailPage: Sendable {
    let items: [MediaItem]
    let reportedTotal: Int?
}

@MainActor
struct RailPagingSource {
    let identity: String
    let pageSize: Int
    let fetchPage: @MainActor @Sendable (_ start: Int, _ limit: Int) async throws -> RailPage

    init(destination: RailViewAllDestination, appModel: AppModel, pageSize: Int = 60) {
        self.identity = destination.sessionIdentity
        self.pageSize = pageSize
        self.fetchPage = { start, limit in
            guard appModel.activeBackend == destination.backend,
                  appModel.activeBrowseSessionKey == destination.sessionIdentity else {
                throw CancellationError()
            }
            switch destination.query {
            case .plexRecentlyAdded(let path, let type):
                guard let server = appModel.serverBaseURL, let token = appModel.serverToken else {
                    throw RailPagingSourceError.missingSession
                }
                let request = PlexRequest(url: server.appendingPathComponent(path),
                                          method: "GET",
                                          queryItems: ([
                                            .init(name: "X-Plex-Container-Start", value: String(start)),
                                            .init(name: "X-Plex-Container-Size", value: String(limit)),
                                          ] + (type.map { [.init(name: "type", value: String($0))] } ?? [])),
                                          headers: PlexHeaders.standard(identity: appModel.identity, token: token))
                let response = try await appModel.client.send(request, as: MetadataResponse.self)
                return RailPage(items: response.mediaContainer.metadata,
                                reportedTotal: response.mediaContainer.totalSize)
            case .mediaBrowserRecentlyAdded(let parentID, let itemTypes):
                let page = try await mediaBrowserItemsPage(appModel: appModel,
                                                           parentID: parentID,
                                                           start: start,
                                                           limit: limit,
                                                           search: nil,
                                                           itemTypes: itemTypes,
                                                           sortBy: "DateCreated,SortName",
                                                           sortOrder: "Descending")
                return RailPage(items: page.items, reportedTotal: page.total)
            case .mediaBrowserResume(let parentID):
                let page = try await mediaBrowserResumePage(appModel: appModel, parentID: parentID,
                                                            start: start, limit: limit)
                return RailPage(items: page.items, reportedTotal: page.total)
            case .mediaBrowserNextUp(let parentID):
                let page = try await mediaBrowserNextUpPage(appModel: appModel, parentID: parentID,
                                                            start: start, limit: limit)
                return RailPage(items: page.items, reportedTotal: page.total)
            case .mediaBrowserSearch(let text, let parentID, let itemTypes):
                let page = try await mediaBrowserItemsPage(appModel: appModel,
                                                           parentID: parentID,
                                                           start: start,
                                                           limit: limit,
                                                           search: text,
                                                           itemTypes: itemTypes,
                                                           sortBy: "SortName",
                                                           sortOrder: "Ascending")
                return RailPage(items: page.items, reportedTotal: page.total)
            case .albums(let libraryID):
                let page = try await appModel.musicProvider.albums(libraryID: libraryID,
                                                                  sort: .recentlyAdded,
                                                                  start: start,
                                                                  size: limit)
                return RailPage(items: page.items, reportedTotal: page.total)
            }
        }
    }
}

@MainActor
private func mediaBrowserItemsPage(appModel: AppModel, parentID: String, start: Int, limit: Int,
                                   search: String?, itemTypes: String, sortBy: String,
                                   sortOrder: String) async throws -> (items: [MediaItem], total: Int?) {
    switch appModel.activeBackend {
    case .jellyfin:
        return try await JellyfinBrowseService(appModel: appModel).itemsPage(parentId: parentID,
            recursive: true, startIndex: start, limit: limit, searchTerm: search,
            sortBy: sortBy, sortOrder: sortOrder, includeItemTypes: itemTypes)
    case .emby:
        return try await EmbyBrowseService(appModel: appModel).itemsPage(parentId: parentID,
            recursive: true, startIndex: start, limit: limit, searchTerm: search,
            sortBy: sortBy, sortOrder: sortOrder, includeItemTypes: itemTypes)
    case .plex:
        throw RailPagingSourceError.missingSession
    }
}

@MainActor
private func mediaBrowserResumePage(appModel: AppModel, parentID: String?, start: Int, limit: Int) async throws -> (items: [MediaItem], total: Int?) {
    switch appModel.activeBackend {
    case .jellyfin: return try await JellyfinBrowseService(appModel: appModel).resumeItemsPage(parentId: parentID, startIndex: start, limit: limit)
    case .emby: return try await EmbyBrowseService(appModel: appModel).resumeItemsPage(parentId: parentID, startIndex: start, limit: limit)
    case .plex: throw RailPagingSourceError.missingSession
    }
}

@MainActor
private func mediaBrowserNextUpPage(appModel: AppModel, parentID: String?, start: Int, limit: Int) async throws -> (items: [MediaItem], total: Int?) {
    switch appModel.activeBackend {
    case .jellyfin: return try await JellyfinBrowseService(appModel: appModel).nextUpPage(parentId: parentID, startIndex: start, limit: limit)
    case .emby: return try await EmbyBrowseService(appModel: appModel).nextUpPage(parentId: parentID, startIndex: start, limit: limit)
    case .plex: throw RailPagingSourceError.missingSession
    }
}

private enum RailPagingSourceError: LocalizedError {
    case missingSession
    var errorDescription: String? { "The selected server session is no longer available." }
}
