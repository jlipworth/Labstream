import SwiftUI
import PMSKit

/// Libraries tab: lists the server's sections (`GET /library/sections`); selecting
/// one pushes a `LibraryGridView` of its items.
struct LibrariesView: View {
    @Environment(AppModel.self) private var appModel

    @State private var sections: [PlexSection] = []
    @State private var jellyfinViews: [JellyfinLibraryLink] = []
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
                if appModel.activeBackend == .jellyfin {
                    jellyfinLibrariesList
                } else if sections.isEmpty {
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
        .navigationDestination(for: JellyfinLibraryLink.self) { view in
            LibraryGridView(jellyfin: view)
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

    @ViewBuilder
    private var jellyfinLibrariesList: some View {
        if jellyfinViews.isEmpty {
            ContentUnavailableView("No Jellyfin libraries",
                                   systemImage: "rectangle.stack",
                                   description: Text("This Jellyfin user has no visible libraries."))
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 340),
                                    spacing: DS.Space.xl)],
                          spacing: DS.Space.xl) {
                    ForEach(jellyfinViews) { view in
                        NavigationLink(value: view) {
                            JellyfinLibraryCard(view: view)
                        }
                        .cardLink(cornerRadius: DS.Radius.card)
                    }
                }
                .padding(DS.Space.xl)
            }
        }
    }

    private func load(force: Bool = false) async {
        // `.task` re-fires on pop-back; the section list doesn't change mid-session,
        // so only first load and pull-to-refresh fetch.
        if !force, case .loaded = loadState { return }
        loadState = .loading

        if appModel.activeBackend == .jellyfin {
            do {
                jellyfinViews = try await JellyfinBrowseService(appModel: appModel).userViewLinks()
                loadState = .loaded
            } catch {
                loadState = .failed(friendlyMessage(error))
            }
            return
        }

        guard let server = appModel.serverBaseURL, let token = appModel.serverToken else {
            loadState = .failed("No server selected.")
            return
        }
        let req = BrowseAPI.sections(server: server, token: token, identity: appModel.identity)
        do {
            let resp = try await appModel.client.send(req, as: SectionsResponse.self)
            // Music sections deliberately stay out of this tab even after the #17
            // un-hide: the Music tab is their dedicated entry point and listing the
            // section twice is noise (MUSIC-DESIGN §2 — a considered exception to
            // #17's original "remove the !isMusic filter" checklist item).
            sections = resp.mediaContainer.directory.filter { !$0.isMusic }
            loadState = .loaded
        } catch {
            loadState = .failed(friendlyMessage(error))
        }
    }
}

enum LibraryGridSource: Hashable {
    case plex(PlexSection)
    case jellyfin(JellyfinLibraryLink)

    var title: String {
        switch self {
        case .plex(let section): return section.title
        case .jellyfin(let view): return view.title
        }
    }
}

extension PlexSection: @retroactive Hashable {
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
    public func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

/// Poster grid for a single library section (`GET /library/sections/<key>/all`).
struct LibraryGridView: View {
    let source: LibraryGridSource

    @Environment(AppModel.self) private var appModel

    @State private var slots: [MediaItem?] = []
    @State private var firstCharacters: [LibraryFirstCharacter] = []
    @State private var loadState: HomeView.LoadState = .idle
    @State private var loadingPages: Set<Int> = []

    private let columns = [GridItem(.adaptive(minimum: DS.Poster.gridMin, maximum: DS.Poster.gridMax),
                                    spacing: DS.Space.xl)]
    private let pageSize = 200

    init(section: PlexSection) {
        self.source = .plex(section)
    }

