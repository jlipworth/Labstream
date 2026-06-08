import SwiftUI
import PlexKit

/// Home tab: the server's hubs (`GET /hubs`) rendered as horizontal poster rails,
/// Swiftfin-style. Each rail is one `Hub`; tapping a poster opens `DetailView`.
struct HomeView: View {
    @Environment(AppModel.self) private var appModel

    @State private var hubs: [Hub] = []
    @State private var loadState: LoadState = .idle

    enum LoadState: Equatable {
        case idle, loading, loaded, failed(String)
    }

    var body: some View {
        ScrollView {
            switch loadState {
            case .idle, .loading:
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, minHeight: 300)
            case .failed(let message):
                ContentUnavailableView("Couldn’t load Home",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(message))
                .frame(maxWidth: .infinity, minHeight: 300)
            case .loaded:
                if hubs.isEmpty {
                    ContentUnavailableView("Nothing here yet",
                                           systemImage: "house",
                                           description: Text("No hubs returned by the server."))
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    LazyVStack(alignment: .leading, spacing: 32) {
                        ForEach(hubs.filter { !$0.metadata.isEmpty }) { hub in
                            HubRail(hub: hub)
                        }
                    }
                    .padding(.vertical, 24)
                }
            }
        }
        .navigationTitle("Home")
        .navigationDestination(for: MediaItem.self) { item in
            DetailView(item: item)
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let server = appModel.serverBaseURL, let token = appModel.token else {
            loadState = .failed("No server selected.")
            return
        }
        loadState = .loading
        let req = BrowseAPI.hubs(server: server, token: token, identity: appModel.identity)
        do {
            let resp = try await appModel.client.send(req, as: HubsResponse.self)
            hubs = resp.mediaContainer.hub
            loadState = .loaded
        } catch {
            loadState = .failed(friendlyMessage(error))
        }
    }
}

/// One horizontal rail of posters for a hub.
private struct HubRail: View {
    let hub: Hub

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(hub.title)
                .font(.title2.bold())
                .padding(.horizontal, 24)

            ScrollView(.horizontal) {
                LazyHStack(spacing: 20) {
                    ForEach(hub.metadata) { item in
                        NavigationLink(value: item) {
                            PosterCell(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }
}

/// A poster + title cell used in rails and grids.
struct PosterCell: View {
    let item: MediaItem
    var width: CGFloat = 180
    var height: CGFloat = 270

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PosterImage(path: item.thumb, width: width, height: height)
            Text(item.title)
                .font(.headline)
                .lineLimit(1)
            if let year = item.year {
                Text(String(year))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: width)
    }
}

/// Map a thrown error (often `PlexError`) to a short user-facing string.
func friendlyMessage(_ error: Error) -> String {
    if let plex = error as? PlexError {
        switch plex {
        case .unauthorized: return "Your session expired. Please sign in again."
        case .serverUnreachable: return "Couldn’t reach the server."
        case .http(let code): return "Server error (HTTP \(code))."
        case .decoding: return "Unexpected response from the server."
        }
    }
    return error.localizedDescription
}

// MARK: - MediaItem Hashable for navigationDestination

extension MediaItem: @retroactive Hashable {
    public static func == (lhs: MediaItem, rhs: MediaItem) -> Bool {
        lhs.ratingKey == rhs.ratingKey
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ratingKey)
    }
}
