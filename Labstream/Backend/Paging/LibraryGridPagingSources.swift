import Foundation
import PMSKit

@MainActor
extension LibraryPagingSource {
    init(gridSource source: LibraryGridSource, appModel: AppModel) {
        switch source {
        case .plex(let section):
            self = .plex(section: section, appModel: appModel)
        case .jellyfin(let view):
            self = .jellyfin(view: view, appModel: appModel)
        case .emby(let view):
            self = .emby(view: view, appModel: appModel)
        }
    }

    static func plex(section: PlexSection, appModel: AppModel) -> LibraryPagingSource {
        LibraryPagingSource(
            title: section.title,
            identity: libraryPagingIdentity(libraryID: section.key,
                                            sessionKey: appModel.browseSessionKey(for: .plex)),
            backendLabel: "Plex",
            cacheEmptyFirstPage: true,
            awaitAlphabetBeforeInitialLoad: true,
            fetchPage: { start, limit in
                guard let server = appModel.serverBaseURL,
                      let token = appModel.serverToken else {
                    throw LibraryPagingError.missingPlexServer
                }
                let req = BrowseAPI.sectionItems(server: server,
                                                 token: token,
                                                 identity: appModel.identity,
                                                 sectionKey: section.key,
                                                 containerStart: start,
                                                 containerSize: limit,
                                                 sort: "titleSort")
                let resp = try await appModel.client.send(req, as: MetadataResponse.self)
                let items = resp.mediaContainer.metadata
                SpotlightIndexer.index(items, server: server)
                return LibraryPagingPage(items: items,
                                         reportedTotal: resp.mediaContainer.totalSize)
            },
            fetchAlphabetCounts: {
                guard let server = appModel.serverBaseURL,
                      let token = appModel.serverToken else { return [] }
                let req = BrowseAPI.firstCharacters(server: server,
                                                    token: token,
                                                    identity: appModel.identity,
                                                    sectionKey: section.key)
                let response = try? await appModel.client.send(req, as: FirstCharacterResponse.self)
                return response?.libraryCounts() ?? []
            }
        )
    }

    static func jellyfin(view: JellyfinLibraryLink, appModel: AppModel) -> LibraryPagingSource {
        mediaBrowser(view: view, backend: .jellyfin, appModel: appModel)
    }

    static func emby(view: EmbyLibraryLink, appModel: AppModel) -> LibraryPagingSource {
        mediaBrowser(view: view, backend: .emby, appModel: appModel)
    }

    private static func mediaBrowser(view: MediaBrowserLibraryLink,
                                     backend: MediaBackendID,
                                     appModel: AppModel) -> LibraryPagingSource {
        precondition(backend == .jellyfin || backend == .emby)
        return LibraryPagingSource(
            title: view.title,
            identity: libraryPagingIdentity(libraryID: view.id,
                                            sessionKey: appModel.browseSessionKey(for: backend)),
            backendLabel: backend.displayName,
            cacheEmptyFirstPage: false,
            awaitAlphabetBeforeInitialLoad: false,
            collapsesMovieVersions: MediaBrowserLibraryGridPolicy.collapsesMovieVersions(collectionType: view.collectionType),
            fetchPage: { start, limit in
                let recursive = MediaBrowserLibraryGridPolicy.recursive(collectionType: view.collectionType)
                let itemTypes = MediaBrowserLibraryGridPolicy.itemTypes(collectionType: view.collectionType)
                let page = try await mediaBrowserItemsPage(
                    backend: backend, view: view, appModel: appModel,
                    recursive: recursive, startIndex: start, limit: limit,
                    includeItemTypes: itemTypes
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
                await mediaBrowserAlphabetCounts(backend: backend, appModel: appModel, view: view)
            }
        )
    }
}

@MainActor
private func libraryPagingIdentity(libraryID: String, sessionKey: String) -> String {
    // UI cache/stale-result guard. The centralized browse key is token-free, host-free,
    // server/user scoped, and includes a non-secret auth revision for same-server re-auth (#136).
    "\(sessionKey):library:\(libraryID)"
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
                                   includeItemTypes: String) async throws -> (items: [MediaItem], total: Int?) {
    switch backend {
    case .jellyfin:
        return try await JellyfinBrowseService(appModel: appModel).itemsPage(
            parentId: view.id, recursive: recursive, startIndex: startIndex, limit: limit,
            nameStartsWith: nameStartsWith, includeItemTypes: includeItemTypes,
            fields: JellyfinLibrary.gridItemFields
        )
    case .emby:
        return try await EmbyBrowseService(appModel: appModel).itemsPage(
            parentId: view.id, recursive: recursive, startIndex: startIndex, limit: limit,
            nameStartsWith: nameStartsWith, includeItemTypes: includeItemTypes,
            fields: EmbyLibrary.gridItemFields
        )
    case .plex:
        preconditionFailure("Plex does not use MediaBrowser paging")
    }
}

/// Probe each A-Z letter's MediaBrowser item count in parallel (GH #96). Individual probe
/// failures remain degraded to zero while stable letter order is reconstructed after completion.
@MainActor
private func mediaBrowserAlphabetCounts(backend: MediaBackendID,
                                        appModel: AppModel,
                                        view: MediaBrowserLibraryLink) async -> [(display: String, count: Int)] {
    let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init)
    let itemTypes = MediaBrowserLibraryGridPolicy.itemTypes(collectionType: view.collectionType)
    let recursive = MediaBrowserLibraryGridPolicy.recursive(collectionType: view.collectionType)
    let counts = await withTaskGroup(of: (Int, String, Int).self) { group -> [Int: (String, Int)] in
        for (index, letter) in letters.enumerated() {
            group.addTask {
                let page = try? await mediaBrowserItemsPage(
                    backend: backend, view: view, appModel: appModel,
                    recursive: recursive, startIndex: nil, limit: 1,
                    nameStartsWith: letter, includeItemTypes: itemTypes
                )
                return (index, letter, page?.total ?? 0)
            }
        }
        var byIndex: [Int: (String, Int)] = [:]
        for await (index, letter, count) in group where count > 0 {
            byIndex[index] = (letter, count)
        }
        return byIndex
    }
    return counts.keys.sorted().map { (display: counts[$0]!.0, count: counts[$0]!.1) }
}

struct FirstCharacterResponse: Decodable {
    let mediaContainer: Container
    enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }

    struct Container: Decodable {
        let directory: [Entry]
        enum CodingKeys: String, CodingKey {
            case directory = "Directory"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            directory = try c.decodeIfPresent([Entry].self, forKey: .directory) ?? []
        }
    }

    struct Entry: Decodable {
        let key: String?
        let title: String?
        let count: Int

        enum CodingKeys: String, CodingKey {
            case key
            case title
            case size
            case count
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decodeIfPresent(String.self, forKey: .key)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            count = (try? c.decodeLossyIntIfPresent(forKey: .size))
                ?? (try? c.decodeLossyIntIfPresent(forKey: .count))
                ?? 0
        }
    }

    /// Maps the Plex first-character response onto the shared alphabet-count shape;
    /// `LibraryPagingModel` turns it into `AlphabetBucket`s once the first page total is known.
    func libraryCounts() -> [(display: String, count: Int)] {
        mediaContainer.directory.map { (display: ($0.title ?? $0.key ?? ""), count: $0.count) }
    }
}

private extension KeyedDecodingContainer {
    func decodeLossyIntIfPresent(forKey key: Key) throws -> Int? {
        if let int = try decodeIfPresent(Int.self, forKey: key) { return int }
        if let string = try decodeIfPresent(String.self, forKey: key) { return Int(string) }
        return nil
    }
}
