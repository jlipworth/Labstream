import SwiftUI
import PMSKit

/// Libraries tab: lists the server's sections (`GET /library/sections`); selecting
/// one pushes a `LibraryGridView` of its items.
struct LibrariesView: View {
    @Environment(AppModel.self) private var appModel

    @State private var sections: [PlexSection] = []
    @State private var jellyfinViews: [JellyfinLibraryLink] = []
    @State private var embyViews: [EmbyLibraryLink] = []
    @State private var loadState: HomeView.LoadState = .idle
    @State private var loadedIdentity: String?

    /// First-run library picker (#104). Holds the candidates + pre-checked hidden ids for the
    /// backend key whose prompt hasn't been shown yet; presented as a sheet from the loaded list.
    @State private var firstRunPrompt: LibraryVisibilityPrompt?

    private let visibilityStore = LibraryVisibilityStore()

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
                } else if appModel.activeBackend == .emby {
                    embyLibrariesList
                } else {
                    plexLibrariesList
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
        .navigationDestination(for: EmbyLibraryLink.self) { view in
            LibraryGridView(emby: view)
        }
        .navigationDestination(for: MediaItem.self) { item in
            // Capture the active backend as the item's origin (#100) so actions resolve
            // against the source backend even after a backend switch.
            DetailView(item: item, originBackend: appModel.activeBackend)
        }
        .task(id: loadIdentity) { await load() }
        .refreshable { await load(force: true) }
        .onReceive(NotificationCenter.default.publisher(for: LibraryVisibilityStore.didChangeNotification)) { notification in
            reloadIfVisibilityChanged(notification)
        }
        .sheet(item: $firstRunPrompt) { prompt in
            LibraryVisibilityPickerSheet(prompt: prompt) { hiddenIDs in
                visibilityStore.setHiddenIDs(hiddenIDs, forBackendKey: prompt.backendKey)
                visibilityStore.markPromptShown(forBackendKey: prompt.backendKey)
                firstRunPrompt = nil
                Task { await load(force: true) }
            } onCancel: {
                // "Show all" / dismissal: record the prompt as shown so it never re-appears,
                // leaving everything visible (empty hidden set).
                visibilityStore.markPromptShown(forBackendKey: prompt.backendKey)
                firstRunPrompt = nil
            }
        }
    }

    private var loadIdentity: String {
        switch appModel.activeBackend {
        case .plex:
            return "plex:\(appModel.selectedServer?.clientIdentifier ?? "nil"):\(appModel.serverBaseURL?.absoluteString ?? "nil")"
        case .jellyfin:
            // Match HomeView's #93 cache-bust: re-auth to the same server changes the
            // token, so the library list must refresh instead of reusing stale/empty state.
            return "jellyfin:\(appModel.jellyfinServerBaseURL?.absoluteString ?? "nil"):\(appModel.jellyfinAccessToken ?? "nil")"
        case .emby:
            return "emby:\(appModel.embyServerBaseURL?.absoluteString ?? "nil"):\(appModel.embyAccessToken ?? "nil")"
        }
    }

    // The Libraries menu is one shared card grid across all three backends (GH #94).
    // Each backend feeds the same `LibrarySectionCard` via a `LibrarySectionKind`;
    // layout (`librarySectionColumns`) and empty-state copy are identical, so the menu
    // reads as the same app regardless of which server is signed in.

    @ViewBuilder
    private var plexLibrariesList: some View {
        if sections.isEmpty {
            librariesEmptyState
        } else {
            ScrollView {
                LazyVGrid(columns: librarySectionColumns, spacing: DS.Space.xl) {
                    ForEach(sections) { section in
                        NavigationLink(value: section) {
                            LibrarySectionCard(title: section.title,
                                               kind: LibrarySectionKind(plexType: section.type))
                        }
                        .cardLink(cornerRadius: DS.Radius.card)
                    }
                }
                .padding(DS.Space.xl)
            }
        }
    }

    @ViewBuilder
    private var jellyfinLibrariesList: some View {
        if jellyfinViews.isEmpty {
            librariesEmptyState
        } else {
            ScrollView {
                LazyVGrid(columns: librarySectionColumns, spacing: DS.Space.xl) {
                    ForEach(jellyfinViews) { view in
                        NavigationLink(value: view) {
                            LibrarySectionCard(title: view.title,
                                               kind: LibrarySectionKind(collectionType: view.collectionType))
                        }
                        .cardLink(cornerRadius: DS.Radius.card)
                    }
                }
                .padding(DS.Space.xl)
            }
        }
    }

    @ViewBuilder
    private var embyLibrariesList: some View {
        if embyViews.isEmpty {
            librariesEmptyState
        } else {
            ScrollView {
                LazyVGrid(columns: librarySectionColumns, spacing: DS.Space.xl) {
                    ForEach(embyViews) { view in
                        NavigationLink(value: view) {
                            LibrarySectionCard(title: view.title,
                                               kind: LibrarySectionKind(collectionType: view.collectionType))
                        }
                        .cardLink(cornerRadius: DS.Radius.card)
                    }
                }
                .padding(DS.Space.xl)
            }
        }
    }

    private var librarySectionColumns: [GridItem] {
        // The cards are a rigid 300pt (`LibrarySectionCard.frame(width: 300)`). With an
        // adaptive minimum below the card width, a transiently-narrow first-pass container
        // could compute a track narrower than the card, laying the 300pt cards edge-to-edge
        // with no gap (#124). Pinning the minimum to the card width guarantees the grid can
        // never compute a sub-card track, so even a degenerate first pass yields one correctly
        // gapped column instead of bunched cards. The spacing-collapse invariant this preserves
        // is asserted by `LibraryGridLayout` / `LibraryGridLayoutTests` in PMSKit.
        [GridItem(.adaptive(minimum: 300, maximum: 340), spacing: DS.Space.xl)]
    }

    private var librariesEmptyState: some View {
        ContentUnavailableView("No libraries",
                               systemImage: "rectangle.stack",
                               description: Text("This server has no libraries."))
    }

    private func load(force: Bool = false) async {
        // `.task` re-fires on pop-back; the section list doesn't change mid-session,
        // so only first load and pull-to-refresh fetch.
        if !force, loadedIdentity == loadIdentity, case .loaded = loadState { return }
        loadState = .loading
        let span = PerformanceInstrumentation.begin(.librariesLoad,
                                                     backend: appModel.activeBackend.performanceLabel,
                                                     fields: ["force": force ? 1 : 0])

        if appModel.activeBackend == .jellyfin {
            do {
                let allViews = try await JellyfinBrowseService(appModel: appModel).userViewLinks()
                let backendKey = appModel.libraryVisibilityBackendKey
                maybePresentFirstRunPrompt(backendKey: backendKey,
                                           candidates: allViews.map { candidate(jellyfin: $0) })
                let hidden = visibilityStore.hiddenIDs(forBackendKey: backendKey)
                jellyfinViews = LibraryVisibility.visible(allViews, hiddenIDs: hidden) { $0.id }
                loadedIdentity = loadIdentity
                loadState = .loaded
                span.end(fields: ["library_count": jellyfinViews.count])
            } catch {
                span.end(result: "failure", fields: ["error": PerformanceInstrumentation.errorLabel(error)])
                loadState = .failed(friendlyMessage(error))
            }
            return
        }

        if appModel.activeBackend == .emby {
            do {
                let allViews = try await EmbyBrowseService(appModel: appModel).userViewLinks()
                let backendKey = appModel.libraryVisibilityBackendKey
                maybePresentFirstRunPrompt(backendKey: backendKey,
                                           candidates: allViews.map { candidate(emby: $0) })
                let hidden = visibilityStore.hiddenIDs(forBackendKey: backendKey)
                embyViews = LibraryVisibility.visible(allViews, hiddenIDs: hidden) { $0.id }
                loadedIdentity = loadIdentity
                loadState = .loaded
                span.end(fields: ["library_count": embyViews.count])
            } catch {
                span.end(result: "failure", fields: ["error": PerformanceInstrumentation.errorLabel(error)])
                loadState = .failed(friendlyMessage(error))
            }
            return
        }

        guard let server = appModel.serverBaseURL, let token = appModel.serverToken else {
            span.end(result: "failure", fields: ["error": "missing_plex_server"])
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
            let nonMusic = resp.mediaContainer.directory.filter { !$0.isMusic }
            let backendKey = appModel.libraryVisibilityBackendKey
            maybePresentFirstRunPrompt(backendKey: backendKey,
                                       candidates: nonMusic.map { candidate(plex: $0) })
            let hidden = visibilityStore.hiddenIDs(forBackendKey: backendKey)
            sections = LibraryVisibility.visible(nonMusic, hiddenIDs: hidden) { $0.key }
            loadedIdentity = loadIdentity
            loadState = .loaded
            span.end(fields: ["library_count": sections.count])
        } catch {
            span.end(result: "failure", fields: ["error": PerformanceInstrumentation.errorLabel(error)])
            loadState = .failed(friendlyMessage(error))
        }
    }

    // MARK: First-run library picker (#104)

    /// On the first successful library load for a backend key whose prompt hasn't been shown,
    /// arm the first-run picker pre-checking known-noise libraries. Tied to the load (not auth
    /// state) so the server/views are known and it works for both fresh login and restored session.
    private func maybePresentFirstRunPrompt(backendKey: String?,
                                            candidates: [LibraryVisibility.Candidate]) {
        guard let backendKey, !candidates.isEmpty else { return }
        guard !visibilityStore.hasShownPrompt(forBackendKey: backendKey) else { return }
        guard firstRunPrompt == nil else { return }
        let preselected = LibraryVisibility.defaultHiddenSelection(from: candidates)
        firstRunPrompt = LibraryVisibilityPrompt(backendKey: backendKey,
                                                 candidates: candidates,
                                                 preselectedHidden: preselected)
    }

    /// Settings edits write through `LibraryVisibilityStore` while this tab can remain mounted
    /// in the background. Reload the visible list for the active backend so returning from
    /// Settings immediately reflects newly hidden/shown libraries (#104).
    private func reloadIfVisibilityChanged(_ notification: Notification) {
        guard let backendKey = notification.userInfo?[LibraryVisibilityStore.didChangeBackendKeyUserInfoKey] as? String,
              backendKey == appModel.libraryVisibilityBackendKey else { return }
        Task { await load(force: true) }
    }

    private func candidate(plex section: PlexSection) -> LibraryVisibility.Candidate {
        LibraryVisibility.Candidate(id: section.key,
                                    title: section.title,
                                    kind: LibrarySectionKind(plexType: section.type).visibilityKindToken)
    }

    private func candidate(jellyfin view: JellyfinLibraryLink) -> LibraryVisibility.Candidate {
        LibraryVisibility.Candidate(id: view.id,
                                    title: view.title,
                                    kind: LibrarySectionKind(collectionType: view.collectionType).visibilityKindToken)
    }

    private func candidate(emby view: EmbyLibraryLink) -> LibraryVisibility.Candidate {
        LibraryVisibility.Candidate(id: view.id,
                                    title: view.title,
                                    kind: LibrarySectionKind(collectionType: view.collectionType).visibilityKindToken)
    }
}

