import SwiftUI
import PMSKit

/// Home tab: the server's hubs (`GET /hubs`) rendered as horizontal poster rails,
/// Swiftfin-style. Each rail is one `Hub`; tapping a poster opens `DetailView`.
struct HomeView: View {
    let catalogRepository: LibraryCatalogRepository

    @Environment(AppModel.self) private var appModel
    @Environment(\.labstreamCompactWidth) private var compactWidth
    @Environment(\.labstreamHomeUsesDenseSectionSpacing) private var denseSectionSpacing

    @State private var hubs: [Hub] = []
    @State private var mediaBrowserLibraries: [MediaBrowserHomeLibraryLink] = []
    @State private var mediaBrowserRails: [MediaBrowserHomeRail] = []
    @State private var loadState: BrowseLoadState = .idle
    /// Server/backend identity the current hubs were loaded from (pop-back no-op guard).
    /// Includes selected Plex server id because multiple servers can resolve through the same URL.
    @State private var loadedIdentity: AuthenticatedBrowseLoadIdentity?
    @State private var loadGeneration = 0


    /// tvOS: scope for the content's default-focus card (see `HubRail.tvDefaultFocusNamespace`).
    @Namespace private var homeFocusNamespace
    /// tvOS: which grid card holds focus. `prefersDefaultFocus` only governs
    /// initial/programmatic focus — a Down press from the tab bar is resolved
    /// geometrically and lands mid-rail — so entry is corrected by hand: when focus
    /// arrives from OUTSIDE the grid (old value nil) onto the first rail, redirect to
    /// the remembered card (or card 1). Inert off tvOS.
    @FocusState private var tvRailFocus: TVHomeFocusTarget?
    /// Last focused first-rail card — the preferred re-entry target from the tab bar.
    @State private var tvRememberedEntry: TVHomeFocusTarget?

    var body: some View {
        ScrollView {
            switch loadState {
            case .idle, .loading:
                // Skeleton rails instead of a lone spinner: the page keeps its shape
                // while content loads, so the transition to real posters is seamless.
                SkeletonRails()
            case .failed(let message):
                ContentUnavailableView("Couldn’t load Home",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(message))
                .frame(maxWidth: .infinity, minHeight: 360)
            case .loaded:
                if appModel.activeBackend.isMediaBrowser {
                    mediaBrowserHome
                } else if hubs.isEmpty {
                    ContentUnavailableView("Nothing here yet",
                                           systemImage: "house",
                                           description: Text("No hubs returned by the server."))
                    .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    LazyVStack(alignment: .leading,
                               spacing: HomeLayoutMetrics.sectionSpacing(compact: compactWidth,
                                                                        denseSections: denseSectionSpacing)) {
                        // Music un-hidden (#17 Phase 7): artists/albums stay in the
                        // hubs; only TRACK items drop (rail cells have no play
                        // affordance — v2, MUSIC-DESIGN §3.1).
                        ForEach(hubs.hidingMusicTracks) { hub in
                            HubRail(hub: hub,
                                    destination: RailViewAllEligibility.plexRecentlyAdded(
                                        hub: hub, sessionIdentity: appModel.activeBrowseSessionKey),
                                    tvDefaultFocusNamespace:
                                        hub.id == hubs.hidingMusicTracks.first?.id
                                            ? homeFocusNamespace : nil,
                                    tvFocusBinding: $tvRailFocus)
                        }
                    }
                    .padding(.vertical, HomeLayoutMetrics.pageVerticalPadding(compact: compactWidth))
                }
            }
        }
        #if os(tvOS)
        // Entering Home's content from the tab bar should land on the FIRST card of the
        // first rail, not whichever card sits geometrically beneath the focused tab button.
        .focusScope(homeFocusNamespace)
        .onChange(of: tvRailFocus) { oldValue, newValue in
            guard let newValue else { return }
            if oldValue == nil, let firstRail = tvFirstRailID, newValue.rail == firstRail {
                // Entry from outside the grid (tab bar / initial / pop-back). In-grid
                // moves arrive with a non-nil old value and pass through; a pop-back
                // restore lands on the remembered card, so redirect is a no-op there.
                let itemIDs = tvFirstRailItemIDs
                let remembered = tvRememberedEntry.flatMap { target in
                    target.rail == firstRail && itemIDs.contains(target.item) ? target : nil
                }
                let intended = remembered ?? itemIDs.first.map { TVHomeFocusTarget(rail: firstRail, item: $0) }
                if let intended, newValue != intended {
                    tvRailFocus = intended
                    return
                }
            }
            if newValue.rail == tvFirstRailID {
                tvRememberedEntry = newValue
            }
        }
        #endif
        .labstreamTopLevelNavigationTitle("Home")
        // Register the shared Jellyfin/Emby library-link type once, then route it through the
        // active backend. Duplicate registrations make SwiftUI pick one by stack position.
        .navigationDestination(for: MediaBrowserLibraryLink.self) { view in
            switch appModel.activeBackend {
            case .jellyfin:
                LibraryGridView(jellyfin: view)
            case .emby:
                LibraryGridView(emby: view)
            case .plex:
                EmptyView()
            }
        }
        .navigationDestination(for: MediaItem.self) { item in
            // Music items route into the music module, never the video detail/player
            // (#17 Phase 7). Home hubs are cross-section, so no music sectionKey —
            // the artist view falls back to its children endpoint. Video/photo
            // playlists are NOT music and keep the DetailView path.
            if item.isMusicContainer || item.isAudioPlaylist {
                musicDestination(for: item, sectionKey: nil)
            } else {
                // Capture the active backend as the item's origin (#100) so Play / watched /
                // download resolve against the backend the item came from even if the user
                // switches backends while this detail is still on the stack.
                DetailView(item: item, originBackend: appModel.activeBackend)
            }
        }
        .navigationDestination(for: RailViewAllDestination.self) { destination in
            RailViewAllView(destination: destination)
        }
        // Re-run whenever the server URL resolves after discovery/rediscovery.
        .task(id: loadIdentity) { await load() }
        .refreshable { await load(force: true) }
        .onReceive(NotificationCenter.default.publisher(for: LibraryVisibilityStore.didChangeNotification)) { notification in
            reloadHomeIfVisibilityChanged(notification)
        }
    }

