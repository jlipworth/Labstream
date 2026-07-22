import AppIntents
import PMSKit

/// An App Intents entity wrapping one library item. Suggestions use backend-scoped,
/// server-scoped identifiers so saved Shortcuts route only into the active signed-in backend.
/// This is what shows up as the "Title" parameter in
/// Shortcuts and in "Play <title> on Labstream" Siri phrases.
///
/// Deliberately a snapshot of display fields only — intents re-fetch authoritative
/// metadata by ratingKey at perform time, so a stale snapshot can't mis-play.
struct MediaItemEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Media Item")
    static let defaultQuery = MediaItemEntityQuery()

    /// System-entry identifier. Backend-scoped ids parse through `MediaSearchIdentifier.routeKey`;
    /// older saved shortcuts with bare/server-scoped Plex ids remain accepted by the query.
    let id: String
    let title: String
    /// Secondary display line: show + episode code for an episode, year for a movie.
    let subtitle: String?
    /// Raw PMS type string ("movie" | "show" | "episode" | …), kept for the glyph.
    let type: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: subtitle.map { "\($0)" },
            image: .init(systemName: glyph))
    }

    private var glyph: String {
        // Raw type strings: `MediaItem.Kind`'s initializer is internal to PMSKit.
        switch type {
        case "show", "season", "episode": return "tv"
        default: return "film"
        }
    }

    init(item: MediaItem, backend: MediaBackendKind, server: URL) {
        self.id = MediaSearchIdentifier.make(ratingKey: item.ratingKey,
                                             server: server,
                                             backend: backend)
        let fields = Self.displayFields(for: item)
        self.type = fields.type
        self.title = fields.title
        self.subtitle = fields.subtitle
    }

    private static func displayFields(for item: MediaItem) -> (type: String, title: String, subtitle: String?) {
        if item.kind == .episode {
            // "Episode title" + "Show · S1E3" mirrors the poster-cell treatment.
            let context = [item.grandparentTitle, item.seasonEpisodeCode]
                .compactMap { $0 }.joined(separator: " · ")
            return (item.type, item.title, context.isEmpty ? nil : context)
        } else {
            return (item.type, item.title, item.year.map(String.init))
        }
    }
}