enum LibraryGridSource: Hashable {
    case plex(PlexSection)
    case jellyfin(JellyfinLibraryLink)
    case emby(EmbyLibraryLink)

    var title: String {
        switch self {
        case .plex(let section): return section.title
        case .jellyfin(let view): return view.title
        case .emby(let view): return view.title
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

    @State private var paging = LibraryPagingModel()

    private let columns = [GridItem(.adaptive(minimum: DS.Poster.gridMin, maximum: DS.Poster.gridMax),
                                    spacing: DS.Space.xl)]

    private var pagingSource: LibraryPagingSource {
        LibraryPagingSource(gridSource: source, appModel: appModel)
    }

    private var loadIdentity: String {
        pagingSource.identity
    }

    init(section: PlexSection) {
        self.source = .plex(section)
    }

    init(jellyfin view: JellyfinLibraryLink) {
        self.source = .jellyfin(view)
    }

    init(emby view: EmbyLibraryLink) {
        self.source = .emby(view)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                switch paging.loadState {
                case .idle, .loading:
                    SkeletonGrid()
                case .failed(let message):
                    ContentUnavailableView("Couldn’t load \(source.title)",
                                           systemImage: "exclamationmark.triangle",
                                           description: Text(message))
                        .frame(maxWidth: .infinity, minHeight: 360)
                case .loaded:
                    if paging.slots.isEmpty {
                        ContentUnavailableView("Empty library",
                                               systemImage: "rectangle.stack",
                                               description: Text("No items in \(source.title)."))
                            .frame(maxWidth: .infinity, minHeight: 360)
                    } else {
                        LazyVGrid(columns: columns, spacing: DS.Space.xxl) {
                            ForEach(Array(paging.slots.enumerated()), id: \.offset) { index, slot in
                                if let item = slot {
                                    NavigationLink(value: item) {
                                        PosterCell(item: item, width: DS.Poster.gridMin)
                                    }
                                    .cardLink()
                                    .id(index)
                                } else {
                                    LibraryPlaceholderPoster()
                                        .id(index)
                                        .onAppear {
                                            prefetchPage(containing: index)
                                        }
                                }
                            }
                        }
                        .padding(DS.Space.xl)
                    }
                }
            }
            .overlay(alignment: .trailing) {
                if paging.alphabetBuckets.count > 1, case .loaded = paging.loadState {
                    LibraryAlphabetRail(entries: paging.alphabetBuckets) { entry in
                        jump(to: entry, proxy: proxy)
                    }
                    .padding(.trailing, 10)
                }
            }
        }
        .navigationTitle(source.title)
        .task(id: loadIdentity) { await load() }
        .refreshable { await load(force: true) }
    }

    private func load(force: Bool = false) async {
        // `.task` re-fires on pop-back from an item; reloading the whole grid then
        // would dump the scroll position the user is returning to. Load once per backend
        // session identity; a re-auth to the same server must bust this cache (#93).
        let source = pagingSource
        await paging.load(source: source, force: force) {
            loadIdentity == source.identity
        }
    }

    private func prefetchPage(containing index: Int) {
        let source = pagingSource
        Task {
            await paging.prefetch(containing: index, source: source) {
                loadIdentity == source.identity
            }
        }
    }

    private func jump(to entry: AlphabetBucket, proxy: ScrollViewProxy) {
        let source = pagingSource
        Task {
            await paging.loadPage(containing: entry.offset, source: source) {
                loadIdentity == source.identity
            }
            await MainActor.run {
                withAnimation(.snappy(duration: 0.25)) {
                    proxy.scrollTo(entry.offset, anchor: .top)
                }
            }
        }
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
    let entries: [AlphabetBucket]
    let onPick: (AlphabetBucket) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(entries, id: \.display) { entry in
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