    private var loadIdentity: AuthenticatedBrowseLoadIdentity {
        AuthenticatedBrowseLoadIdentity(appModel: appModel)
    }

    /// First rail's id as the `HubRail` sees it (mediaBrowser rails wrap into a
    /// synthesized `Hub` whose identifier is prefixed with the backend).
    private var tvFirstRailID: String? {
        if appModel.activeBackend.isMediaBrowser {
            return mediaBrowserRails.first.map { "\(appModel.activeBackend.rawValue)-\($0.id)" }
        }
        return hubs.hidingMusicTracks.first?.id
    }

    private var tvFirstRailItemIDs: [String] {
        if appModel.activeBackend.isMediaBrowser {
            return mediaBrowserRails.first?.items.map(\.id) ?? []
        }
        return hubs.hidingMusicTracks.first?.metadata.map(\.id) ?? []
    }

    @ViewBuilder
    private var mediaBrowserHome: some View {
        if mediaBrowserLibraries.isEmpty {
            ContentUnavailableView("No \(appModel.activeBackend.displayName) libraries",
                                   systemImage: "rectangle.stack",
                                   description: Text("This \(appModel.activeBackend.displayName) user has no visible libraries."))
            .frame(maxWidth: .infinity, minHeight: 360)
        } else {
            LazyVStack(alignment: .leading,
                       spacing: HomeLayoutMetrics.sectionSpacing(compact: compactWidth,
                                                                denseSections: denseSectionSpacing)) {
                if mediaBrowserRails.isEmpty {
                    ContentUnavailableView("Open a library to browse",
                                           systemImage: "rectangle.stack",
                                           description: Text("\(appModel.activeBackend.displayName) did not return preview items for these libraries."))
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    ForEach(mediaBrowserRails) { rail in
                        HubRail(hub: Hub(title: rail.title,
                                         hubIdentifier: "\(appModel.activeBackend.rawValue)-\(rail.id)",
                                         metadata: rail.items),
                                destination: rail.destination,
                                tvDefaultFocusNamespace:
                                    rail.id == mediaBrowserRails.first?.id
                                        ? homeFocusNamespace : nil,
                                tvFocusBinding: $tvRailFocus)
                        .macHomeMeasurementMilestone(rail.id == mediaBrowserRails.first?.id)
                    }
                }
            }
            .padding(.vertical, HomeLayoutMetrics.pageVerticalPadding(compact: compactWidth))
        }
    }

