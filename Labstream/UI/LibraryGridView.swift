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
        .labstreamTopLevelNavigationTitle("Libraries")
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
        // Pushed from a Plex section grid's Collections toolbar entry (#199).
        .navigationDestination(for: LibraryGridSource.self) { source in
            LibraryGridView(source: source)
        }
        .task(id: loadIdentity) { await load() }
        .refreshable { await load(force: true) }
        .onReceive(NotificationCenter.default.publisher(for: LibraryVisibilityStore.didChangeNotification)) { notification in
            reloadIfVisibilityChanged(notification)
        }
        #if os(tvOS)
        .fullScreenCover(item: $firstRunPrompt) { prompt in
            libraryVisibilityPicker(for: prompt)
        }
        #else
        .sheet(item: $firstRunPrompt) { prompt in
            libraryVisibilityPicker(for: prompt)
        }
        #endif
    }

    private func libraryVisibilityPicker(for prompt: LibraryVisibilityPrompt) -> some View {
        LibraryVisibilityPickerSheet(prompt: prompt) { hiddenIDs in
            visibilityStore.setHiddenIDs(hiddenIDs, forBackendKey: prompt.backendKey)
            visibilityStore.markPromptShown(forBackendKey: prompt.backendKey)
            firstRunPrompt = nil
            Task { await load(force: true) }
        } onCancel: {
            // Cancellation preserves the existing show-all behavior and records the prompt so it
            // does not interrupt the next launch. Settings remains the persistent editor.
            visibilityStore.markPromptShown(forBackendKey: prompt.backendKey)
            firstRunPrompt = nil
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
                LazyVGrid(columns: librarySectionColumns, spacing: DS.gridGutter(compact: compactWidth)) {
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
        #if os(tvOS)
        return [GridItem(.adaptive(minimum: 400, maximum: 400), spacing: DS.gridGutter(compact: false))]
        #else
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
        #endif
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

        #if os(tvOS) && DEBUG
        if let fixtureItems = TVUIFixtureCatalog.libraryRootItems(for: appModel.activeBackend) {
            rootItems = fixtureItems
            loadedIdentity = activeIdentity
            loadState = .loaded
            return
        }
        #endif

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

        guard let service = try? PlexBrowseService(appModel: appModel) else {
            span.end(result: "failure", fields: ["error": "missing_plex_server"])
            loadState = .failed("No server selected.")
            return
        }
        do {
            let libraries = try await service.libraries()
            guard generation == loadGeneration, loadIdentity == activeIdentity, !Task.isCancelled else { return }
            // Music sections deliberately stay out of this tab even after the #17
            // un-hide: the Music tab is their dedicated entry point and listing the
            // section twice is noise (MUSIC-DESIGN §2 — a considered exception to
            // #17's original "remove the !isMusic filter" checklist item).
            let nonMusic = libraries.filter { !$0.isMusic }
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
    /// Backend-defined collections of one Plex section (#199). Plex exposes collections
    /// per section, so this grid is pushed from that section's toolbar.
    case plexCollections(PlexSection)
    case jellyfin(JellyfinLibraryLink)
    case emby(EmbyLibraryLink)

    var title: String {
        switch self {
        case .plex(let section): return section.title
        case .plexCollections: return "Collections"
        case .jellyfin(let view): return view.title
        case .emby(let view): return view.title
        }
    }

    var capabilityIdentity: String {
        switch self {
        case .plex(let section): return "plex:\(section.key)"
        case .plexCollections(let section): return "plex:\(section.key):collections"
        case .jellyfin(let view): return "jellyfin:\(view.id)"
        case .emby(let view): return "emby:\(view.id)"
        }
    }

    var backend: MediaBackendKind {
        switch self {
        case .plex, .plexCollections: return .plex
        case .jellyfin: return .jellyfin
        case .emby: return .emby
        }
    }
}

extension PlexSection: @retroactive Hashable {
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
    public func hash(into hasher: inout Hasher) { hasher.combine(key) }
}


private enum LibraryBrowseCapabilityLoadState: Equatable {
    case loading
    case loaded(LibraryBrowseCapabilities)
    case unavailable(String)

    var capabilities: LibraryBrowseCapabilities {
        switch self {
        case .loading, .unavailable:
            return .defaultOnly
        case .loaded(let capabilities):
            return capabilities
        }
    }
}

private struct LibraryBrowsePreferenceStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func query(for identity: String) -> LibraryBrowseQuery {
        let prefix = "libraryBrowse.\(identity)"
        let sort = defaults.string(forKey: "\(prefix).sort")
            .flatMap(LibraryBrowseSort.init(rawValue:)) ?? .titleAscending
        let filter = defaults.string(forKey: "\(prefix).filter")
            .flatMap(LibraryBrowseFilter.init(rawValue:)) ?? .all
        return LibraryBrowseQuery(sort: sort, filter: filter)
    }

    func save(_ query: LibraryBrowseQuery, for identity: String) {
        let prefix = "libraryBrowse.\(identity)"
        defaults.set(query.sort.rawValue, forKey: "\(prefix).sort")
        defaults.set(query.filter.rawValue, forKey: "\(prefix).filter")
    }
}

/// Poster grid for a single library section (`GET /library/sections/<key>/all`).
struct LibraryGridView: View {
    let source: LibraryGridSource

    @Environment(AppModel.self) private var appModel
    @Environment(\.labstreamCompactWidth) private var compactWidth

    @State private var paging = LibraryPagingModel()
    @State private var sort: LibraryBrowseSort = .titleAscending
    @State private var filter: LibraryBrowseFilter = .all
    @State private var capabilityState: LibraryBrowseCapabilityLoadState = .loading
    @State private var loadedCapabilityIdentity: String?
    @State private var loadedPreferenceIdentity: String?
    @State private var jumpTask: Task<Void, Never>?

    private var regularColumns: [GridItem] {
        #if os(tvOS)
        [GridItem(.adaptive(minimum: tvPosterWidth, maximum: tvPosterWidth),
                  spacing: tvGridSpacing)]
        #else
        [GridItem(.adaptive(minimum: DS.Poster.gridMin(compact: compactWidth),
                            maximum: DS.Poster.gridMax(compact: compactWidth)),
                  spacing: DS.gridGutter(compact: compactWidth))]
        #endif
    }

    #if os(tvOS)
    private let tvPosterWidth: CGFloat = 248
    private let tvGridSpacing: CGFloat = 24
    private let tvPageInset: CGFloat = 56
    #endif

    private var browseQuery: LibraryBrowseQuery {
        LibraryBrowseQuery(sort: sort, filter: filter)
    }

    private var availableCapabilities: LibraryBrowseCapabilities {
        switch source {
        case .plex:
            return capabilityState.capabilities
        case .plexCollections:
            return .defaultOnly
        case .jellyfin(let view):
            return MediaBrowserLibraryGridPolicy.browseCapabilities(collectionType: view.collectionType)
        case .emby(let view):
            return MediaBrowserLibraryGridPolicy.browseCapabilities(collectionType: view.collectionType)
        }
    }

    private var availableSorts: [LibraryBrowseSort] {
        availableCapabilities.sorts
    }

    private var availableFilters: [LibraryBrowseFilter] {
        availableCapabilities.filters
    }

    private var pagingSource: LibraryPagingSource {
        LibraryPagingSource(gridSource: source, query: browseQuery, appModel: appModel)
    }

    private var pagingIdentity: String {
        pagingSource.identity
    }

    private var loadIdentity: String {
        "\(loadedPreferenceIdentity ?? "pending"):\(pagingIdentity)"
    }

    private var capabilityIdentity: String {
        "\(appModel.browseSessionKey(for: source.backend)):capabilities:\(source.capabilityIdentity)"
    }

    private var preferenceIdentity: String {
        let serverUser = appModel.stableServerUserKey(for: source.backend)
            ?? appModel.browseSessionKey(for: source.backend)
        return "\(serverUser):\(source.capabilityIdentity)"
    }

    private var alphabetRailVisible: Bool {
        guard case .loaded = paging.loadState else { return false }
        return paging.alphabetBuckets.count > 1
    }

    init(source: LibraryGridSource) {
        self.source = source
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
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 0) {
                    #if os(tvOS)
                    tvLibraryHeader(proxy: proxy)
                    #else
                    if showsBrowseControls {
                        browseControls(proxy: proxy)
                            .padding(.horizontal, DS.pagePadding(compact: compactWidth))
                            .padding(.vertical, DS.Space.lg)
                    }
                    #endif

                    ScrollView {
                        VStack(alignment: .leading, spacing: DS.Space.lg) {
                            switch paging.loadState {
                            case .idle, .loading:
                                SkeletonGrid(availableWidth: geometry.size.width)
                            case .failed(let message):
                                ContentUnavailableView("Couldn’t load \(source.title)",
                                                       systemImage: "exclamationmark.triangle",
                                                       description: Text(message))
                                    .frame(maxWidth: .infinity, minHeight: 360)
                            case .loaded:
                                if paging.slots.isEmpty {
                                    emptyState
                                } else {
                                    let metrics = compactGridMetrics(availableWidth: geometry.size.width)
                                    LazyVGrid(columns: gridColumns(metrics: metrics),
                                              spacing: metrics?.rowSpacing ?? regularGridRowSpacing) {
                                        ForEach(Array(paging.slots.enumerated()), id: \.offset) { index, slot in
                                            LibraryGridSlot(index: index,
                                                            item: slot,
                                                            width: metrics?.posterWidth ?? regularPosterWidth,
                                                            usesDenseLabels: metrics != nil || usesTelevisionGrid) {
                                                prefetchPage(containing: index)
                                            }
                                            // Keep the stable sparse-grid offset as the scroll target for
                                            // the A–Z rail while giving the loaded/placeholder subtrees
                                            // different identities below. Without the inner identity split,
                                            // SwiftUI can recycle a placeholder view after a fast alphabet
                                            // jump and leave the slot blank/missing metadata once the page
                                            // arrives.
                                            .id(index)
                                        }
                                    }
                                    .padding(.horizontal, metrics?.horizontalPadding ?? regularGridHorizontalPadding)
                                    .padding(.vertical, metrics?.horizontalPadding ?? regularGridVerticalPadding)
                                    .padding(.trailing, metrics?.trailingReservation ?? 0)
                                }
                            }
                        }
                    }
                }
                .overlay(alignment: .trailing) {
                    #if !os(visionOS) && !os(tvOS)
                    if alphabetRailVisible {
                        LibraryAlphabetRail(entries: paging.alphabetBuckets) { entry in
                            jump(to: entry, proxy: proxy)
                        }
                        .padding(.trailing, 10)
                    }
                    #endif
                }
            }
        }
        #if os(tvOS)
        // The selected library is already named by the compact in-content header. Native tvOS
        // navigation chrome otherwise consumes the first half-screen and detaches Collections
        // into a separate trailing toolbar rail.
        .toolbar(.hidden, for: .navigationBar)
        #else
        .navigationTitle(navigationTitle)
        .toolbar {
            // Plex collections belong to movie/show sections rather than a standalone
            // library, so the regular section grid carries the entry point.
            if case .plex(let section) = source, section.type == "movie" || section.type == "show" {
                #if os(macOS)
                ToolbarItem {
                    collectionsToolbarLink(section)
                }
                #else
                ToolbarItem(placement: .topBarTrailing) {
                    collectionsToolbarLink(section)
                }
                #endif
            }
        }
        #endif
        .task(id: preferenceIdentity) { loadPreferences() }
        .task(id: capabilityIdentity) { await loadBrowseCapabilities() }
        .task(id: loadIdentity) { await load() }
        .onChange(of: browseQuery) { _, query in savePreferences(query) }
        .onDisappear {
            jumpTask?.cancel()
            jumpTask = nil
        }
        .refreshable {
            // Capability discovery can fail independently of the library request. Retry it
            // on an explicit refresh instead of leaving a transient outage sticky for the
            // lifetime of this navigation destination.
            await loadBrowseCapabilities(force: true)
            await load(force: true)
        }
    }

    private func compactGridMetrics(availableWidth: CGFloat) -> MobileLibraryGridLayout.Metrics? {
        guard compactWidth else { return nil }
        let reservation = nonVisionAlphabetRailVisible ? LibraryAlphabetRail.compactGridTrailingReservation : 0
        return MobileLibraryGridLayout.metrics(availableWidth: Double(availableWidth),
                                               trailingReservation: Double(reservation))
    }

    private func gridColumns(metrics: MobileLibraryGridLayout.Metrics?) -> [GridItem] {
        guard let metrics else { return regularColumns }
        return Array(repeating: GridItem(.fixed(CGFloat(metrics.posterWidth)), spacing: CGFloat(metrics.gutter)),
                     count: metrics.columnCount)
    }

    private var regularPosterWidth: CGFloat {
        #if os(tvOS)
        tvPosterWidth
        #else
        DS.Poster.gridMin(compact: compactWidth)
        #endif
    }

    private var regularGridHorizontalPadding: CGFloat {
        #if os(tvOS)
        tvPageInset
        #else
        DS.pagePadding(compact: compactWidth)
        #endif
    }

    private var regularGridVerticalPadding: CGFloat {
        #if os(tvOS)
        DS.Space.lg
        #else
        DS.pagePadding(compact: compactWidth)
        #endif
    }

    private var regularGridRowSpacing: CGFloat {
        #if os(tvOS)
        DS.Space.xl
        #else
        DS.Space.xxl
        #endif
    }

    private var usesTelevisionGrid: Bool {
        #if os(tvOS)
        true
        #else
        false
        #endif
    }

    #if os(tvOS)
    private func tvLibraryHeader(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.lg) {
                Text(navigationTitle)
                    .font(.headline)
                    .lineLimit(1)

                Spacer(minLength: DS.Space.xl)
            }

            if showsBrowseControls {
                HStack(spacing: DS.Space.md) {
                    browseControlItems(proxy: proxy)
                    Spacer(minLength: DS.Space.md)

                    if let capabilityNotice {
                        capabilityNoticeView(capabilityNotice)
                            .lineLimit(1)
                    }

                    if case .plex(let section) = source,
                       section.type == "movie" || section.type == "show" {
                        collectionsToolbarLink(section)
                    }
                }
            }
        }
        .padding(.horizontal, tvPageInset)
        .padding(.top, DS.Space.md)
        .padding(.bottom, DS.Space.sm)
    }
    #endif

    private func browseControls(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: DS.Space.md) {
            browseControlItems(proxy: proxy)
            if let capabilityNotice {
                capabilityNoticeView(capabilityNotice)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func browseControlItems(proxy: ScrollViewProxy) -> some View {
            if availableSorts.count > 1 {
                sortMenu
            } else if sort != .titleAscending {
                // The sort menu is hidden (e.g. capability discovery failed/was unavailable),
                // but a restored non-default sort still drives the query. Without this chip the
                // user would have no visible way to clear it — the symmetric escape hatch to
                // `activeFilterChip` below.
                activeSortChip
            }
            if availableFilters.count > 1 {
                filterMenu
            }
            if filter != .all {
                activeFilterChip
            }
            #if os(visionOS) || os(tvOS)
            if alphabetRailVisible {
                LibraryAlphabetJumpButton(entries: paging.alphabetBuckets) { entry in
                    jump(to: entry, proxy: proxy)
                }
            }
            #endif
    }

    /// Collection order is backend-curated and Plex does not expose the regular section
    /// sort/filter/alphabet capabilities on the collections endpoint. Avoid reserving an
    /// empty controls row above this specialized grid while preserving the full browse
    /// architecture for normal libraries.
    private var showsBrowseControls: Bool {
        if case .plexCollections = source { return false }
        return true
    }

    private var capabilityNotice: String? {
        guard case .plex = source else { return nil }
        switch capabilityState {
        case .loading:
            return "Checking server filters…"
        case .unavailable(let message):
            return message
        case .loaded(let capabilities):
            if capabilities.sorts.count <= 1, capabilities.filters.count <= 1 {
                return "No server-advertised filters for this section."
            }
            return nil
        }
    }

    private func capabilityNoticeView(_ message: String) -> some View {
        Label(message, systemImage: "line.3.horizontal.decrease.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(availableSorts) { option in
                    Text(option.label).tag(option)
                }
            }
        } label: {
            Label(sort.label, systemImage: "arrow.up.arrow.down")
                .font(.callout)
        }
        .buttonStyle(.bordered)
        #if os(tvOS)
        .controlSize(.small)
        .fixedSize()
        #endif
    }

    private var filterMenu: some View {
        Menu {
            Picker("Filter", selection: $filter) {
                ForEach(availableFilters) { option in
                    Text(option.label).tag(option)
                }
            }
        } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                .font(.callout)
        }
        .buttonStyle(.bordered)
        #if os(tvOS)
        .controlSize(.small)
        .fixedSize()
        #endif
    }

    private var activeSortChip: some View {
        Button {
            sort = .titleAscending
        } label: {
            HStack(spacing: DS.Space.xs) {
                Text(sort.label)
                Image(systemName: "xmark.circle.fill")
                    .imageScale(.small)
            }
            .font(.callout)
        }
        .buttonStyle(.bordered)
        #if os(tvOS)
        .controlSize(.small)
        .fixedSize()
        #endif
        .accessibilityLabel("Clear \(sort.label) sort")
    }

    private var activeFilterChip: some View {
        Button {
            filter = .all
        } label: {
            HStack(spacing: DS.Space.xs) {
                Text(filter.label)
                Image(systemName: "xmark.circle.fill")
                    .imageScale(.small)
            }
            .font(.callout)
        }
        .buttonStyle(.bordered)
        #if os(tvOS)
        .controlSize(.small)
        .fixedSize()
        #endif
        .accessibilityLabel("Clear \(filter.label) filter")
    }

    private var emptyState: some View {
        if case .plexCollections(let section) = source {
            return ContentUnavailableView("No collections",
                                          systemImage: "rectangle.stack",
                                          description: Text("\(section.title) has no collections on this server."))
                .frame(maxWidth: .infinity, minHeight: 360)
        }
        let title = filter == .all ? "Empty library" : "No matching items"
        let description = filter == .all
            ? "No items in \(source.title)."
            : "No \(filter.label.lowercased()) items matched \(source.title)."
        return ContentUnavailableView(title,
                                      systemImage: filter == .all ? "rectangle.stack" : "line.3.horizontal.decrease.circle",
                                      description: Text(description))
            .frame(maxWidth: .infinity, minHeight: 360)
    }

    private func collectionsToolbarLink(_ section: PlexSection) -> some View {
        NavigationLink(value: LibraryGridSource.plexCollections(section)) {
            Label("Collections", systemImage: "square.stack.3d.up")
                #if os(tvOS)
                .font(.callout)
                #endif
        }
        #if os(tvOS)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        #endif
    }

    private var navigationTitle: String {
        if case .plexCollections(let section) = source {
            return "\(section.title) · Collections"
        }
        return source.title
    }

    private var nonVisionAlphabetRailVisible: Bool {
        #if os(visionOS) || os(tvOS)
        false
        #else
        alphabetRailVisible
        #endif
    }

    private func loadPreferences() {
        let identity = preferenceIdentity
        let query = LibraryBrowsePreferenceStore().query(for: identity)
        sort = query.sort
        filter = query.filter
        // Capability discovery and preference restoration are independent tasks. If the
        // server answered first, validate the restored selection now; if preferences won
        // the race, `loadBrowseCapabilities()` validates them when discovery completes.
        switch source {
        case .plex:
            switch capabilityState {
            case .loaded(let capabilities):
                enforceCapabilities(capabilities)
            case .unavailable:
                // A discovery failure does not prove that a previously saved query is no
                // longer supported. Preserve it rather than destructively overwriting the
                // per-library preference because of a transient network/server error.
                break
            case .loading:
                break
            }
        case .plexCollections:
            sort = .titleAscending
            filter = .all
        case .jellyfin, .emby:
            enforceCapabilities(availableCapabilities)
        }
        loadedPreferenceIdentity = identity
    }

    private func savePreferences(_ query: LibraryBrowseQuery) {
        guard loadedPreferenceIdentity == preferenceIdentity else { return }
        LibraryBrowsePreferenceStore().save(query, for: preferenceIdentity)
    }

    private func loadBrowseCapabilities(force: Bool = false) async {
        // Non-Plex capabilities are static (`availableCapabilities` is the source of truth);
        // only Plex discovers them from the server.
        guard case .plex(let section) = source else { return }
        // `.task` re-fires on pop-back from an item (see load()); refetching then would
        // flash the menus and — worse — enforcing defaults below would reset the user's
        // chosen sort/filter and force a full grid reload. Load once per identity.
        guard force || loadedCapabilityIdentity != capabilityIdentity else { return }
        let activeIdentity = capabilityIdentity
        capabilityState = .loading
        guard let server = appModel.serverBaseURL, let token = appModel.serverToken else {
            guard capabilityIdentity == activeIdentity, !Task.isCancelled else { return }
            loadedCapabilityIdentity = activeIdentity
            capabilityState = .unavailable("Server filters unavailable.")
            return
        }
        do {
            async let filterResponse = appModel.client.send(
                BrowseAPI.sectionFilters(server: server,
                                         token: token,
                                         identity: appModel.identity,
                                         sectionKey: section.key),
                as: PlexLibrarySectionFiltersResponse.self)
            async let sortResponse = appModel.client.send(
                BrowseAPI.sectionSorts(server: server,
                                       token: token,
                                       identity: appModel.identity,
                                       sectionKey: section.key),
                as: PlexLibrarySectionSortsResponse.self)
            let filters = try await filterResponse
            let sorts = try await sortResponse
            guard capabilityIdentity == activeIdentity, !Task.isCancelled else { return }
            loadedCapabilityIdentity = activeIdentity
            // A parseable-but-empty discovery payload (HTTP 200 whose `Directory` is missing
            // or empty) is indistinguishable from a defaults-only capability set. Trusting it
            // would let enforceCapabilities() destructively reset — and, via onChange →
            // savePreferences, PERSIST the reset of — the user's saved sort/filter. Treat an
            // empty advertisement like the thrown-error path below (.unavailable), which
            // preserves saved prefs. A genuinely non-empty (even partial) set still enforces.
            guard !sorts.mediaContainer.directory.isEmpty,
                  !filters.mediaContainer.directory.isEmpty else {
                capabilityState = .unavailable("Server filters unavailable.")
                return
            }
            let capabilities = LibraryBrowseCapabilities.plex(filters: filters, sorts: sorts)
            capabilityState = .loaded(capabilities)
            enforceCapabilities(capabilities)
        } catch {
            guard capabilityIdentity == activeIdentity, !Task.isCancelled else { return }
            loadedCapabilityIdentity = activeIdentity
            capabilityState = .unavailable("Server filters unavailable.")
        }
    }

    private func enforceCapabilities(_ capabilities: LibraryBrowseCapabilities) {
        if !capabilities.sorts.contains(sort) {
            sort = capabilities.sorts.first ?? .titleAscending
        }
        if !capabilities.filters.contains(filter) {
            filter = .all
        }
    }

    private func load(force: Bool = false) async {
        // `.task` re-fires on pop-back from an item; reloading the whole grid then
        // would dump the scroll position the user is returning to. Load once per backend
        // session/query identity; a re-auth to the same server must bust this cache (#93).
        guard loadedPreferenceIdentity == preferenceIdentity else { return }
        let source = pagingSource
        await paging.load(source: source, force: force) {
            pagingIdentity == source.identity
        }
    }

    private func prefetchPage(containing index: Int) {
        let source = pagingSource
        Task {
            await paging.prefetch(containing: index, source: source) {
                pagingIdentity == source.identity
            }
        }
    }

    private func jump(to entry: AlphabetBucket, proxy: ScrollViewProxy) {
        jumpTask?.cancel()
        let source = pagingSource
        let needsPageLoad = !paging.isLoaded(at: entry.offset)
        withAnimation(.snappy(duration: 0.16)) {
            proxy.scrollTo(entry.offset, anchor: .top)
        }

        // Loaded targets are a local scroll only. For a sparse target, keep the immediate
        // placeholder jump, but allow only the latest selection to re-anchor after its page
        // arrives; older A-Z tasks must never pull the user back to a superseded letter.
        guard needsPageLoad else { return }
        jumpTask = Task {
            await paging.loadPage(containing: entry.offset, source: source) {
                pagingIdentity == source.identity
            }
            guard !Task.isCancelled,
                  pagingIdentity == source.identity,
                  paging.isLoaded(at: entry.offset) else { return }
            withAnimation(.snappy(duration: 0.16)) {
                proxy.scrollTo(entry.offset, anchor: .top)
            }
        }
    }
}

