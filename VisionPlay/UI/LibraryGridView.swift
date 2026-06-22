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
        [GridItem(.adaptive(minimum: 260, maximum: 340), spacing: DS.Space.xl)]
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

    @State private var slots: [MediaItem?] = []
    @State private var firstCharacters: [AlphabetBucket] = []
    @State private var loadState: HomeView.LoadState = .idle
    @State private var loadingPages: Set<Int> = []
    @State private var loadedIdentity: String?

    private let columns = [GridItem(.adaptive(minimum: DS.Poster.gridMin, maximum: DS.Poster.gridMax),
                                    spacing: DS.Space.xl)]
    private let pageSize = 200

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
        .task(id: loadIdentity) { await load() }
        .refreshable { await load(force: true) }
    }

    private var loadIdentity: String {
        switch source {
        case .plex(let section):
            return "plex:\(section.key):\(appModel.selectedServer?.clientIdentifier ?? "nil"):\(appModel.serverBaseURL?.absoluteString ?? "nil")"
        case .jellyfin(let view):
            return "jellyfin:\(view.id):\(appModel.jellyfinServerBaseURL?.absoluteString ?? "nil"):\(appModel.jellyfinAccessToken ?? "nil")"
        case .emby(let view):
            return "emby:\(view.id):\(appModel.embyServerBaseURL?.absoluteString ?? "nil"):\(appModel.embyAccessToken ?? "nil")"
        }
    }

    private func load(force: Bool = false) async {
        // `.task` re-fires on pop-back from an item; reloading the whole grid then
        // would dump the scroll position the user is returning to. Load once per backend
        // session identity; a re-auth to the same server must bust this cache (#93).
        let activeIdentity = loadIdentity
        if !force, loadedIdentity == activeIdentity, case .loaded = loadState { return }
        loadState = .loading
        loadingPages = []
        firstCharacters = []

        switch source {
        case .plex(let section):
            await loadPlex(section: section, loadedIdentity: activeIdentity)
        case .jellyfin(let view):
            await loadJellyfin(view: view, loadedIdentity: activeIdentity)
        case .emby(let view):
            await loadEmby(view: view, loadedIdentity: activeIdentity)
        }
    }

    private func loadPlex(section: PlexSection, loadedIdentity identity: String) async {
        let span = PerformanceInstrumentation.begin(.libraryGridInitialPage,
                                                     backend: "Plex",
                                                     fields: ["page_size": pageSize])
        guard let server = appModel.serverBaseURL, let token = appModel.serverToken else {
            span.end(result: "failure", fields: ["error": "missing_plex_server"])
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
            loadedIdentity = identity
            loadState = .loaded
            span.end(fields: [
                "item_count": page.count,
                "total_count": total,
                "alphabet_count": firstCharacters.count,
            ])
            // Make the browsed page findable in system search (#24).
            SpotlightIndexer.index(page, server: server)
        } catch {
            span.end(result: "failure", fields: ["error": PerformanceInstrumentation.errorLabel(error)])
            loadState = .failed(friendlyMessage(error))
        }
    }

    private func loadJellyfin(view: JellyfinLibraryLink, loadedIdentity identity: String) async {
        let span = PerformanceInstrumentation.begin(.libraryGridInitialPage,
                                                     backend: "Jellyfin",
                                                     fields: ["page_size": pageSize])
        // Run the first page and the alphabet-rail probe CONCURRENTLY (GH #96), mirroring
        // the Plex `async let` path. Previously the rail was kicked off in a deferred
        // `Task` AFTER the page loaded and ran 26 SEQUENTIAL letter probes, so the rail
        // took ~10s to appear. The probe is parallelized internally (see
        // `jellyfinAlphabetCounts`) and starts here, off the first page's critical path.
        let service = JellyfinBrowseService(appModel: appModel)
        async let rawCounts = jellyfinAlphabetCounts(service: service, view: view)
        do {
            let page = try await service
                .itemsPage(parentId: view.id,
                           recursive: jellyfinLibraryRecursive(for: view),
                           startIndex: 0,
                           limit: pageSize,
                           includeItemTypes: jellyfinLibraryItemTypes(for: view),
                           fields: JellyfinLibrary.gridItemFields)
            let total = max(page.total ?? page.items.count, page.items.count)
            var fresh = [MediaItem?](repeating: nil, count: total)
            for (i, item) in page.items.enumerated() where fresh.indices.contains(i) {
                fresh[i] = item
            }
            slots = fresh
            firstCharacters = []
            // A 200/empty first page is indistinguishable from the transient false-empty
            // library state in #93. Show it, but don't pin it so returning to the grid
            // re-fetches automatically rather than sticking until pull-to-refresh.
            loadedIdentity = page.items.isEmpty ? nil : identity
            loadState = .loaded
            span.end(fields: [
                "item_count": page.items.count,
                "total_count": total,
            ])
            // The page is already shown; await the (concurrently-running) probe and apply
            // the rail when it resolves. Uses the SAME offset math as Plex.
            firstCharacters = AlphabetBucket.buckets(from: await rawCounts, total: total)
        } catch {
            span.end(result: "failure", fields: ["error": PerformanceInstrumentation.errorLabel(error)])
            loadState = .failed(friendlyMessage(error))
            // Let the structured `async let` cancel at scope exit. Do not await the
            // alphabet probes after the first-page request has failed; otherwise a
            // network/auth failure can hold the error UI behind all 26 rail probes.
        }
    }

    private func loadEmby(view: EmbyLibraryLink, loadedIdentity identity: String) async {
        let span = PerformanceInstrumentation.begin(.libraryGridInitialPage,
                                                     backend: "Emby",
                                                     fields: ["page_size": pageSize])
        // Concurrent first-page + parallelized alphabet probe — see `loadJellyfin` (GH #96).
        let service = EmbyBrowseService(appModel: appModel)
        async let rawCounts = embyAlphabetCounts(service: service, view: view)
        do {
            let page = try await service
                .itemsPage(parentId: view.id,
                           recursive: embyLibraryRecursive(for: view),
                           startIndex: 0,
                           limit: pageSize,
                           includeItemTypes: embyLibraryItemTypes(for: view),
                           fields: EmbyLibrary.gridItemFields)
            let total = max(page.total ?? page.items.count, page.items.count)
            var fresh = [MediaItem?](repeating: nil, count: total)
            for (i, item) in page.items.enumerated() where fresh.indices.contains(i) {
                fresh[i] = item
            }
            slots = fresh
            firstCharacters = []
            loadedIdentity = page.items.isEmpty ? nil : identity
            loadState = .loaded
            span.end(fields: [
                "item_count": page.items.count,
                "total_count": total,
            ])
            firstCharacters = AlphabetBucket.buckets(from: await rawCounts, total: total)
        } catch {
            span.end(result: "failure", fields: ["error": PerformanceInstrumentation.errorLabel(error)])
            loadState = .failed(friendlyMessage(error))
            // Let the structured `async let` cancel at scope exit. Do not await the
            // alphabet probes after the first-page request has failed; otherwise a
            // network/auth failure can hold the error UI behind all 26 rail probes.
        }
    }

    private func loadFirstCharacters(server: URL, token: String,
                                     section: PlexSection) async -> FirstCharacterResponse? {
        let req = BrowseAPI.firstCharacters(server: server, token: token,
                                            identity: appModel.identity, sectionKey: section.key)
        return try? await appModel.client.send(req, as: FirstCharacterResponse.self)
    }

    private func loadPage(containing index: Int) async {
        guard slots.indices.contains(index) else { return }
        let page = index / pageSize
        guard !loadingPages.contains(page) else { return }
        loadingPages.insert(page)
        let start = page * pageSize

        switch source {
        case .plex(let section):
            let span = PerformanceInstrumentation.begin(.libraryGridPage,
                                                         backend: "Plex",
                                                         fields: ["page": page, "page_size": pageSize])
            guard let server = appModel.serverBaseURL,
                  let token = appModel.serverToken
            else {
                span.end(result: "failure", fields: ["error": "missing_plex_server"])
                loadingPages.remove(page)
                return
            }
            let req = BrowseAPI.sectionItems(server: server, token: token,
                                             identity: appModel.identity, sectionKey: section.key,
                                             containerStart: start, containerSize: pageSize,
                                             sort: "titleSort")
            do {
                let resp = try await appModel.client.send(req, as: MetadataResponse.self)
                let pageItems = resp.mediaContainer.metadata
                for (i, item) in pageItems.enumerated()
                where slots.indices.contains(start + i) {
                    slots[start + i] = item
                }
                span.end(fields: ["item_count": pageItems.count])
                SpotlightIndexer.index(pageItems, server: server)
            } catch {
                span.end(result: "failure", fields: ["error": PerformanceInstrumentation.errorLabel(error)])
                // Non-fatal: remove the in-flight mark so the placeholder retries when it reappears.
            }
        case .jellyfin(let view):
            let span = PerformanceInstrumentation.begin(.libraryGridPage,
                                                         backend: "Jellyfin",
                                                         fields: ["page": page, "page_size": pageSize])
            do {
                let page = try await JellyfinBrowseService(appModel: appModel)
                    .itemsPage(parentId: view.id,
                               recursive: jellyfinLibraryRecursive(for: view),
                               startIndex: start,
                               limit: pageSize,
                               includeItemTypes: jellyfinLibraryItemTypes(for: view),
                               fields: JellyfinLibrary.gridItemFields)
                for (i, item) in page.items.enumerated()
                where slots.indices.contains(start + i) {
                    slots[start + i] = item
                }
                span.end(fields: ["item_count": page.items.count])
            } catch {
                span.end(result: "failure", fields: ["error": PerformanceInstrumentation.errorLabel(error)])
                // Non-fatal: remove the in-flight mark so the placeholder retries when it reappears.
            }
        case .emby(let view):
            let span = PerformanceInstrumentation.begin(.libraryGridPage,
                                                         backend: "Emby",
                                                         fields: ["page": page, "page_size": pageSize])
            do {
                let page = try await EmbyBrowseService(appModel: appModel)
                    .itemsPage(parentId: view.id,
                               recursive: embyLibraryRecursive(for: view),
                               startIndex: start,
                               limit: pageSize,
                               includeItemTypes: embyLibraryItemTypes(for: view),
                               fields: EmbyLibrary.gridItemFields)
                for (i, item) in page.items.enumerated()
                where slots.indices.contains(start + i) {
                    slots[start + i] = item
                }
                span.end(fields: ["item_count": page.items.count])
            } catch {
                span.end(result: "failure", fields: ["error": PerformanceInstrumentation.errorLabel(error)])
                // Non-fatal: remove the in-flight mark so the placeholder retries when it reappears.
            }
        }
        loadingPages.remove(page)
    }
    /// Probe each A–Z letter's item count for the Jellyfin alphabet rail, IN PARALLEL
    /// (GH #96). Returns letters with at least one item, in alphabetical order, as raw
    /// `(display, count)` pairs — the caller turns them into `AlphabetBucket`s with the
    /// shared offset math once `total` is known. Previously these 26 `limit: 1` probes
    /// ran sequentially (~10s); a task group overlaps them so the rail appears in roughly
    /// one round-trip.
    private func jellyfinAlphabetCounts(service: JellyfinBrowseService,
                                        view: JellyfinLibraryLink) async -> [(display: String, count: Int)] {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init)
        let itemTypes = jellyfinLibraryItemTypes(for: view)
        let counts = await withTaskGroup(of: (Int, String, Int).self) { group -> [Int: (String, Int)] in
            for (index, letter) in letters.enumerated() {
                group.addTask {
                    let page = try? await service.itemsPage(parentId: view.id,
                                                            recursive: jellyfinLibraryRecursive(for: view),
                                                            limit: 1,
                                                            nameStartsWith: letter,
                                                            includeItemTypes: itemTypes,
                                                            fields: JellyfinLibrary.gridItemFields)
                    return (index, letter, page?.total ?? 0)
                }
            }
            var byIndex: [Int: (String, Int)] = [:]
            for await (index, letter, count) in group where count > 0 {
                byIndex[index] = (letter, count)
            }
            return byIndex
        }
        // Re-impose alphabetical order — task-group results arrive out of order.
        return counts.keys.sorted().map { (display: counts[$0]!.0, count: counts[$0]!.1) }
    }

    /// Emby twin of `jellyfinAlphabetCounts` (GH #96) — identical parallelized probe.
    private func embyAlphabetCounts(service: EmbyBrowseService,
                                    view: EmbyLibraryLink) async -> [(display: String, count: Int)] {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init)
        let itemTypes = embyLibraryItemTypes(for: view)
        let counts = await withTaskGroup(of: (Int, String, Int).self) { group -> [Int: (String, Int)] in
            for (index, letter) in letters.enumerated() {
                group.addTask {
                    let page = try? await service.itemsPage(parentId: view.id,
                                                            recursive: embyLibraryRecursive(for: view),
                                                            limit: 1,
                                                            nameStartsWith: letter,
                                                            includeItemTypes: itemTypes,
                                                            fields: EmbyLibrary.gridItemFields)
                    return (index, letter, page?.total ?? 0)
                }
            }
            var byIndex: [Int: (String, Int)] = [:]
            for await (index, letter, count) in group where count > 0 {
                byIndex[index] = (letter, count)
            }
            return byIndex
        }
        return counts.keys.sorted().map { (display: counts[$0]!.0, count: counts[$0]!.1) }
    }

}

private func embyLibraryItemTypes(for view: EmbyLibraryLink) -> String {
    MediaBrowserLibraryGridPolicy.itemTypes(collectionType: view.collectionType)
}

private func embyLibraryRecursive(for view: EmbyLibraryLink) -> Bool {
    MediaBrowserLibraryGridPolicy.recursive(collectionType: view.collectionType)
}

private func jellyfinLibraryItemTypes(for view: JellyfinLibraryLink) -> String {
    MediaBrowserLibraryGridPolicy.itemTypes(collectionType: view.collectionType)
}

private func jellyfinLibraryRecursive(for view: JellyfinLibraryLink) -> Bool {
    MediaBrowserLibraryGridPolicy.recursive(collectionType: view.collectionType)
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

    /// Maps the Plex first-character response onto the shared `AlphabetBucket` math so
    /// the rail offsets match the Jellyfin/Emby probe path exactly (GH #96).
    func libraryEntries(totalSize: Int) -> [AlphabetBucket] {
        let counts: [(display: String, count: Int)] = mediaContainer.directory.map {
            (display: ($0.title ?? $0.key ?? ""), count: $0.count)
        }
        return AlphabetBucket.buckets(from: counts, total: totalSize)
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
