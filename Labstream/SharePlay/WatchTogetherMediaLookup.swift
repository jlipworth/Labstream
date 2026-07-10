import Foundation
import PMSKit

/// Searches only the currently authenticated online backend. Offline downloads are
/// intentionally absent from this path, and every returned item is hydrated through
/// the participant's own credentials before SharePlay matching.
@MainActor
struct WatchTogetherMediaLookup {
    let appModel: AppModel

    func candidates(matching query: String) async -> [MediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let snapshots: [MediaItem]
        switch appModel.activeBackend {
        case .plex:
            guard let server = appModel.serverBaseURL,
                  let token = appModel.serverToken else { return [] }
            let request = BrowseAPI.search(server: server, token: token,
                                           identity: appModel.identity, query: trimmed)
            guard let response = try? await appModel.client.send(request, as: HubsResponse.self) else {
                return []
            }
            snapshots = response.mediaContainer.hub.flatMap(\.metadata)
        case .jellyfin:
            guard let results = try? await JellyfinBrowseService(appModel: appModel)
                .searchResults(query: trimmed) else { return [] }
            snapshots = results.groups.flatMap(\.hubs).flatMap(\.metadata)
        case .emby:
            guard let results = try? await EmbyBrowseService(appModel: appModel)
                .searchResults(query: trimmed) else { return [] }
            snapshots = results.groups.flatMap(\.hubs).flatMap(\.metadata)
        }

        var seen = Set<String>()
        let leaves = snapshots.filter {
            $0.isPlayableLeaf && !$0.isMusic && seen.insert($0.ratingKey).inserted
        }
        var hydrated: [MediaItem] = []
        for item in leaves.prefix(100) {
            if Task.isCancelled { return [] }
            let result = await DetailMetadataLoader.load(ratingKey: item.ratingKey,
                                                         backend: appModel.activeBackend,
                                                         appModel: appModel)
            hydrated.append(result.item ?? item)
        }
        return hydrated
    }
}
