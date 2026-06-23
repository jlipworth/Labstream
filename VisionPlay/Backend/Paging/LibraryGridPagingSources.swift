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
            identity: libraryPagingIdentity(backend: "plex",
                                            libraryID: section.key,
                                            serverID: appModel.selectedServer?.clientIdentifier,
                                            baseURL: appModel.serverBaseURL,
                                            userID: nil),
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
        LibraryPagingSource(
            title: view.title,
            identity: libraryPagingIdentity(backend: "jellyfin",
                                            libraryID: view.id,
                                            serverID: appModel.jellyfinServerID,
                                            baseURL: appModel.jellyfinServerBaseURL,
                                            userID: appModel.jellyfinUserID),
            backendLabel: "Jellyfin",
            cacheEmptyFirstPage: false,
            awaitAlphabetBeforeInitialLoad: false,
            collapsesMovieVersions: MediaBrowserLibraryGridPolicy.collapsesMovieVersions(collectionType: view.collectionType),
            fetchPage: { start, limit in
                let service = JellyfinBrowseService(appModel: appModel)
                let recursive = jellyfinLibraryRecursive(for: view)
                let itemTypes = jellyfinLibraryItemTypes(for: view)
                let page = try await service.itemsPage(parentId: view.id,
                                                       recursive: recursive,
                                                       startIndex: start,
                                                       limit: limit,
                                                       includeItemTypes: itemTypes,
                                                       fields: JellyfinLibrary.gridItemFields)
                let gridPage = LibraryPagingPage(items: page.items, reportedTotal: page.total)
                recordGridPageDiagnostics(page.items,
                                          backend: "Jellyfin",
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
                await jellyfinAlphabetCounts(service: JellyfinBrowseService(appModel: appModel), view: view)
            }
        )
    }

    static func emby(view: EmbyLibraryLink, appModel: AppModel) -> LibraryPagingSource {
        LibraryPagingSource(
            title: view.title,
            identity: libraryPagingIdentity(backend: "emby",
                                            libraryID: view.id,
                                            serverID: appModel.embyServerID,
                                            baseURL: appModel.embyServerBaseURL,
                                            userID: appModel.embyUserID),
            backendLabel: "Emby",
            cacheEmptyFirstPage: false,
            awaitAlphabetBeforeInitialLoad: false,
            collapsesMovieVersions: MediaBrowserLibraryGridPolicy.collapsesMovieVersions(collectionType: view.collectionType),
            fetchPage: { start, limit in
                let service = EmbyBrowseService(appModel: appModel)
                let recursive = embyLibraryRecursive(for: view)
                let itemTypes = embyLibraryItemTypes(for: view)
                let page = try await service.itemsPage(parentId: view.id,
                                                       recursive: recursive,
                                                       startIndex: start,
                                                       limit: limit,
                                                       includeItemTypes: itemTypes,
                                                       fields: EmbyLibrary.gridItemFields)
                let gridPage = LibraryPagingPage(items: page.items, reportedTotal: page.total)
                recordGridPageDiagnostics(page.items,
                                          backend: "Emby",
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
                await embyAlphabetCounts(service: EmbyBrowseService(appModel: appModel), view: view)
            }
        )
    }
}

private func libraryPagingIdentity(backend: String,
                                   libraryID: String,
                                   serverID: String?,
                                   baseURL: URL?,
                                   userID: String?) -> String {
    // Identity is only a UI cache/stale-result guard. Keep raw access tokens and full
    // URLs out of it; server/user IDs plus origin host are enough to invalidate on
    // backend, account, server, or library switches.
    let origin = [baseURL?.scheme, baseURL?.host, baseURL?.port.map(String.init)]
        .compactMap { $0 }
        .joined(separator: ":")
    return [backend, libraryID, serverID ?? "nil", origin, userID ?? "nil"]
        .joined(separator: ":")
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

/// Probe each A-Z letter's item count for the Jellyfin alphabet rail, in parallel
/// (GH #96). Returns raw `(display, count)` pairs; `LibraryPagingModel` applies the
/// shared `AlphabetBucket` offset math after the first page reports the library total.
private func jellyfinAlphabetCounts(service: JellyfinBrowseService,
                                    view: JellyfinLibraryLink) async -> [(display: String, count: Int)] {
    let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init)
    let itemTypes = jellyfinLibraryItemTypes(for: view)
    let recursive = jellyfinLibraryRecursive(for: view)
    let counts = await withTaskGroup(of: (Int, String, Int).self) { group -> [Int: (String, Int)] in
        for (index, letter) in letters.enumerated() {
            group.addTask {
                let page = try? await service.itemsPage(parentId: view.id,
                                                        recursive: recursive,
                                                        limit: 1,
                                                        nameStartsWith: letter,
                                                        includeItemTypes: itemTypes,
                                                        fields: JellyfinLibrary.gridItemFields)
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

/// Emby twin of `jellyfinAlphabetCounts` (GH #96) — identical parallelized probe.
private func embyAlphabetCounts(service: EmbyBrowseService,
                                view: EmbyLibraryLink) async -> [(display: String, count: Int)] {
    let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init)
    let itemTypes = embyLibraryItemTypes(for: view)
    let recursive = embyLibraryRecursive(for: view)
    let counts = await withTaskGroup(of: (Int, String, Int).self) { group -> [Int: (String, Int)] in
        for (index, letter) in letters.enumerated() {
            group.addTask {
                let page = try? await service.itemsPage(parentId: view.id,
                                                        recursive: recursive,
                                                        limit: 1,
                                                        nameStartsWith: letter,
                                                        includeItemTypes: itemTypes,
                                                        fields: EmbyLibrary.gridItemFields)
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

private func embyLibraryItemTypes(for view: EmbyLibraryLink) -> String {
    MediaBrowserLibraryGridPolicy.itemTypes(collectionType: view.collectionType)
}

private func embyLibraryRecursive(for view: EmbyLibraryLink) -> Bool {
    MediaBrowserLibraryGridPolicy.recursive(collectionType: view.collectionType)
}

private func jellyfinLibraryItemTypes(for view: JellyfinLibraryLink) -> String {
    MediaBrowserLibraryGridPolicy.itemTypes(collectionType: view.collectionType)
}

private func jellyfinLibraryRecursive(for view: JellyfinLibraryLink) -> Bool {
    MediaBrowserLibraryGridPolicy.recursive(collectionType: view.collectionType)
}

private struct FirstCharacterResponse: Decodable {
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