    private func load(force: Bool = false) async {
        // `.task` also re-fires every time the stack pops back to Home; without this
        // guard the rails reload and dump the scroll position the user returned to.
        // A real server change (different URL) still reloads.
        let activeIdentity = loadIdentity
        if !force, loadedIdentity == activeIdentity, case .loaded = loadState { return }
        loadGeneration += 1
        let generation = loadGeneration

        #if DEBUG
        if let fixture = DebugUIFixtureCatalog.homeContent(for: appModel.activeBackend) {
            hubs = fixture.hubs
            mediaBrowserLibraries = fixture.mediaBrowserLibraries
            mediaBrowserRails = fixture.mediaBrowserRails
            loadedIdentity = activeIdentity
            loadState = .loaded
            return
        }
        #endif

        let span = PerformanceInstrumentation.begin(.homeLoad,
                                                     backend: appModel.activeBackend.performanceLabel,
                                                     fields: ["force": force ? 1 : 0])
        let firstContentSpan = PerformanceInstrumentation.begin(
            .homeFirstContent,
            backend: appModel.activeBackend.performanceLabel)
        #if DEBUG || PERFORMANCE_AUDIT
        var publicationCount = 0
        #endif
        if appModel.activeBackend.isMediaBrowser {
            loadState = .loading
            do {
                // Mirror the Libraries screen: hide library rails the user has hidden (#104).
                // Jellyfin/Emby Home rails are library-scoped (built from `views`), so filtering
                // `views` here keeps Home consistent. (Plex Home uses non-library `/hubs` and is
                // deferred — see #104.)
                // The backend can change while an earlier Home task is unwinding. A Plex task uses
                // native hubs and must never enter the Jellyfin/Emby provider.
                guard let provider = MediaBrowserHomeProvider(appModel: appModel,
                                                              catalogRepository: catalogRepository) else {
                    firstContentSpan.end(result: "superseded")
                    span.end(result: "superseded")
                    return
                }
                let content = try await provider.loadHome(forceRefresh: force) { snapshot in
                    guard generation == loadGeneration,
                          loadIdentity == activeIdentity,
                          !Task.isCancelled else { return }
                    mediaBrowserLibraries = snapshot.libraries
                    mediaBrowserRails = snapshot.rails
                    loadedIdentity = MediaBrowserHomePublicationPolicy.shouldPin(snapshot)
                        ? activeIdentity : nil
                    loadState = MediaBrowserHomePublicationPolicy.shouldShowLoadedState(snapshot)
                        ? .loaded : .loading
                    #if DEBUG || PERFORMANCE_AUDIT
                    publicationCount += 1
                    let itemCount = snapshot.rails.reduce(0) { $0 + $1.items.count }
                    if itemCount > 0 {
                        firstContentSpan.end(
                            result: BrowsePerformanceMeasurementPolicy.firstContentResult(itemCount: itemCount),
                            fields: [
                            "content_present": 1,
                            "rail_count": snapshot.rails.count,
                            "item_count": itemCount,
                            "publication_count": publicationCount,
                        ])
                    }
                    #endif
                }
                guard generation == loadGeneration,
                      loadIdentity == activeIdentity,
                      !Task.isCancelled else {
                    firstContentSpan.end(result: Task.isCancelled ? "cancelled" : "superseded")
                    span.end(result: Task.isCancelled ? "cancelled" : "superseded")
                    return
                }
                if let session = appModel.backendSession(for: appModel.activeBackend) {
                    SpotlightIndexer.index(content.rails.flatMap(\.items),
                                           backend: appModel.activeBackend,
                                           server: session.baseURL)
                    LabstreamShortcuts.updateAppShortcutParameters()
                }
                #if DEBUG || PERFORMANCE_AUDIT
                span.end(fields: [
                    "view_count": content.libraries.count,
                    "rail_count": mediaBrowserRails.count,
                    "item_count": mediaBrowserRails.reduce(0) { $0 + $1.items.count },
                    "degraded": content.isDegraded ? 1 : 0,
                    "pending_rail_count": content.pendingRailKeys.count,
                    "publication_count": publicationCount,
                ])
                let terminalItemCount = mediaBrowserRails.reduce(0) { $0 + $1.items.count }
                firstContentSpan.end(
                    result: BrowsePerformanceMeasurementPolicy.firstContentResult(itemCount: terminalItemCount),
                    fields: [
                    "content_present": terminalItemCount > 0 ? 1 : 0,
                    "rail_count": mediaBrowserRails.count,
                    "item_count": terminalItemCount,
                    "publication_count": publicationCount,
                ])
                #else
                span.end(fields: [
                    "view_count": content.libraries.count,
                    "rail_count": mediaBrowserRails.count,
                    "item_count": mediaBrowserRails.reduce(0) { $0 + $1.items.count },
                    "degraded": content.isDegraded ? 1 : 0,
                    "pending_rail_count": content.pendingRailKeys.count,
                ])
                #endif
            } catch {
                guard generation == loadGeneration,
                      loadIdentity == activeIdentity,
                      !Task.isCancelled else {
                    firstContentSpan.end(result: Task.isCancelled ? "cancelled" : "superseded")
                    span.end(result: Task.isCancelled ? "cancelled" : "superseded")
                    return
                }
                firstContentSpan.end(result: "failure",
                                     fields: ["error": PerformanceInstrumentation.errorLabel(error)])
                span.end(result: "failure", fields: ["error": PerformanceInstrumentation.errorLabel(error)])
                loadState = .failed(friendlyMessage(error))
            }
            return
        }

        guard let service = try? PlexBrowseService(appModel: appModel) else {
            firstContentSpan.end(result: "failure", fields: ["error": "missing_plex_server"])
            span.end(result: "failure", fields: ["error": "missing_plex_server"])
            loadState = .failed("No reachable Plex server selected.")
            return
        }
        loadState = .loading
        do {
            let loadedHubs = try await service.hubs()
            guard generation == loadGeneration,
                      loadIdentity == activeIdentity,
                      !Task.isCancelled else {
                firstContentSpan.end(result: Task.isCancelled ? "cancelled" : "superseded")
                span.end(result: Task.isCancelled ? "cancelled" : "superseded")
                return
            }
            hubs = loadedHubs
            loadedIdentity = activeIdentity
            loadState = .loaded
            #if DEBUG || PERFORMANCE_AUDIT
            publicationCount = 1
            let itemCount = hubs.reduce(0) { $0 + $1.metadata.count }
            firstContentSpan.end(
                result: BrowsePerformanceMeasurementPolicy.firstContentResult(itemCount: itemCount),
                fields: [
                "content_present": itemCount > 0 ? 1 : 0,
                "rail_count": hubs.count,
                "item_count": itemCount,
                "publication_count": publicationCount,
            ])
            span.end(fields: [
                "hub_count": hubs.count,
                "item_count": hubs.reduce(0) { $0 + $1.metadata.count },
                "publication_count": publicationCount,
            ])
            #else
            span.end(fields: [
                "hub_count": hubs.count,
                "item_count": hubs.reduce(0) { $0 + $1.metadata.count },
            ])
            #endif
            // System integration (#24): make the just-browsed items findable in
            // Spotlight, and refresh the "Play <title> on Labstream" Siri phrase
            // vocabulary (drawn from the entity query's suggestions).
            SpotlightIndexer.index(hubs.flatMap(\.metadata), server: service.session.baseURL)
            LabstreamShortcuts.updateAppShortcutParameters()
        } catch {
            guard generation == loadGeneration,
                  loadIdentity == activeIdentity,
                  !Task.isCancelled else {
                firstContentSpan.end(result: Task.isCancelled ? "cancelled" : "superseded")
                span.end(result: Task.isCancelled ? "cancelled" : "superseded")
                return
            }
            firstContentSpan.end(result: "failure",
                                 fields: ["error": PerformanceInstrumentation.errorLabel(error)])
            span.end(result: "failure", fields: ["error": PerformanceInstrumentation.errorLabel(error)])
            loadState = .failed(friendlyMessage(error))
        }
    }