    init(jellyfin view: JellyfinLibraryLink) {
        self.source = .jellyfin(view)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                switch loadState {
                case .idle, .loading:
                    SkeletonGrid()
                case .failed(let message):
                    ContentUnavailableView("Couldn’t load \(source.title)",
                                           systemImage: "exclamationmark.triangle",
                                           description: Text(message))
                        .frame(maxWidth: .infinity, minHeight: 360)
                case .loaded:
                    if slots.isEmpty {
                        ContentUnavailableView("Empty library",
                                               systemImage: "rectangle.stack",
                                               description: Text("No items in \(source.title)."))
                            .frame(maxWidth: .infinity, minHeight: 360)
                    } else {
                        LazyVGrid(columns: columns, spacing: DS.Space.xxl) {
                            ForEach(slots.indices, id: \.self) { index in
                                if let item = slots[index] {
                                    NavigationLink(value: item) {
                                        PosterCell(item: item, width: DS.Poster.gridMin)
                                    }
                                    .cardLink()
                                    .id(index)
                                } else {
                                    LibraryPlaceholderPoster()
                                        .id(index)
                                        .onAppear {
                                            Task { await loadPage(containing: index) }
                                        }
                                }
                            }
                        }
                        .padding(DS.Space.xl)
                    }
                }
            }
            .overlay(alignment: .trailing) {
                if firstCharacters.count > 1, case .loaded = loadState {
                    LibraryAlphabetRail(entries: firstCharacters) { entry in
                        Task {
                            await loadPage(containing: entry.offset)
                            await MainActor.run {
                                withAnimation(.snappy(duration: 0.25)) {
                                    proxy.scrollTo(entry.offset, anchor: .top)
                                }
                            }
                        }
                    }
                    .padding(.trailing, 10)
                }
            }
        }
        .navigationTitle(source.title)
        .task { await load() }
        .refreshable { await load(force: true) }
    }

    private func load(force: Bool = false) async {
        // `.task` re-fires on pop-back from an item; reloading the whole grid then
        // would dump the scroll position the user is returning to. Load once.
        if !force, case .loaded = loadState { return }
        loadState = .loading
        loadingPages = []
        firstCharacters = []

        switch source {
        case .plex(let section):
            await loadPlex(section: section)
        case .jellyfin(let view):
            await loadJellyfin(view: view)
        }
    }

    private func loadPlex(section: PlexSection) async {
        guard let server = appModel.serverBaseURL, let token = appModel.serverToken else {
            loadState = .failed("No server selected.")
            return
        }
        let req = BrowseAPI.sectionItems(server: server, token: token,
                                         identity: appModel.identity, sectionKey: section.key,
                                         containerStart: 0, containerSize: pageSize,
                                         sort: "titleSort")
        do {
            async let itemsResponse = appModel.client.send(req, as: MetadataResponse.self)
            async let initialsResponse: FirstCharacterResponse? = loadFirstCharacters(server: server,
                                                                                      token: token,
                                                                                      section: section)

            let resp = try await itemsResponse
            let page = resp.mediaContainer.metadata
            let total = max(resp.mediaContainer.totalSize ?? page.count, page.count)
            var fresh = [MediaItem?](repeating: nil, count: total)
            for (i, item) in page.enumerated() where fresh.indices.contains(i) {
                fresh[i] = item
            }
            slots = fresh
            firstCharacters = (await initialsResponse)?.libraryEntries(totalSize: total) ?? []
            loadState = .loaded
        } catch {
            loadState = .failed(friendlyMessage(error))
        }
    }

    private func loadJellyfin(view: JellyfinLibraryLink) async {
        do {
            let items = try await JellyfinBrowseService(appModel: appModel).items(parentId: view.id, recursive: false)
            slots = items.map(Optional.some)
            loadState = .loaded
        } catch {
            loadState = .failed(friendlyMessage(error))
        }
    }

    private func loadFirstCharacters(server: URL, token: String,
                                     section: PlexSection) async -> FirstCharacterResponse? {
        let req = BrowseAPI.firstCharacters(server: server, token: token,
                                            identity: appModel.identity, sectionKey: section.key)
        return try? await appModel.client.send(req, as: FirstCharacterResponse.self)
    }

    private func loadPage(containing index: Int) async {
        guard case .plex(let section) = source,
              slots.indices.contains(index),
              let server = appModel.serverBaseURL,
              let token = appModel.serverToken
        else { return }
        let page = index / pageSize
        guard !loadingPages.contains(page) else { return }
        loadingPages.insert(page)
        let start = page * pageSize
        let req = BrowseAPI.sectionItems(server: server, token: token,
                                         identity: appModel.identity, sectionKey: section.key,
                                         containerStart: start, containerSize: pageSize,
                                         sort: "titleSort")
        do {
            let resp = try await appModel.client.send(req, as: MetadataResponse.self)
            for (i, item) in resp.mediaContainer.metadata.enumerated()
            where slots.indices.contains(start + i) {
                slots[start + i] = item
            }
        } catch {
            // Non-fatal: remove the in-flight mark so the placeholder retries when it reappears.
        }
        loadingPages.remove(page)
    }
}

