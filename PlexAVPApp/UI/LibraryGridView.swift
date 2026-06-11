import SwiftUI
import PMSKit

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
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                            Label {
                                Text(section.title).font(.title3)
                            } icon: {
                                Image(systemName: icon(for: section.type))
                                    .foregroundStyle(.tint)
                            }
                            .padding(.vertical, DS.Space.xs)
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
        .refreshable { await load(force: true) }
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

    private func load(force: Bool = false) async {
        // `.task` re-fires on pop-back; the section list doesn't change mid-session,
        // so only first load and pull-to-refresh fetch.
        if !force, case .loaded = loadState { return }
        guard let server = appModel.serverBaseURL, let token = appModel.serverToken else {
            loadState = .failed("No server selected.")
            return
        }
        loadState = .loading
        let req = BrowseAPI.sections(server: server, token: token, identity: appModel.identity)
        do {
            let resp = try await appModel.client.send(req, as: SectionsResponse.self)
            // Hide music libraries until a dedicated Plexamp-style experience exists (#15).
            sections = resp.mediaContainer.directory.filter { !$0.isMusic }
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

    private let columns = [GridItem(.adaptive(minimum: DS.Poster.gridMin, maximum: DS.Poster.gridMax),
                                    spacing: DS.Space.xl)]

    var body: some View {
        ScrollView {
            switch loadState {
            case .idle, .loading:
                SkeletonGrid()
            case .failed(let message):
                ContentUnavailableView("Couldn’t load \(section.title)",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(message))
                .frame(maxWidth: .infinity, minHeight: 360)
            case .loaded:
                if items.isEmpty {
                    ContentUnavailableView("Empty library",
                                           systemImage: "rectangle.stack",
                                           description: Text("No items in \(section.title)."))
                    .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    LazyVGrid(columns: columns, spacing: DS.Space.xxl) {
                        ForEach(items) { item in
                            NavigationLink(value: item) {
                                PosterCell(item: item, width: DS.Poster.gridMin)
                            }
                            .buttonStyle(.card)
                        }
                    }
                    .padding(DS.Space.xl)
                }
            }
        }
        .navigationTitle(section.title)
        .task { await load() }
    }

    private func load() async {
        // `.task` re-fires on pop-back from an item; reloading the whole grid then
        // would dump the scroll position the user is returning to. Load once.
        if case .loaded = loadState { return }
        guard let server = appModel.serverBaseURL, let token = appModel.serverToken else {
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

/// Shimmering poster grid shown while a library section loads, so the screen keeps
/// its layout (and the same gutters as the real grid) rather than flashing a spinner.
private struct SkeletonGrid: View {
    private let columns = [GridItem(.adaptive(minimum: DS.Poster.gridMin, maximum: DS.Poster.gridMax),
                                    spacing: DS.Space.xl)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: DS.Space.xxl) {
            ForEach(0..<12, id: \.self) { _ in
                RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous)
                    .fill(.regularMaterial)
                    .frame(width: DS.Poster.gridMin, height: DS.Poster.height(for: DS.Poster.gridMin))
                    .overlay { ShimmerView() }
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous))
            }
        }
        .padding(DS.Space.xl)
    }
}
