import AppIntents
import PMSKit

/// An App Intents entity wrapping one library item. Current suggestions still use the
/// legacy Plex `ratingKey` identifier, while resolution accepts backend-scoped ids too.
/// This is what shows up as the "Title" parameter in
/// Shortcuts and in "Play <title> on Labstream" Siri phrases.
///
/// Deliberately a snapshot of display fields only — intents re-fetch authoritative
/// metadata by ratingKey at perform time, so a stale snapshot can't mis-play.
struct MediaItemEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Media Item")
    static let defaultQuery = MediaItemEntityQuery()

    /// System-entry identifier. Current Plex-only suggestions are legacy bare ratingKeys;
    /// future backend-scoped ids parse through `MediaSearchIdentifier.routeKey`.
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

    init(item: MediaItem) {
        self.id = item.ratingKey
        self.type = item.type
        if item.kind == .episode {
            // "Episode title" + "Show · S1E3" mirrors the poster-cell treatment.
            self.title = item.title
            let context = [item.grandparentTitle, item.seasonEpisodeCode]
                .compactMap { $0 }.joined(separator: " · ")
            self.subtitle = context.isEmpty ? nil : context
        } else {
            self.title = item.title
            self.subtitle = item.year.map(String.init)
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
              let ctx = SystemEntryRouter.shared.browseContext else { return [] }
        var found: [MediaItemEntity] = []
        for identifier in identifiers {
            let routeKey = MediaSearchIdentifier.routeKey(from: identifier)
            guard routeKey.backend == .plex else { continue }
            if let namespace = routeKey.serverNamespace,
               namespace != BackendScopedMediaID.serverNamespace(ctx.server) {
                continue
            }
            let req = BrowseAPI.metadata(server: ctx.server, token: ctx.token,
                                         identity: ctx.identity, ratingKey: routeKey.ratingKey)
            if let resp = try? await ctx.client.send(req, as: MetadataResponse.self),
               let item = resp.mediaContainer.metadata.first {
                found.append(MediaItemEntity(item: item))
            }
        }
        return found
    }

    @MainActor
    func entities(matching string: String) async throws -> [MediaItemEntity] {
        guard PlaybackPreferences.systemMediaSuggestionsEnabled() else { return [] }
        guard await SystemEntryRouter.shared.ensureBrowseReady(),
              let ctx = SystemEntryRouter.shared.browseContext else { return [] }
        let req = BrowseAPI.search(server: ctx.server, token: ctx.token,
                                   identity: ctx.identity, query: string)
        guard let resp = try? await ctx.client.send(req, as: HubsResponse.self) else { return [] }
        // This first system surface opens video DetailView, so keep music out;
        // music has its own in-app navigation paths.
        return resp.mediaContainer.hub
            .flatMap(\.metadata)
            .filter { !$0.isMusic }
            .prefix(15)
            .map(MediaItemEntity.init)
    }

    /// What Shortcuts offers before the user types: the On Deck list — the items
    /// someone is most likely to ask Siri to play.
    @MainActor
    func suggestedEntities() async throws -> [MediaItemEntity] {
        guard PlaybackPreferences.systemMediaSuggestionsEnabled() else { return [] }
        guard await SystemEntryRouter.shared.ensureBrowseReady(),
              let ctx = SystemEntryRouter.shared.browseContext else { return [] }
        let req = BrowseAPI.onDeck(server: ctx.server, token: ctx.token, identity: ctx.identity)
        guard let resp = try? await ctx.client.send(req, as: MetadataResponse.self) else { return [] }
        return resp.mediaContainer.metadata
            .filter { !$0.isMusic }
            .prefix(10)
            .map(MediaItemEntity.init)
    }
}