private struct LibraryGridSlot: View {
    let index: Int
    let item: MediaItem?
    let width: CGFloat
    let usesDenseLabels: Bool
    let onPlaceholderAppear: () -> Void

    var body: some View {
        Group {
            if let item {
                NavigationLink(value: item) {
                    PosterCell(item: item,
                               width: width,
                               labelStyle: usesDenseLabels ? .denseLibrary : .standard)
                }
                .cardLink()
                .videoCardContextMenu(for: item)
                .id("loaded-\(item.ratingKey)")
            } else {
                LibraryPlaceholderPoster(width: width)
                    .id("placeholder-\(index)")
                    .onAppear(perform: onPlaceholderAppear)
            }
        }
    }
}

/// Shared shimmer placeholder for a paged poster slot (library grid + collection detail).
struct LibraryPlaceholderPoster: View {
    let width: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous)
            .fill(.regularMaterial)
            .frame(width: width, height: DS.Poster.height(for: width))
            .overlay { ShimmerView() }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous))
    }
}

/// Shimmering poster grid shown while a library section loads, so the screen keeps
/// its layout (and the same gutters as the real grid) rather than flashing a spinner.
private struct SkeletonGrid: View {
    @Environment(\.labstreamCompactWidth) private var compactWidth
    let availableWidth: CGFloat

