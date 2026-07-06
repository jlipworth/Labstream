import SwiftUI
import PMSKit

/// Browser for a backend container (`show`, `season`, or collection/BoxSet).
///
/// - A `show` lists its seasons; selecting one pushes another `DetailView`, which (since a
///   season is itself a container) recurses into this browser to show that season's
///   episodes.
/// - A `season` lists its episodes directly.
///
/// Selecting an episode pushes `DetailView(item: episode)` — a LEAF — whose Play/Download/
/// Mark actions target the episode's own ratingKey (the item that owns a Media/Part),
/// which is the fix for the series-download HTTP 400.
///
/// TV children come from `GET /library/metadata/{ratingKey}/children` via `BrowseAPI.children`.
/// Collection children use backend-specific collection item reads (Plex
/// `/library/collections/{id}/items`; Jellyfin/Emby generic Items + ParentId).
struct ContainerBrowserView: View {
    let container: MediaItem

    @Environment(AppModel.self) private var appModel
    @Environment(\.labstreamCompactWidth) private var compactWidth

    @State private var children: [MediaItem] = []
    @State private var loadState: BrowseLoadState = .idle

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: DS.Poster.gridMin(compact: compactWidth),
                            maximum: DS.Poster.gridMax(compact: compactWidth)),
                  spacing: DS.gridGutter(compact: compactWidth))]
    }

    /// A season lists episodes (drawn as wide episode rows); a show lists seasons (posters).
    private var childrenAreEpisodes: Bool { container.kind == .season }
    private var isCollection: Bool { container.isCollection }

    var body: some View {
        ScrollView {
            switch loadState {
            case .idle, .loading:
                ProgressView("Loading…")
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: 360)
            case .failed(let message):
                ContentUnavailableView("Couldn’t load \(container.title)",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(message))
                    .frame(maxWidth: .infinity, minHeight: 360)
            case .loaded:
                if children.isEmpty {
                    ContentUnavailableView(emptyTitle,
                                           systemImage: emptySystemImage,
                                           description: Text(emptyDescription))
                        .frame(maxWidth: .infinity, minHeight: 360)
                } else if childrenAreEpisodes {
                    episodeList
                } else {
                    posterGrid
                }
            }
        }
        .navigationTitle(navigationTitle)
        .id(container.ratingKey)
        .task(id: container.ratingKey) { await load() }
    }

    /// Seasons/collection items as a poster grid (same look as a library section).
    private var posterGrid: some View {
        LazyVGrid(columns: columns, spacing: compactWidth ? DS.Space.lg : DS.Space.xxl) {
            ForEach(Array(children.enumerated()), id: \.element.containerRowIdentity) { _, child in
                NavigationLink(value: child) {
                    PosterCell(item: child, width: DS.Poster.gridMin(compact: compactWidth))
                }
                .cardLink()
                .videoCardContextMenu(for: season)
            }
        }
        .padding(DS.pagePadding(compact: compactWidth))
    }

    private var navigationTitle: String {
        if isCollection { return container.title }
        return container.grandparentTitle ?? container.title
    }

    private var emptyTitle: String {
        if isCollection { return "No collection items" }
        return childrenAreEpisodes ? "No episodes" : "No seasons"
    }

    private var emptySystemImage: String {
        isCollection ? "rectangle.stack" : "tv"
    }

    private var emptyDescription: String {
        if isCollection {
            return "This server did not return any items for \(container.title)."
        }
        return "Nothing to show for \(container.title)."
    }

    /// Episodes as a vertical list of wide rows, each reading
    /// "S{parentIndex}E{index} · {title}" — Plex/Emby style.
    private var episodeList: some View {
        LazyVStack(spacing: DS.Space.md) {
            ForEach(Array(children.enumerated()), id: \.element.containerRowIdentity) { _, episode in
                NavigationLink(value: episode) {
                    EpisodeRow(episode: episode)
                }
                .cardLink(cornerRadius: DS.Radius.card)
                .videoCardContextMenu(for: episode)
            }
        }
        .padding(DS.pagePadding(compact: compactWidth))
    }

    private func recordContainerChildrenDiagnostics(_ loaded: [MediaItem],
                                                    normalized: [MediaItem],
                                                    backend: String) {
        guard childrenAreEpisodes else { return }
        let summary = BrowseDiagnostics.containerChildren(rawItems: loaded,
                                                          normalizedItems: normalized,
                                                          backend: backend,
                                                          container: container,
                                                          childrenAreEpisodes: childrenAreEpisodes)
        AppDiagnostics.record(.browse, "container.children", fields: summary.fields)
        #if DEBUG
        NSLog("%@", "container.children \(summary.consoleLine)")
        #endif
    }

    private func load() async {
        // Always reload when this browser appears. Season/episode payloads are small, and this
        // avoids keeping a stale, duplicated child snapshot alive across navigation restoration
        // or backend/model changes.
        children = []
        if appModel.activeBackend == .jellyfin {
            loadState = .loading
            do {
                let service = JellyfinBrowseService(appModel: appModel)
                let loaded: [MediaItem]
                if isCollection {
                    loaded = try await service.collectionItems(collectionId: container.ratingKey)
                } else {
                    loaded = try await service.items(parentId: container.ratingKey, recursive: false)
                }
                let normalized = loaded.normalizedForContainerBrowser(childrenAreEpisodes: childrenAreEpisodes)
                recordContainerChildrenDiagnostics(loaded, normalized: normalized, backend: "Jellyfin")
                children = normalized
                loadState = .loaded
            } catch {
                loadState = .failed(friendlyMessage(error))
            }
            return
        }
        if appModel.activeBackend == .emby {
            loadState = .loading
            do {
                let service = EmbyBrowseService(appModel: appModel)
                let loaded: [MediaItem]
                if isCollection {
                    loaded = try await service.collectionItems(collectionId: container.ratingKey)
                } else {
                    loaded = try await service.items(parentId: container.ratingKey, recursive: false)
                }
                let normalized = loaded.normalizedForContainerBrowser(childrenAreEpisodes: childrenAreEpisodes)
                recordContainerChildrenDiagnostics(loaded, normalized: normalized, backend: "Emby")
                children = normalized
                loadState = .loaded
            } catch {
                loadState = .failed(friendlyMessage(error))
            }
            return
        }

        guard let service = try? PlexBrowseService(appModel: appModel) else {
            loadState = .failed("No server selected.")
            return
        }
        loadState = .loading
        do {
            let loaded = isCollection
                ? try await service.collectionItems(collectionId: container.ratingKey)
                : try await service.children(ratingKey: container.ratingKey)
            let normalized = loaded.normalizedForContainerBrowser(childrenAreEpisodes: childrenAreEpisodes)
            recordContainerChildrenDiagnostics(loaded, normalized: normalized, backend: "Plex")
            children = normalized
            loadState = .loaded
        } catch {
            loadState = .failed(friendlyMessage(error))
        }
    }
}