/// Resolves `MediaItemEntity` values against the signed-in server: by ratingKey
/// (re-resolution of a saved shortcut), by free-text search (the user types a title
/// in Shortcuts / speaks one to Siri), and as suggestions (the On Deck list).
///
/// Every path degrades to an empty result when no server session is available —
/// the intents themselves throw the user-facing "not signed in" error.
struct MediaItemEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [MediaItemEntity] {
        guard PlaybackPreferences.systemMediaSuggestionsEnabled() else { return [] }
        guard await SystemEntryRouter.shared.ensureBrowseReady(),
              let ctx = SystemEntryRouter.shared.browseContext,
              let appModel = SystemEntryRouter.shared.appModel else { return [] }
        var found: [MediaItemEntity] = []
        for identifier in identifiers {
            let routeKey = MediaSearchIdentifier.routeKey(from: identifier)
            guard routeKey.backend == ctx.backend else { continue }
            if let namespace = routeKey.serverNamespace,
               namespace != BackendScopedMediaID.serverNamespace(ctx.server) {
                continue
            }
            let result = await DetailMetadataLoader.load(ratingKey: routeKey.ratingKey,
                                                         backend: ctx.backend,
                                                         appModel: appModel)
            if let item = result.item {
                found.append(MediaItemEntity(item: item, backend: ctx.backend, server: ctx.server))
            }
        }
        return found
    }

    @MainActor
    func entities(matching string: String) async throws -> [MediaItemEntity] {
        guard PlaybackPreferences.systemMediaSuggestionsEnabled() else { return [] }
        guard await SystemEntryRouter.shared.ensureBrowseReady(),
              let ctx = SystemEntryRouter.shared.browseContext,
              let appModel = SystemEntryRouter.shared.appModel else { return [] }
        // This first system surface opens video DetailView, so keep music out;
        // music has its own in-app navigation paths.
        let matches: [MediaItem]
        switch ctx.backend {
        case .plex:
            guard let service = plexBrowseService(context: ctx),
                  let hubs = try? await service.search(query: string) else { return [] }
            matches = hubs.flatMap(\.metadata)
        case .jellyfin:
            guard let catalogRepository = SystemEntryRouter.shared.libraryCatalogRepository,
                  let client = try? MediaBrowserCatalogClient(appModel: appModel),
                  let request = try? catalogRepository.request(appModel: appModel),
                  let catalog = try? await catalogRepository.catalog(for: request),
                  client.matches(catalog), client.isCurrent(in: appModel) else { return [] }
            let views = catalog.descriptors.compactMap(\.mediaBrowserLink)
            let results = try? await client.searchResults(query: string, views: views,
                                                          limitPerLibrary: 15)
            guard client.isCurrent(in: appModel), !Task.isCancelled else { return [] }
            matches = results?.groups.flatMap(\.hubs).flatMap(\.metadata) ?? []
        case .emby:
            guard let catalogRepository = SystemEntryRouter.shared.libraryCatalogRepository,
                  let client = try? MediaBrowserCatalogClient(appModel: appModel),
                  let request = try? catalogRepository.request(appModel: appModel),
                  let catalog = try? await catalogRepository.catalog(for: request),
                  client.matches(catalog), client.isCurrent(in: appModel) else { return [] }
            let views = catalog.descriptors.compactMap(\.mediaBrowserLink)
            let results = try? await client.searchResults(query: string, views: views,
                                                          limitPerLibrary: 15)
            guard client.isCurrent(in: appModel), !Task.isCancelled else { return [] }
            matches = results?.groups.flatMap(\.hubs).flatMap(\.metadata) ?? []
        }
        var seen = Set<String>()
        return matches
            .filter { !$0.isMusic && seen.insert($0.ratingKey).inserted }
            .prefix(15)
            .map { MediaItemEntity(item: $0, backend: ctx.backend, server: ctx.server) }
    }

    /// What Shortcuts offers before the user types: the On Deck list — the items
    /// someone is most likely to ask Siri to play.
    @MainActor
    func suggestedEntities() async throws -> [MediaItemEntity] {
        guard PlaybackPreferences.systemMediaSuggestionsEnabled() else { return [] }
        guard await SystemEntryRouter.shared.ensureBrowseReady(),
              let ctx = SystemEntryRouter.shared.browseContext,
              let appModel = SystemEntryRouter.shared.appModel else { return [] }
        let suggestions: [MediaItem]
        switch ctx.backend {
        case .plex:
            guard let service = plexBrowseService(context: ctx),
                  let items = try? await service.onDeck() else { return [] }
            suggestions = items
        case .jellyfin:
            let service = JellyfinBrowseService(appModel: appModel)
            let resume = (try? await service.resumeItems(limit: 10)) ?? []
            suggestions = resume.isEmpty ? ((try? await service.nextUp(limit: 10)) ?? []) : resume
        case .emby:
            let service = EmbyBrowseService(appModel: appModel)
            let resume = (try? await service.resumeItems(limit: 10)) ?? []
            suggestions = resume.isEmpty ? ((try? await service.nextUp(limit: 10)) ?? []) : resume
        }
        return suggestions
            .filter { !$0.isMusic }
            .prefix(10)
            .map { MediaItemEntity(item: $0, backend: ctx.backend, server: ctx.server) }
    }
}

@MainActor
private func plexBrowseService(context: SystemEntryRouter.BrowseContext) -> PlexBrowseService? {
    try? PlexBrowseService(
        session: BackendSession(kind: .plex, baseURL: context.server, token: context.token),
        identity: context.identity,
        client: context.client
    )
}
