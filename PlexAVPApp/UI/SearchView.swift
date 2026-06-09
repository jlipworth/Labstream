import SwiftUI
import PlexKit

/// Search tab: queries `GET /hubs/search?query=` and renders the grouped hub
/// results into the same Detail flow as browse. Debounced via `.task(id:)`.
struct SearchView: View {
    @Environment(AppModel.self) private var appModel

    @State private var query = ""
    @State private var hubs: [Hub] = []
    @State private var loadState: HomeView.LoadState = .idle

    var body: some View {
        ScrollView {
            switch loadState {
            case .idle:
                ContentUnavailableView("Search your libraries",
                                       systemImage: "magnifyingglass",
                                       description: Text("Find movies, shows, and more."))
                .frame(maxWidth: .infinity, minHeight: 300)
            case .loading:
                ProgressView("Searching…")
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: 360)
            case .failed(let message):
                ContentUnavailableView("Search failed",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(message))
                .frame(maxWidth: .infinity, minHeight: 300)
            case .loaded:
                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    LazyVStack(alignment: .leading, spacing: DS.Space.xxxl) {
                        ForEach(results) { hub in
                            SearchHubSection(hub: hub)
                        }
                    }
                    .padding(.vertical, DS.Space.xl)
                }
            }
        }
        .navigationTitle("Search")
        .navigationDestination(for: MediaItem.self) { item in
            DetailView(item: item)
        }
        .searchable(text: $query, prompt: "Movies, shows, people…")
        .task(id: query) {
            await runSearch()
        }
    }

    /// Only hubs that carry playable/openable metadata, with music hidden (#15): music
    /// items are stripped and any hub left empty is dropped (see `Array.hidingMusic`).
    private var results: [Hub] {
        hubs.hidingMusic
    }

    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            hubs = []
            loadState = .idle
            return
        }
        // Light debounce so we don't fire a request per keystroke.
        try? await Task.sleep(for: .milliseconds(300))
        if Task.isCancelled { return }

        guard let server = appModel.serverBaseURL, let token = appModel.serverToken else {
            loadState = .failed("No server selected.")
            return
        }
        loadState = .loading
        let req = BrowseAPI.search(server: server, token: token,
                                   identity: appModel.identity, query: trimmed)
        do {
            let resp = try await appModel.client.send(req, as: HubsResponse.self)
            if Task.isCancelled { return }
            hubs = resp.mediaContainer.hub
            loadState = .loaded
        } catch {
            if Task.isCancelled { return }
            loadState = .failed(friendlyMessage(error))
        }
    }
}

/// One titled section of search results (a hub) rendered as a horizontal rail.
private struct SearchHubSection: View {
    let hub: Hub

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Text(hub.title)
                .font(.title2.bold())
                .padding(.horizontal, DS.Space.xxl)

            ScrollView(.horizontal) {
                LazyHStack(spacing: DS.Space.xl) {
                    ForEach(hub.metadata) { item in
                        NavigationLink(value: item) {
                            PosterCell(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, DS.Space.xxl)
                .padding(.vertical, DS.Space.sm)
            }
            .scrollClipDisabled()
        }
    }
}