private struct LibraryPlaceholderPoster: View {
    var body: some View {
        RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous)
            .fill(.regularMaterial)
            .frame(width: DS.Poster.gridMin, height: DS.Poster.height(for: DS.Poster.gridMin))
            .overlay { ShimmerView() }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous))
    }
}

private struct LibraryAlphabetRail: View {
    let entries: [LibraryFirstCharacter]
    let onPick: (LibraryFirstCharacter) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(entries) { entry in
                Button {
                    onPick(entry)
                } label: {
                    Text(entry.display)
                        .font(.caption2.weight(.semibold))
                        .monospaced()
                        .frame(width: 26, height: 20)
                }
                .buttonStyle(.plain)
                .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 8, style: .continuous))
                .hoverEffect(.highlight)
                .accessibilityLabel("Jump to \(entry.display)")
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

private struct LibraryFirstCharacter: Identifiable, Equatable {
    let display: String
    let count: Int
    let offset: Int

    var id: String { display }
}

private struct FirstCharacterResponse: Decodable {
    let mediaContainer: Container
    enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }

    struct Container: Decodable {
        let directory: [Entry]
        enum CodingKeys: String, CodingKey {
            case directory = "Directory"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            directory = try c.decodeIfPresent([Entry].self, forKey: .directory) ?? []
        }
    }

    struct Entry: Decodable {
        let key: String?
        let title: String?
        let count: Int

        enum CodingKeys: String, CodingKey {
            case key
            case title
            case size
            case count
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decodeIfPresent(String.self, forKey: .key)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            count = (try? c.decodeLossyIntIfPresent(forKey: .size))
                ?? (try? c.decodeLossyIntIfPresent(forKey: .count))
                ?? 0
        }
    }

    func libraryEntries(totalSize: Int) -> [LibraryFirstCharacter] {
        var runningOffset = 0
        var result: [LibraryFirstCharacter] = []
        for entry in mediaContainer.directory {
            let display = (entry.title ?? entry.key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !display.isEmpty, entry.count > 0 else { continue }
            result.append(.init(display: display, count: entry.count,
                                offset: min(runningOffset, max(totalSize - 1, 0))))
            runningOffset += entry.count
        }
        return result
    }
}

private extension KeyedDecodingContainer {
    func decodeLossyIntIfPresent(forKey key: Key) throws -> Int? {
        if let int = try decodeIfPresent(Int.self, forKey: key) { return int }
        if let string = try decodeIfPresent(String.self, forKey: key) { return Int(string) }
        return nil
    }
}

struct JellyfinLibraryCard: View {
    let view: JellyfinLibraryLink

    var body: some View {
        HStack(spacing: DS.Space.lg) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(.tint.opacity(0.18))
                Image(systemName: jellyfinLibraryIcon(collectionType: view.collectionType))
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            .frame(width: 76, height: 76)

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(view.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(jellyfinLibrarySubtitle(collectionType: view.collectionType))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(DS.Space.lg)
        .frame(width: 300, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
        .posterHover()
    }
}

func jellyfinLibraryIcon(collectionType: String?) -> String {
    switch collectionType?.lowercased() {
    case "movies": return "film"
    case "tvshows": return "tv"
    case "music": return "music.note"
    case "boxsets": return "square.stack.3d.up"
    case "homevideos", "livetv": return "play.rectangle"
    case "photos": return "photo"
    case "folders": return "folder"
    default: return "rectangle.stack"
    }
}

func jellyfinLibrarySubtitle(collectionType: String?) -> String {
    switch collectionType?.lowercased() {
    case "movies": return "Movies"
    case "tvshows": return "TV shows"
    case "music": return "Music"
    case "boxsets": return "Collections"
    case "homevideos": return "Home videos"
    case "livetv": return "Live TV"
    case "photos": return "Photos"
    case "folders": return "Folder"
    default: return "Library"
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
