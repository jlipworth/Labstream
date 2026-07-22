import Foundation
import PMSKit

/// Searches only the currently authenticated online backend. Offline downloads are
/// intentionally absent from this path, and every returned item is hydrated through
/// the participant's own credentials before SharePlay matching.
@MainActor
struct WatchTogetherMediaLookup {
    let appModel: AppModel
    let catalogRepository: LibraryCatalogRepository

    func candidates(matching query: String) async -> [MediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let lookupContext = appModel.activeAuthenticatedBrowseSession else { return [] }

        let snapshots: [MediaItem]
        switch lookupContext.backend {
        case .plex:
            let request = BrowseAPI.search(server: lookupContext.session.baseURL,
                                           token: lookupContext.session.token,
                                           identity: lookupContext.clientIdentity,
                                           query: trimmed)
            guard let response = try? await appModel.client.send(request, as: HubsResponse.self) else {
                return []
            }
            snapshots = response.mediaContainer.hub.flatMap(\.metadata)
        case .jellyfin, .emby:
            guard let client = try? MediaBrowserCatalogClient(appModel: appModel),
                  let request = try? catalogRepository.request(appModel: appModel),
                  let catalog = try? await catalogRepository.catalog(for: request),
                  client.matches(catalog), client.isCurrent(in: appModel) else {
                return []
            }
            let views = catalog.descriptors.compactMap(\.mediaBrowserLink)
            guard let results = try? await client.searchResults(query: trimmed, views: views),
                  client.isCurrent(in: appModel), !Task.isCancelled else { return [] }
            snapshots = results.groups.flatMap(\.hubs).flatMap(\.metadata)
        }

        guard let current = appModel.activeAuthenticatedBrowseSession,
              current.backend == lookupContext.backend,
              current.authority == lookupContext.authority,
              !Task.isCancelled else { return [] }

        var seen = Set<String>()
        let leaves = snapshots.filter {
            $0.isPlayableLeaf && !$0.isMusic && seen.insert($0.ratingKey).inserted
        }
        var hydrated: [MediaItem] = []
        for item in leaves.prefix(100) {
            guard let current = appModel.activeAuthenticatedBrowseSession,
                  current.backend == lookupContext.backend,
                  current.authority == lookupContext.authority,
                  !Task.isCancelled else { return [] }
            let result = await DetailMetadataLoader.load(ratingKey: item.ratingKey,
                                                         backend: lookupContext.backend,
                                                         appModel: appModel)
            guard let current = appModel.activeAuthenticatedBrowseSession,
                  current.backend == lookupContext.backend,
                  current.authority == lookupContext.authority,
                  !Task.isCancelled else { return [] }
            hydrated.append(result.item ?? item)
        }
        return hydrated
    }
}
