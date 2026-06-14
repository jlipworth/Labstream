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

extension PlexSection: @retroactive Hashable {
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
    public func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

/// Poster grid for a single library section (`GET /library/sections/<key>/all`).
struct LibraryGridView: View {
    let section: PlexSection

    @Environment(AppModel.self) private var appModel

    @State private var slots: [MediaItem?] = []
    @State private var firstCharacters: [LibraryFirstCharacter] = []
    @State private var loadState: HomeView.LoadState = .idle
    @State private var loadingPages: Set<Int> = []

    private let columns = [GridItem(.adaptive(minimum: DS.Poster.gridMin, maximum: DS.Poster.gridMax),
                                    spacing: DS.Space.xl)]
    private let pageSize = 200

    var body: some View {
        ScrollViewReader { proxy in
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
                    if slots.isEmpty {
                        ContentUnavailableView("Empty library",
                                               systemImage: "rectangle.stack",
                                               description: Text("No items in \(section.title)."))
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
        .navigationTitle(section.title)
        .task { await load() }
        .refreshable { await load(force: true) }
    }

    private func load(force: Bool = false) async {
        // `.task` re-fires on pop-back from an item; reloading the whole grid then
        // would dump the scroll position the user is returning to. Load once.
        if !force, case .loaded = loadState { return }
        guard let server = appModel.serverBaseURL, let token = appModel.serverToken else {
            loadState = .failed("No server selected.")
            return
        }
        loadState = .loading
        loadingPages = []
        let req = BrowseAPI.sectionItems(server: server, token: token,
                                         identity: appModel.identity, sectionKey: section.key,
                                         containerStart: 0, containerSize: pageSize,
                                         sort: "titleSort")
        do {
            async let itemsResponse = appModel.client.send(req, as: MetadataResponse.self)
            async let initialsResponse: FirstCharacterResponse? = loadFirstCharacters(server: server,
                                                                                      token: token)

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

    private func loadFirstCharacters(server: URL, token: String) async -> FirstCharacterResponse? {
        let req = BrowseAPI.firstCharacters(server: server, token: token,
                                            identity: appModel.identity, sectionKey: section.key)
        return try? await appModel.client.send(req, as: FirstCharacterResponse.self)
    }

    private func loadPage(containing index: Int) async {
        guard slots.indices.contains(index),
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
