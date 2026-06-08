import SwiftUI
import PlexKit

/// Libraries tab: lists the server's sections (`GET /library/sections`); selecting
/// one pushes a `LibraryGridView` of its items.
struct LibrariesView: View {
    @Environment(AppModel.self) private var appModel

    @State private var sections: [PlexSection] = []
    @State private var loadState: HomeView.LoadState = .idle

    var body: some View {
        Group {
            switch loadState {
            case .idle, .loading:
                ProgressView("Loading…")
            case .failed(let message):
                ContentUnavailableView("Couldn’t load libraries",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(message))
            case .loaded:
                if sections.isEmpty {
                    ContentUnavailableView("No libraries",
                                           systemImage: "rectangle.stack",
                                           description: Text("This server has no libraries."))
                } else {
                    List(sections) { section in
                        NavigationLink(value: section) {
                            Label(section.title, systemImage: icon(for: section.type))
                                .font(.title3)
                        }
                    }
                }
            }
        }
        .navigationTitle("Libraries")
        .navigationDestination(for: PlexSection.self) { section in
            LibraryGridView(section: section)
        }
        .navigationDestination(for: MediaItem.self) { item in
            DetailView(item: item)
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func icon(for type: String) -> String {
        switch type {
        case "movie": return "film"
        case "show": return "tv"
        case "artist": return "music.note"
        case "photo": return "photo"
        default: return "rectangle.stack"
        }
    }

    private func load() async {
        guard let server = appModel.serverBaseURL, let token = appModel.token else {
            loadState = .failed("No server selected.")
            return
        }
        loadState = .loading
        let req = BrowseAPI.sections(server: server, token: token, identity: appModel.identity)
        do {
            let resp = try await appModel.client.send(req, as: SectionsResponse.self)
            sections = resp.mediaContainer.directory
            loadState = .loaded
        } catch {
            loadState = .failed(friendlyMessage(error))
        }
    }
}

extension PlexSection: @retroactive Hashable {
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
    public func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

/// Poster grid for a single library section (`GET /library/sections/<key>/all`).
struct LibraryGridView: View {
    let section: PlexSection

    @Environment(AppModel.self) private var appModel

    @State private var items: [MediaItem] = []
    @State private var loadState: HomeView.LoadState = .idle

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 24)]

    var body: some View {
        ScrollView {
            switch loadState {
            case .idle, .loading:
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, minHeight: 300)
            case .failed(let message):
                ContentUnavailableView("Couldn’t load \(section.title)",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(message))
                .frame(maxWidth: .infinity, minHeight: 300)
            case .loaded:
                LazyVGrid(columns: columns, spacing: 32) {
                    ForEach(items) { item in
                        NavigationLink(value: item) {
                            PosterCell(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(24)
            }
        }
        .navigationTitle(section.title)
        .task { await load() }
    }

    private func load() async {
        guard let server = appModel.serverBaseURL, let token = appModel.token else {
            loadState = .failed("No server selected.")
            return
        }
        loadState = .loading
        let req = BrowseAPI.sectionItems(server: server, token: token,
                                         identity: appModel.identity, sectionKey: section.key)
        do {
            let resp = try await appModel.client.send(req, as: MetadataResponse.self)
            items = resp.mediaContainer.metadata
            loadState = .loaded
        } catch {
            loadState = .failed(friendlyMessage(error))
        }
    }
}
