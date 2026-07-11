import Foundation
import PMSKit

struct RailViewAllDestination: Hashable, Identifiable {
    let title: String
    let backend: MediaBackendKind
    let sessionIdentity: String
    let query: RailViewAllQuery

    var id: String { "\(backend.rawValue):\(sessionIdentity):\(query)" }
}

enum RailViewAllQuery: Hashable {
    case plexRecentlyAdded(path: String, type: Int?)
    case mediaBrowserRecentlyAdded(parentID: String, itemTypes: String)
    case mediaBrowserResume(parentID: String?)
    case mediaBrowserNextUp(parentID: String?)
    case mediaBrowserSearch(text: String, parentID: String, itemTypes: String)
    case albums(libraryID: String)
}

enum RailViewAllEligibility {
    static func plexRecentlyAdded(hub: Hub,
                                  sessionIdentity: String) -> RailViewAllDestination? {
        guard let rawPath = hub.key ?? hub.hubKey,
              let selection = PlexRailPathPolicy.recentlyAddedSelection(rawPath) else { return nil }
        return RailViewAllDestination(title: hub.title,
                                      backend: .plex,
                                      sessionIdentity: sessionIdentity,
                                      query: .plexRecentlyAdded(path: selection.path, type: selection.type))
    }
}
