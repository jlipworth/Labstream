import SwiftUI
import PMSKit

/// Libraries tab: lists the server's sections (`GET /library/sections`); selecting
/// one pushes a `LibraryGridView` of its items.
struct LibrariesView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.labstreamCompactWidth) private var compactWidth

    @State private var rootItems: [LibraryRootItem] = []
    @State private var loadState: BrowseLoadState = .idle
    @State private var loadedIdentity: String?
    @State private var loadGeneration = 0

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
                librariesList
            }
        }
        .navigationTitle("Libraries")
        .navigationDestination(for: LibraryRootItem.Destination.self) { destination in
            switch destination {
            case .plex(let section):
                LibraryGridView(section: section)
            case .jellyfin(let view):
                LibraryGridView(jellyfin: view)
            case .emby(let view):
                LibraryGridView(emby: view)
            }
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
        appModel.activeBrowseSessionKey
    }

    // The Libraries menu is one shared card grid across all three backends (GH #94/#153).
    // Each backend maps its native section/view type into a `LibraryRootItem` descriptor;
    // layout (`librarySectionColumns`) and empty-state copy are identical, so the menu
    // reads as the same app regardless of which server is signed in.

    @ViewBuilder
    private var librariesList: some View {
        if rootItems.isEmpty {
            librariesEmptyState
        } else {
            ScrollView {
                LazyVGrid(columns: librarySectionColumns, spacing: DS.Space.xl) {
                    ForEach(rootItems) { item in
                        NavigationLink(value: item.destination) {
                            LibrarySectionCard(title: item.title, kind: item.kind)
                        }
                        .cardLink(cornerRadius: DS.Radius.card)
                    }
                }
                .padding(DS.pagePadding(compact: compactWidth))
            }
        }
    }

    private var librarySectionColumns: [GridItem] {
        if compactWidth {
            // Compact phones: one full-width flexible column — the card stretches to
            // the screen (`LibrarySectionCard` drops its rigid width on compact), so
            // the #124 sub-card-track hazard below cannot arise here.
            return [GridItem(.flexible())]
        }
        // The cards are a rigid 300pt (`LibrarySectionCard.frame(width: 300)`). With an
        // adaptive minimum below the card width, a transiently-narrow first-pass container
        // could compute a track narrower than the card, laying the 300pt cards edge-to-edge
        // with no gap (#124). Pinning the minimum to the card width guarantees the grid can
        // never compute a sub-card track, so even a degenerate first pass yields one correctly
        // gapped column instead of bunched cards. The spacing-collapse invariant this preserves
        // is asserted by `LibraryGridLayout` / `LibraryGridLayoutTests` in PMSKit.
        return [GridItem(.adaptive(minimum: 300, maximum: 340), spacing: DS.Space.xl)]
    }

    private var librariesEmptyState: some View {
        ContentUnavailableView("No libraries",
                               systemImage: "rectangle.stack",
                               description: Text("This server has no libraries."))
    }

    private func load(force: Bool = false) async {
        // `.task` re-fires on pop-back; the section list doesn't change mid-session,
        // so only first load and pull-to-refresh fetch.
        let activeIdentity = loadIdentity
        if !force, loadedIdentity == activeIdentity, case .loaded = loadState { return }
        loadGeneration += 1
        let generation = loadGeneration
        loadState = .loading
        let span = PerformanceInstrumentation.begin(.librariesLoad,
                                                     backend: appModel.activeBackend.performanceLabel,
                                                     fields: ["force": force ? 1 : 0])

        if appModel.activeBackend == .jellyfin {
            do {
                let allViews = try await JellyfinBrowseService(appModel: appModel).userViewLinks()
                guard generation == loadGeneration, loadIdentity == activeIdentity, !Task.isCancelled else { return }
                appModel.migrateLibraryVisibilityKeysIfNeeded(store: visibilityStore)
                let backendKey = appModel.libraryVisibilityBackendKey
                maybePresentFirstRunPrompt(backendKey: backendKey,
                                           candidates: allViews.map { candidate(jellyfin: $0) })
                let hidden = visibilityStore.hiddenIDs(forBackendKey: backendKey)
                let visible = LibraryVisibility.visible(allViews, hiddenIDs: hidden) { $0.id }
                rootItems = visible.map(LibraryRootItem.init(jellyfin:))
                loadedIdentity = activeIdentity
                loadState = .loaded
                span.end(fields: ["library_count": rootItems.count])
            } catch {
                guard generation == loadGeneration, loadIdentity == activeIdentity, !Task.isCancelled else { return }
                span.end(result: "failure", fields: ["error": PerformanceInstrumentation.errorLabel(error)])
                loadState = .failed(friendlyMessage(error))
            }
            return
        }

        if appModel.activeBackend == .emby {
            do {
                let allViews = try await EmbyBrowseService(appModel: appModel).userViewLinks()
                guard generation == loadGeneration, loadIdentity == activeIdentity, !Task.isCancelled else { return }
                appModel.migrateLibraryVisibilityKeysIfNeeded(store: visibilityStore)
                let backendKey = appModel.libraryVisibilityBackendKey
                maybePresentFirstRunPrompt(backendKey: backendKey,
                                           candidates: allViews.map { candidate(emby: $0) })
                let hidden = visibilityStore.hiddenIDs(forBackendKey: backendKey)
                let visible = LibraryVisibility.visible(allViews, hiddenIDs: hidden) { $0.id }
                rootItems = visible.map(LibraryRootItem.init(emby:))
                loadedIdentity = activeIdentity
                loadState = .loaded
                span.end(fields: ["library_count": rootItems.count])
            } catch {
                guard generation == loadGeneration, loadIdentity == activeIdentity, !Task.isCancelled else { return }
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
            guard generation == loadGeneration, loadIdentity == activeIdentity, !Task.isCancelled else { return }
            // Music sections deliberately stay out of this tab even after the #17
            // un-hide: the Music tab is their dedicated entry point and listing the
            // section twice is noise (MUSIC-DESIGN §2 — a considered exception to
            // #17's original "remove the !isMusic filter" checklist item).
            let nonMusic = resp.mediaContainer.directory.filter { !$0.isMusic }
            appModel.migrateLibraryVisibilityKeysIfNeeded(store: visibilityStore)
            let backendKey = appModel.libraryVisibilityBackendKey
            maybePresentFirstRunPrompt(backendKey: backendKey,
                                       candidates: nonMusic.map { candidate(plex: $0) })
            let hidden = visibilityStore.hiddenIDs(forBackendKey: backendKey)
            let visible = LibraryVisibility.visible(nonMusic, hiddenIDs: hidden) { $0.key }
            rootItems = visible.map(LibraryRootItem.init(plex:))
            loadedIdentity = activeIdentity
            loadState = .loaded
            span.end(fields: ["library_count": rootItems.count])
        } catch {
            guard generation == loadGeneration, loadIdentity == activeIdentity, !Task.isCancelled else { return }
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

struct LibraryRootItem: Identifiable, Hashable {
    enum Destination: Hashable {
        case plex(PlexSection)
        case jellyfin(JellyfinLibraryLink)
        case emby(EmbyLibraryLink)
    }

    let id: String
    let backend: MediaBackendChoice
    let title: String
    let kind: LibrarySectionKind
    let destination: Destination

    init(plex section: PlexSection) {
        self.id = "plex:\(section.key)"
        self.backend = .plex
        self.title = section.title
        self.kind = LibrarySectionKind(plexType: section.type)
        self.destination = .plex(section)
    }

    init(jellyfin view: JellyfinLibraryLink) {
        self.id = "jellyfin:\(view.id)"
        self.backend = .jellyfin
        self.title = view.title
        self.kind = LibrarySectionKind(collectionType: view.collectionType)
        self.destination = .jellyfin(view)
    }

    init(emby view: EmbyLibraryLink) {
        self.id = "emby:\(view.id)"
        self.backend = .emby
        self.title = view.title
        self.kind = LibrarySectionKind(collectionType: view.collectionType)
        self.destination = .emby(view)
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
    @Environment(\.labstreamCompactWidth) private var compactWidth

    @State private var paging = LibraryPagingModel()

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: DS.Poster.gridMin(compact: compactWidth),
                            maximum: DS.Poster.gridMax(compact: compactWidth)),
                  spacing: DS.gridGutter(compact: compactWidth))]
    }

    private var pagingSource: LibraryPagingSource {
        LibraryPagingSource(gridSource: source, appModel: appModel)
    }

    /// Mirrors the trailing A–Z rail's own visibility condition below so the grid can
    /// reserve room for it. On compact width the 16 pt page padding leaves the last
    /// poster column under the section-index strip, which then intercepts scrubs/taps (#209).
    private var alphabetRailVisible: Bool {
        guard case .loaded = paging.loadState else { return false }
        return paging.alphabetBuckets.count > 1
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
                        LazyVGrid(columns: columns,
                                  spacing: compactWidth ? DS.Space.lg : DS.Space.xxl) {
                            ForEach(Array(paging.slots.enumerated()), id: \.offset) { index, slot in
                                if let item = slot {
                                    NavigationLink(value: item) {
                                        PosterCell(item: item,
                                                   width: DS.Poster.gridMin(compact: compactWidth))
                                    }
                                    .cardLink()
                                    .id(index)
                                    .videoCardContextMenu(for: item)
                                } else {
                                    LibraryPlaceholderPoster()
                                        .id(index)
                                        .onAppear {
                                            prefetchPage(containing: index)
                                        }
                                }
                            }
                        }
                        .padding(DS.pagePadding(compact: compactWidth))
                        // Reserve the rail's own narrow strip past the base padding so the last
                        // poster column clears the trailing A–Z index on compact (#209);
                        // regular width has ample gutter and needs no reservation.
                        .padding(.trailing, alphabetRailVisible && compactWidth ? LibraryAlphabetRail.compactGridTrailingReservation : 0)
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
        // The sparse grid already has a placeholder at every server offset, so move
        // immediately and let the page fill in as soon as it arrives. Waiting for the
        // network page first made rail scrubbing feel delayed.
        withAnimation(.snappy(duration: 0.16)) {
            proxy.scrollTo(entry.offset, anchor: .top)
        }
        Task {
            await paging.loadPage(containing: entry.offset, source: source) {
                loadIdentity == source.identity
            }
            await MainActor.run {
                withAnimation(.snappy(duration: 0.16)) {
                    proxy.scrollTo(entry.offset, anchor: .top)
                }
            }
        }
    }
}

private struct LibraryPlaceholderPoster: View {
    @Environment(\.labstreamCompactWidth) private var compactWidth

    var body: some View {
        let side = DS.Poster.gridMin(compact: compactWidth)
        RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous)
            .fill(.regularMaterial)
            .frame(width: side, height: DS.Poster.height(for: side))
            .overlay { ShimmerView() }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous))
    }
}

/// Shimmering poster grid shown while a library section loads, so the screen keeps
/// its layout (and the same gutters as the real grid) rather than flashing a spinner.
private struct SkeletonGrid: View {
    @Environment(\.labstreamCompactWidth) private var compactWidth

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: DS.Poster.gridMin(compact: compactWidth),
                            maximum: DS.Poster.gridMax(compact: compactWidth)),
                  spacing: DS.gridGutter(compact: compactWidth))]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: compactWidth ? DS.Space.lg : DS.Space.xxl) {
            ForEach(0..<12, id: \.self) { _ in
                LibraryPlaceholderPoster()
            }
        }
        .padding(DS.pagePadding(compact: compactWidth))
    }
}