    /// Jellyfin/Emby Home rails are filtered by the same hidden-library set as the Libraries
    /// screen (#104). Settings can change that set while Home remains mounted in its tab, so
    /// refresh the active MediaBrowser home when the relevant backend key changes. Plex Home uses
    /// non-library `/hubs` and is intentionally deferred for #104, so no reload is needed there.
    private func reloadHomeIfVisibilityChanged(_ notification: Notification) {
        guard appModel.activeBackend != .plex,
              let backendKey = notification.userInfo?[LibraryVisibilityStore.didChangeBackendKeyUserInfoKey] as? String,
              backendKey == appModel.libraryVisibilityBackendKey else { return }
        Task { await load(force: true) }
    }
}

private extension View {
    @ViewBuilder
    func macHomeMeasurementMilestone(_ isFirstRail: Bool) -> some View {
        #if os(macOS)
        if isFirstRail {
            accessibilityIdentifier("performance.mac.home.first-rail")
        } else {
            self
        }
        #else
        self
        #endif
    }
}

/// (rail, card) coordinate of a focused Home cell — tvOS entry-redirect bookkeeping.
struct TVHomeFocusTarget: Hashable {
    let rail: String
    let item: String
}

/// One horizontal rail of posters for a hub.
private struct HubRail: View {
    let hub: Hub
    let destination: RailViewAllDestination?
    /// Non-nil on the screen's FIRST rail (tvOS): its leading card becomes the scope's
    /// default focus, so entering the content from the tab bar lands on card 1 instead of
    /// whichever card happens to sit geometrically beneath the focused tab button.
    var tvDefaultFocusNamespace: Namespace.ID? = nil
    /// Shared per-card focus tracker for the WHOLE grid (tvOS): every rail reports, so
    /// a nil→card transition provably means focus entered from outside the grid.
    var tvFocusBinding: FocusState<TVHomeFocusTarget?>.Binding? = nil

    @Environment(\.labstreamCompactWidth) private var compactWidth
    @Environment(\.labstreamHomeUsesDenseSectionSpacing) private var denseSectionSpacing

    #if os(tvOS)
    @ScaledMetric(relativeTo: .body) private var shelfLabelHeight: CGFloat = 100
    #elseif os(iOS)
    // Body (`.subheadline` semibold) title plus a Caption context line.
    @ScaledMetric(relativeTo: .subheadline) private var shelfLabelHeight: CGFloat = 38
    #else
    @ScaledMetric(relativeTo: .headline) private var shelfLabelHeight: CGFloat = 46
    #endif

    /// The rail viewport (content region) width, measured so posters show whole cards plus a cue.
    @State private var railViewportWidth: CGFloat?
    /// First visible card, kept across a fold or resize.
    @State private var firstVisibleItemID: String?

    private var presentation: HomeRailArtworkPolicy.Presentation? {
        HomeShelfPresentationPolicy.presentation(for: hub)
    }

    private var captionKind: HomeShelfCaptionPolicy.Kind {
        HomeShelfCaptionPolicy.kind(for: hub.metadata, shelfIdentifier: hub.id)
    }

    private var shelfWidth: CGFloat {
        presentation == .landscape
            ? HomeRailCellMetrics.episodeWidth(compact: compactWidth)
            : DS.Poster.measuredRailWidth(viewport: railViewportWidth,
                                          compact: compactWidth,
                                          margin: DS.Scroll.railHorizontalMargin(compact: compactWidth),
                                          gutter: HomeLayoutMetrics.itemSpacing(compact: compactWidth))
    }