private extension MediaItem {
    /// Stable per-row identity for season/episode container browsers. Keep backend id in the
    /// SwiftUI identity so taps still route to the exact item when rows are legitimately distinct.
    var containerRowIdentity: String {
        [ratingKey, type, parentIndex.map(String.init), index.map(String.init), title]
            .compactMap { $0 }
            .joined(separator: "|")
    }

    /// Visible episode identity for de-duping server duplicates. Jellyfin can expose multiple
    /// physical entries/versions with distinct item ids but identical S/E/title/artwork; a season
    /// browser should show one row for that episode, not four indistinguishable rows.
    var episodeDisplayIdentity: String {
        [parentIndex.map(String.init), index.map(String.init), title]
            .compactMap { $0 }
            .joined(separator: "|")
    }
}

private extension Array where Element == MediaItem {
    /// Normalize a show/season child payload at the UI boundary: sort episode lists by numeric
    /// S/E order and collapse visible duplicate episode rows. Use display identity for episodes
    /// (S/E/title) rather than backend id, because duplicate files can arrive as separate Jellyfin
    /// items while being impossible to distinguish in this list.
    func normalizedForContainerBrowser(childrenAreEpisodes: Bool) -> [MediaItem] {
        let ordered = childrenAreEpisodes ? sortedByEpisodeOrder() : self
        var seen = Set<String>()
        return ordered.filter { item in
            let key = childrenAreEpisodes ? item.episodeDisplayIdentity : item.containerRowIdentity
            return seen.insert(key).inserted
        }
    }
}

/// A wide episode row used inside a season: thumbnail + "S{x}E{y} · Title" + summary,
/// with a continue-watching sliver when the episode carries a resume offset.
struct EpisodeRow: View {
    let episode: MediaItem
    @Environment(\.labstreamCompactWidth) private var compactWidth

    var body: some View {
        // Shrink the 16:9 thumbnail on compact width so the title/summary column
        // isn't squeezed to a sliver on a narrow phone.
        let thumbWidth: CGFloat = compactWidth ? 128 : 200
        let thumbHeight = round(thumbWidth * 9 / 16)
        HStack(alignment: .top, spacing: compactWidth ? DS.Space.md : DS.Space.lg) {
            PosterImage(path: episode.thumb ?? episode.parentThumb,
                        width: thumbWidth,
                        height: thumbHeight,
                        cornerRadius: DS.Radius.poster)
                .overlay(alignment: .bottom) { progressSliver }

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(episodeTitle)
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                if let summary = episode.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Space.md)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        // NOTE: highlight comes from the wrapping link's `.cardLink(cornerRadius: DS.Radius.card)`
        // — a custom ButtonStyle here misroutes pinches to neighboring rows (DEVELOPMENT.md).
    }

    /// "S{parentIndex}E{index} · {title}", falling back to the bare title.
    private var episodeTitle: String {
        if let code = episode.seasonEpisodeCode {
            return "\(code) · \(episode.title)"
        }
        return episode.title
    }

    private var progressSliver: some View {
        ProgressSliver(offset: episode.viewOffset, duration: episode.duration)
    }
}