    var body: some View {
        #if os(tvOS)
        let columns = [GridItem(.adaptive(minimum: 248, maximum: 248), spacing: 24)]
        let width: CGFloat = 248
        let horizontalPadding: CGFloat = 56
        let verticalPadding: CGFloat = DS.Space.lg
        let rowSpacing: CGFloat = DS.Space.xl
        #else
        let metrics = compactWidth
            ? MobileLibraryGridLayout.metrics(availableWidth: Double(availableWidth))
            : nil
        let columns = metrics.map {
            Array(repeating: GridItem(.fixed($0.posterWidth), spacing: $0.gutter), count: $0.columnCount)
        } ?? [GridItem(.adaptive(minimum: DS.Poster.gridMin(compact: false),
                                maximum: DS.Poster.gridMax(compact: false)),
                       spacing: DS.gridGutter(compact: false))]
        let width = metrics?.posterWidth ?? DS.Poster.gridMin(compact: false)
        let horizontalPadding = metrics?.horizontalPadding ?? DS.pagePadding(compact: compactWidth)
        let verticalPadding = horizontalPadding
        let rowSpacing = metrics?.rowSpacing ?? DS.Space.xxl
        #endif
        LazyVGrid(columns: columns, spacing: rowSpacing) {
            ForEach(0..<12, id: \.self) { _ in
                LibraryPlaceholderPoster(width: width)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
    }
}