    private var shelfImageHeight: CGFloat {
        shelfWidth / CGFloat(presentation?.aspectRatio ?? Double(DS.Poster.aspect))
    }

    private var shelfHeight: CGFloat? {
        guard let presentation else { return nil }
        let contentHeight = shelfImageHeight + DS.Space.sm + shelfLabelHeight
        if presentation == .landscape,
           HomeLayoutMetrics.reservePosterHeightForEpisodeRails(denseSections: denseSectionSpacing) {
            return max(contentHeight, DS.Poster.height(for: shelfWidth)
                       + DS.Space.sm + shelfLabelHeight)
        }
        return contentHeight
    }

    var body: some View {
        VStack(alignment: .leading,
               spacing: HomeLayoutMetrics.titleToRailSpacing(compact: compactWidth,
                                                             denseSections: denseSectionSpacing)) {
            RailSectionHeader(title: hub.title, destination: destination)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: HomeLayoutMetrics.itemSpacing(compact: compactWidth)) {
                    ForEach(hub.metadata) { item in
                        NavigationLink(value: item) {
                            if let presentation {
                                HomeShelfMediaCell(item: item, presentation: presentation,
                                                   width: shelfWidth, imageHeight: shelfImageHeight,
                                                   labelHeight: shelfLabelHeight,
                                                   captionKind: captionKind)
                            } else {
                                RailMediaCell(item: item)
                            }
                        }
                        .accessibilityIdentifier("labstream.home.\(hub.id).\(item.ratingKey)")
                        #if os(tvOS)
                        .tvPrefersDefaultFocus(item.id == hub.metadata.first?.id,
                                               in: tvDefaultFocusNamespace)
                        .tvFocusTracked(tvFocusBinding,
                                        equals: TVHomeFocusTarget(rail: hub.id, item: item.id))
                        #endif
                        .cardLink()
                        .videoCardContextMenu(for: item)
                    }

                    #if os(tvOS)
                    if let destination {
                        RailViewAllCard(title: hub.title,
                                        destination: destination,
                                        width: viewAllCardSize.width,
                                        height: viewAllCardSize.height)
                    }
                    #endif
                }
                .railScrollTargetLayout()
                // LazyHStack must not infer the shelf height from its currently realized cards.
                .frame(height: shelfHeight, alignment: .top)
                .padding(.vertical,
                         HomeLayoutMetrics.railVerticalPadding(denseSections: denseSectionSpacing))
            }
            // Inset the scroll content via contentMargins, not .padding on the stack —
            // keeps the inset out of the cards' own geometry (see the gaze-routing
            // gotcha in docs/DEVELOPMENT.md).
            .mediaRailScrollStyle(horizontalMargin: DS.Scroll.railHorizontalMargin(compact: compactWidth))
            .railScrollAnchor($firstVisibleItemID)
            .railViewportWidth($railViewportWidth)
            .accessibilityIdentifier("labstream.home.rail.\(hub.id)")
            #if os(tvOS)
            // Declared focus row: vertical moves treat the whole rail as a target, so a
            // card whose column doesn't overlap the row above/below still routes into it.
            .focusSection()
            #endif
        }
    }

    #if os(tvOS)
    /// Match the trailing View All card to the rail's artwork frame: 16:9 for episode
    /// shelves, the canonical 2:3 poster otherwise.
    private var viewAllCardSize: CGSize {
        CGSize(width: shelfWidth, height: shelfImageHeight)
    }
    #endif
}

/// Home-only card: uniform shelf geometry, with aspect-preserving fill and crop.
private struct HomeShelfMediaCell: View {
    let item: MediaItem
    let presentation: HomeRailArtworkPolicy.Presentation
    let width: CGFloat
    let imageHeight: CGFloat
    let labelHeight: CGFloat
    var captionKind: HomeShelfCaptionPolicy.Kind = .none

    var body: some View {
        let artwork = HomeShelfPresentationPolicy.artwork(for: item, presentation: presentation)
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            PosterImage(path: artwork.path, width: width, height: imageHeight,
                        requestAspectRatio: HomeShelfPresentationPolicy.sourceAspect(for: item, artwork: artwork))
                .overlay(alignment: .bottom) {
                    ProgressSliver(offset: item.viewOffset, duration: item.duration)
                }
                .posterHover()
                .tvFocusHighlight()
            VStack(alignment: .leading, spacing: 2) {
                Text(item.kind == .episode ? item.grandparentTitle ?? item.title : item.title)
                    #if os(tvOS)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                    #elseif os(iOS)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    #else
                    .font(.headline)
                    .lineLimit(1)
                    #endif
                #if os(iOS)
                // Every sibling shows the same field (HomeShelfCaptionPolicy); an empty line
                // keeps the reserved label height so rows stay aligned.
                if let caption = HomeShelfCaptionPolicy.caption(for: item, kind: captionKind) {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                #else
                if item.kind == .episode {
                    Text([item.seasonEpisodeCode, item.title].compactMap { $0 }.joined(separator: " · "))
                        .font(subtitleFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let year = item.year {
                    Text(String(year))
                        .font(subtitleFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                #endif
            }
            .frame(width: width, height: labelHeight, alignment: .topLeading)
        }
        .frame(width: width, alignment: .topLeading)
    }

    private var subtitleFont: Font {
        #if os(tvOS)
        .caption
        #else
        .subheadline
        #endif
    }
}

private enum HomeLayoutMetrics {
    static func itemSpacing(compact: Bool) -> CGFloat {
        #if os(tvOS)
        32
        #else
        compact ? DS.Space.md : DS.Space.xl
        #endif
    }

    static func sectionSpacing(compact: Bool, denseSections: Bool) -> CGFloat {
        if compact { return DS.Space.xl }
        return denseSections ? DS.Space.xxl : DS.Space.xxxl
    }

    static func titleToRailSpacing(compact: Bool, denseSections: Bool) -> CGFloat {
        if compact { return DS.Space.sm }
        return denseSections ? DS.Space.md : DS.Space.lg
    }

    static func railVerticalPadding(denseSections: Bool) -> CGFloat {
        denseSections ? DS.Space.xs : DS.Space.sm
    }

    static func pageVerticalPadding(compact: Bool) -> CGFloat {
        #if os(tvOS)
        32
        #else
        compact ? DS.Space.lg : DS.Space.xl
        #endif
    }

    static func reservePosterHeightForEpisodeRails(denseSections: Bool) -> Bool {
        !denseSections
    }
}

private extension EnvironmentValues {
    /// Dense spacing is for a large two-dimensional viewport: regular width AND regular height
    /// (a full-size iPad, a wide iPad window, the unfolded iPhone Duo inner display). macOS has
    /// the same desktop-density problem. It stays off any compact-height viewport (iPhone
    /// landscape can report regular width but should keep the compact phone rhythm) and off
    /// visionOS so its authored window rhythm remains unchanged. The size classes are read
    /// from the environment, so a resize or fold re-evaluates it.
    var labstreamHomeUsesDenseSectionSpacing: Bool {
        #if os(iOS)
        horizontalSizeClass == .regular && verticalSizeClass == .regular
        #elseif os(macOS)
        true
        #else
        false
        #endif
    }
}

/// Search/standard rails retain item-specific artwork; Home uses HomeShelfMediaCell.
struct RailMediaCell: View {
    let item: MediaItem
    /// Measured rail poster width (`DS.Poster.measuredRailWidth`); nil keeps the authored width.
    var posterWidth: CGFloat? = nil

    @ViewBuilder
    var body: some View {
        if item.kind == .episode {
            EpisodeRailCell(item: item)
        } else {
            PosterCell(item: item, width: posterWidth)
        }
    }
}

/// Shared sizing for Home/media-browser rails.
///
/// Episode rails use 16:9 stills while movie/show rails use the canonical 2:3 poster.
/// visionOS and compact phone-class layouts keep the old poster-height reservation for
/// stable rail rhythm, but regular iPad/macOS Home lets episode rails use their natural
/// height so 16:9 "On Deck" shelves do not leave a poster-sized blank tail (#234).
private enum HomeRailCellMetrics {
    static func episodeWidth(compact: Bool) -> CGFloat {
        #if os(tvOS)
        360
        #else
        compact ? 196 : 252
        #endif
    }
    static func episodeImageHeight(compact: Bool) -> CGFloat {
        episodeWidth(compact: compact)
            / CGFloat(HomeRailArtworkPolicy.Presentation.landscape.aspectRatio)
    }
    #if os(tvOS)
    static let titleBlockHeight: CGFloat = 60
    #else
    static let titleBlockHeight: CGFloat = 46
    #endif
    static func canonicalCellHeight(compact: Bool) -> CGFloat {
        DS.Poster.height(for: DS.Poster.railWidth(compact: compact)) + DS.Space.sm + titleBlockHeight
    }
    static func episodeCellHeight(compact: Bool, denseSections: Bool) -> CGFloat? {
        HomeLayoutMetrics.reservePosterHeightForEpisodeRails(denseSections: denseSections)
            ? canonicalCellHeight(compact: compact)
            : nil
    }
}

private struct EpisodeRailCell: View {
    let item: MediaItem
    var artworkPath: String?

    @Environment(\.labstreamCompactWidth) private var compactWidth
    @Environment(\.labstreamHomeUsesDenseSectionSpacing) private var denseSectionSpacing

    private var width: CGFloat { HomeRailCellMetrics.episodeWidth(compact: compactWidth) }
    private var height: CGFloat { HomeRailCellMetrics.episodeImageHeight(compact: compactWidth) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            PosterImage(path: artworkPath ?? item.episodeRailArtworkPath,
                        width: width,
                        height: height,
                        cornerRadius: DS.Radius.poster)
                .overlay(alignment: .bottom) { progressSliver }
                .posterHover()
                .tvFocusHighlight()

            VStack(alignment: .leading, spacing: 2) {
                Text(item.grandparentTitle ?? item.title)
                    .font(episodeTitleFont)
                    .lineLimit(1)
                Text(episodeSubtitle)
                    .font(episodeSubtitleFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: width,
               height: HomeRailCellMetrics.episodeCellHeight(compact: compactWidth,
                                                             denseSections: denseSectionSpacing),
               alignment: .topLeading)
    }

    private var episodeSubtitle: String {
        if let code = item.seasonEpisodeCode {
            return "\(code) · \(item.title)"
        }
        return item.title
    }

    /// tvOS text styles run big (headline is 38pt); captions under a 360-pt still read
    /// oversized at TV sizes, so the TV pass drops one weight class.
    private var episodeTitleFont: Font {
        #if os(tvOS)
        .body.weight(.medium)
        #else
        .headline
        #endif
    }

    private var episodeSubtitleFont: Font {
        #if os(tvOS)
        .caption
        #else
        .subheadline
        #endif
    }

    private var progressSliver: some View {
        ProgressSliver(offset: item.viewOffset, duration: item.duration)
    }
}

private extension MediaItem {
    /// Episode rails want a 16:9 still first. If a backend omits the episode still, fall back
    /// through backdrop-style art before using season/show posters so the card is less likely to
    /// be an empty tile.
    var episodeRailArtworkPath: String? {
        thumb ?? art ?? parentThumb ?? grandparentThumb
    }
}

/// A poster + title cell used in rails and grids.
///
/// Visual polish: a fixed 2:3 poster, a continue-watching progress sliver when the
/// item has a resume point, and a visionOS hover lift. The title block reserves a
/// stable height so rows of cells with 1- vs 2-line titles still align cleanly.
enum PosterCellLabelStyle {
    case standard
    case denseLibrary
}

#if DEBUG || PERFORMANCE_AUDIT
/// Opt-in roles for narrow performance-audit milestones. Ordinary poster callers remain
/// unscoped; the library grid assigns this only to its stable first slot.
enum PosterArtworkMeasurementRole: Equatable {
    case coldFirstPoster
}
#endif

struct PosterCell: View {
    let item: MediaItem
    /// Explicit width from grid callers; nil means "rail default for this size class".
    var width: CGFloat?
    /// Optional artwork override for Home episode posters. Defaults to `item.thumb` so
    /// movies, music, library grids, search, detail/offline-adjacent callers stay unchanged.
    var artworkPath: String?
    /// Optional width/height aspect override for artwork whose shape is known independently
    /// of `item.primaryImageAspectRatio` (e.g. season poster art on an episode item).
    var aspectOverride: Double?
    /// Compact library grids use denser typography; rail/search/music callers retain defaults.
    var labelStyle: PosterCellLabelStyle = .standard
    #if DEBUG || PERFORMANCE_AUDIT
    /// Optional audit role forwarded unchanged to the image loader.
    var artworkMeasurementRole: PosterArtworkMeasurementRole?
    #endif

    @Environment(\.labstreamCompactWidth) private var compactWidth

    private var resolvedWidth: CGFloat {
        width ?? DS.Poster.railWidth(compact: compactWidth)
    }

    /// Render at the item's real artwork ratio when the backend reports one (Jellyfin/Emby
    /// `PrimaryImageAspectRatio`: 16:9 YouTube, square Twitch, 16:9 episode stills), else the
    /// canonical 2:3 poster. Plex reports no ratio, so it stays 2:3 (GH #101).
    private var height: CGFloat {
        let aspect = aspectOverride
            ?? item.resolvedPosterAspect(fallback: Double(DS.Poster.aspect))
        return CGFloat(Double(resolvedWidth) / aspect)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            posterArtworkImage
                .overlay(alignment: .bottom) { progressSliver }
                .posterHover()
                .tvFocusHighlight()

            VStack(alignment: .leading, spacing: 2) {
                // Episodes read like Plex/Emby: show name on top, then
                // "S{parentIndex}E{index} · {title}". Everything else keeps the
                // title + year treatment.
                if item.kind == .episode {
                    Text(item.grandparentTitle ?? item.title)
                        .font(primaryLabelFont)
                        .lineLimit(primaryLabelLineLimit)
                    Text(episodeSubtitle)
                        .font(secondaryLabelFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(item.title)
                        .font(primaryLabelFont)
                        .lineLimit(primaryLabelLineLimit)
                    if let year = item.year {
                        Text(String(year))
                            .font(secondaryLabelFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(width: resolvedWidth, alignment: .leading)
        // NOTE: no hover effect here — the wrapping link uses `.cardLink()`, whose
        // built-in `.plain` style draws (and correctly registers) the gaze highlight.
        // A custom ButtonStyle here misroutes pinches to neighboring cards (DEVELOPMENT.md).
    }

    @ViewBuilder
    private var posterArtworkImage: some View {
        #if DEBUG || PERFORMANCE_AUDIT
        PosterImage(path: artworkPath ?? item.thumb,
                    width: resolvedWidth,
                    height: height,
                    measurementRole: artworkMeasurementRole)
        #else
        PosterImage(path: artworkPath ?? item.thumb, width: resolvedWidth, height: height)
        #endif
    }

    private var primaryLabelFont: Font {
        #if os(tvOS)
        // headline (38pt) overwhelms a 236-pt poster at TV sizes; body-medium (29pt)
        // matches the caption weight of Apple's own TV shelves.
        .body.weight(.medium)
        #elseif os(iOS)
        // iPhone/iPad type pass: card titles are Body, context lines Caption, in every
        // grid and rail (iPhone Duo design spec, Color & type).
        .subheadline.weight(.semibold)
        #else
        labelStyle == .denseLibrary ? .subheadline.weight(.semibold) : .headline
        #endif
    }

    private var secondaryLabelFont: Font {
        #if os(tvOS) || os(iOS)
        .caption
        #else
        labelStyle == .denseLibrary ? .caption : .subheadline
        #endif
    }

    private var primaryLabelLineLimit: Int {
        #if os(tvOS)
        2
        #else
        1
        #endif
    }

    /// "S{x}E{y} · {title}" for an episode poster's second line, gracefully dropping the
    /// code when the season/episode numbers are missing.
    private var episodeSubtitle: String {
        if let code = item.seasonEpisodeCode {
            return "\(code) · \(item.title)"
        }
        return item.title
    }

    /// A thin "continue watching" progress bar pinned to the poster's bottom edge,
    /// shown only when the item carries a resume offset. Mirrors Plex/Netflix posters.
    private var progressSliver: some View {
        ProgressSliver(offset: item.viewOffset, duration: item.duration)
    }
}

/// Placeholder rails shown while Home loads — a couple of titled rows of shimmering
/// poster blanks so the screen has structure (and no jarring spinner-to-grid jump).
struct SkeletonRails: View {
    @Environment(\.labstreamCompactWidth) private var compactWidth
    @Environment(\.labstreamHomeUsesDenseSectionSpacing) private var denseSectionSpacing

    var body: some View {
        VStack(alignment: .leading,
               spacing: HomeLayoutMetrics.sectionSpacing(compact: compactWidth,
                                                         denseSections: denseSectionSpacing)) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading,
                       spacing: HomeLayoutMetrics.titleToRailSpacing(compact: compactWidth,
                                                                     denseSections: denseSectionSpacing)) {
                    RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                        .fill(.regularMaterial)
                        .frame(width: 200, height: 26)
                        .overlay { ShimmerView() }
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                        .padding(.horizontal, DS.Scroll.railHorizontalMargin(compact: compactWidth))

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: compactWidth ? DS.Space.md : DS.Space.xl) {
                            ForEach(0..<5, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous)
                                    .fill(.regularMaterial)
                                    .frame(width: DS.Poster.railWidth(compact: compactWidth),
                                           height: DS.Poster.height(for: DS.Poster.railWidth(compact: compactWidth)))
                                    .overlay { ShimmerView() }
                                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous))
                            }
                        }
                    }
                    .mediaRailScrollStyle(horizontalMargin: DS.Scroll.railHorizontalMargin(compact: compactWidth),
                                          clipDisabled: false)
                    .scrollDisabled(true)
                }
            }
        }
        .padding(.vertical, HomeLayoutMetrics.pageVerticalPadding(compact: compactWidth))
    }
}

/// Map a thrown error (often `PlexError`) to a short user-facing string.
func friendlyMessage(_ error: Error) -> String {
    // Labstream-authored playback messages (e.g. the DV P5 guard block, GH #196) are
    // already user-safe — surface them verbatim instead of redacting to a code.
    let nsError = error as NSError
    if nsError.domain == "Labstream.Playback",
       let message = nsError.userInfo[NSLocalizedDescriptionKey] as? String {
        return message
    }
    if let plex = error as? PlexError {
        switch plex {
        case .unauthorized: return "Your session expired. Please sign in again."
        case .serverUnreachable: return "Couldn’t reach the server."
        case .http(let code): return "Server error (HTTP \(code))."
        case .decoding: return "Unexpected response from the server."
        }
    }

    return DiagnosticRedactor.safeUserFacingErrorMessage(error, operation: "Loading")
}

// MARK: - Music track filtering (#17 Phase 7 — replaces the #15 full hide)

extension Array where Element == Hub {
    /// Drops TRACK items from each hub (and any hub left empty). The #15-era
    /// `hidingMusic` full strip is gone — artists/albums now render and route via
    /// `musicDestination` — but track cells in a generic poster rail would navigate
    /// instead of play, so they stay out until rails grow a play affordance
    /// (MUSIC-DESIGN §3.1, v2).
    var hidingMusicTracks: [Hub] {
        compactMap { hub in
            let kept = hub.metadata.filter { $0.kind != .track }
            guard !kept.isEmpty else { return nil }
            return Hub(hubKey: hub.hubKey, key: hub.key, title: hub.title, type: hub.type,
                       hubIdentifier: hub.hubIdentifier, size: hub.size, metadata: kept)
        }
    }
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
