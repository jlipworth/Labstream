#if os(iOS)
import PMSKit
import SwiftUI

/// iPhone/iPad show page (iPhone Duo design spec, Show detail, seasons and episodes).
///
/// One hierarchy in every pose: show → season → episode. The show level is a header (key art,
/// the title once, "3 seasons · TV-14", the one prominent "Resume S1, E3" action with "23m left")
/// above the seasons as a 2:3 poster grid. Where `ShowDetailLayoutPolicy` splits the content
/// region (unfolded sideways) the inner display shows one extra level: this page is the leading
/// list column with the chosen season ringed in amber, and the season's episodes fill the
/// trailing column, with the divider on the hinge in book. Elsewhere choosing a season pushes it.
///
/// Folding collapses the split into show → season with the season and the episode scroll anchor
/// kept; unfolding pops a season page that is on top back into the split.
struct MobileShowBrowser: View {
    let show: MediaItem

    @Environment(AppModel.self) private var appModel
    @Environment(\.metadataRepository) private var metadataRepository
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.labstreamCompactWidth) private var compactWidth
    @Environment(\.duoPose) private var duoPose

    @State private var hydratedShow: MediaItem?
    @State private var seasons: [MediaItem] = []
    @State private var loadState: BrowseLoadState = .idle
    @State private var resumePlan: ShowResumePlan?
    /// The chosen season: ringed in the split, pushed in a single column.
    @State private var selectedSeasonKey: String?
    /// Episode list scroll anchor shared by the split column and the pushed season page.
    @State private var episodeAnchor: String?
    /// An episode pushed from this page (the split's season column or the resume action).
    @State private var pushedEpisode: MediaItem?
    /// An episode pushed from the pushed season page; while set, unfolding keeps that page.
    @State private var seasonPushedEpisode: MediaItem?
    /// The page's global frame: the content region for the split and the hinge conversion.
    @State private var region: CGRect = .zero
    @State private var heroTitleVisible = true
    @State private var viewportHeight: CGFloat = 0
    /// Measured content-region width of the show column (its scroll view minus the safe-area
    /// insets, e.g. the vertical bar's); the key art and the season grid size from it.
    @State private var columnContentWidth: CGFloat = 0

    private var displayShow: MediaItem { hydratedShow ?? show }

    private var layout: ShowDetailLayoutPolicy.Layout {
        var hinge: (minX: Double, maxX: Double)?
        if case .book(let rect) = duoPose {
            hinge = (Double(rect.minX - region.minX), Double(rect.maxX - region.minX))
        }
        return ShowDetailLayoutPolicy.layout(width: Double(region.width),
                                             height: Double(region.height),
                                             regularWidth: horizontalSizeClass == .regular,
                                             hinge: hinge)
    }

    private var isSplit: Bool {
        if case .split = layout { return true }
        return false
    }

    private var selectedSeason: MediaItem? {
        guard let selectedSeasonKey else { return nil }
        return seasons.first { $0.ratingKey == selectedSeasonKey }
    }

    /// The split always shows a season: the chosen one, else the first.
    private var displayedSeason: MediaItem? {
        selectedSeason ?? seasons.first
    }

    var body: some View {
        Group {
            switch layout {
            case .single:
                showColumn(highlightedSeasonKey: nil, columnWidth: columnContentWidth)
            case .split(let listWidth, let detailStart):
                HStack(spacing: 0) {
                    // The list column's width is the split's own; a measured value would lag a
                    // frame behind the single → split flip.
                    showColumn(highlightedSeasonKey: displayedSeason?.ratingKey,
                               columnWidth: CGFloat(listWidth))
                        .frame(width: CGFloat(listWidth))
                    Rectangle()
                        .fill(.separator)
                        .frame(width: 0.5)
                        .accessibilityHidden(true)
                    Color.clear
                        .frame(width: max(CGFloat(detailStart - listWidth) - 0.5, 0))
                        .accessibilityHidden(true)
                    if let season = displayedSeason {
                        MobileSeasonEpisodesView(season: season,
                                                 showsTitle: true,
                                                 anchor: $episodeAnchor,
                                                 onSelect: { pushedEpisode = $0 })
                            .id(season.ratingKey)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { newRegion in
            if region != newRegion { region = newRegion }
        }
        .navigationTitle(heroTitleVisible ? "" : displayShow.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: seasonPagePresented) {
            if let season = selectedSeason {
                MobileSeasonPage(season: season,
                                 anchor: $episodeAnchor,
                                 pushedEpisode: $seasonPushedEpisode)
            }
        }
        .navigationDestination(item: $pushedEpisode) { episode in
            DetailView(item: episode, originBackend: appModel.activeBackend)
        }
        .onChange(of: selectedSeasonKey) { _, _ in
            episodeAnchor = nil
        }
        .task(id: show.ratingKey) { await load() }
    }

    /// The pushed season page exists in a single column only, except that unfolding keeps it
    /// while an episode sits on top of it (navigation is never dropped by a fold).
    private var seasonPagePresented: Binding<Bool> {
        Binding(
            get: {
                guard selectedSeason != nil, pushedEpisode == nil else { return false }
                return !isSplit || seasonPushedEpisode != nil
            },
            set: { presented in
                guard !presented else { return }
                seasonPushedEpisode = nil
                // Only a pop in the single column clears the choice; unfolding into the split
                // dismisses the pushed page but keeps the season chosen.
                if !isSplit { selectedSeasonKey = nil }
            })
    }

    // MARK: - Show column

    private var padding: CGFloat { DS.pagePadding(compact: compactWidth) }

    private func showColumn(highlightedSeasonKey: String?, columnWidth: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                DetailKeyArtBand(path: displayShow.art ?? displayShow.thumb,
                                 height: CGFloat(MobileDetailLayoutPolicy.artworkHeight(
                                    viewportWidth: Double(columnWidth),
                                    viewportHeight: Double(viewportHeight)) ?? 0))
                header
                    .frame(maxWidth: 640, alignment: .leading)
                    .padding(.horizontal, padding)
                if columnWidth > 0 {
                    seasonsSection(highlightedSeasonKey: highlightedSeasonKey,
                                   columnWidth: columnWidth)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, DS.Space.xxxl)
        }
        // The scroll view's own width (its frame already excludes the bar's inset): the column's content
        // region, independent of the content laid out in it (no feedback from the grid's width).
        // `onGeometryChange` also reports the first value, so a fresh column (single ↔ split)
        // measures itself.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            if columnContentWidth != width { columnContentWidth = width }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            if viewportHeight != height { viewportHeight = height }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text(displayShow.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .onScrollVisibilityChange(threshold: 0.01) { visible in
                    heroTitleVisible = visible
                }
            DetailContextLine(parts: MediaDetailCaptions.showContext(
                seasonCount: seasons.isEmpty ? nil : seasons.count,
                contentRating: displayShow.contentRating,
                year: displayShow.year))
            if let resumePlan {
                Button {
                    resume(resumePlan)
                } label: {
                    Label(resumePlan.label, systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                .labstreamGlassProminentButtonStyle()
                .controlSize(.large)
                .padding(.top, DS.Space.xs)
                if let left = resumePlan.timeLeft {
                    Text(left)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let summary = displayShow.summary, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineLimit(4)
                    .padding(.top, DS.Space.xs)
            }
        }
    }

    @ViewBuilder
    private func seasonsSection(highlightedSeasonKey: String?, columnWidth: CGFloat) -> some View {
        switch loadState {
        case .idle, .loading:
            ProgressView("Loading…")
                .controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: 200)
        case .failed(let message):
            ContentUnavailableView("Couldn’t load \(show.title)",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(message))
                .frame(maxWidth: .infinity, minHeight: 240)
        case .loaded:
            if seasons.isEmpty {
                ContentUnavailableView("No seasons", systemImage: "tv",
                                       description: Text("Nothing to show for \(show.title)."))
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    Text("Seasons")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, padding)
                    seasonGrid(highlightedSeasonKey: highlightedSeasonKey, columnWidth: columnWidth)
                }
            }
        }
    }

    /// The seasons as 2:3 posters with measured columns. The column is phone-sized in a single
    /// compact column and in the split, so both use the compact grid style.
    private func seasonGrid(highlightedSeasonKey: String?, columnWidth: CGFloat) -> some View {
        let compactStyle = compactWidth || isSplit
        let style = MobileLibraryGridLayout.Style(
            minimumPosterWidth: compactStyle ? 104 : 168,
            gutter: compactStyle ? Double(DS.Space.md) : Double(DS.Space.xl),
            rowSpacing: Double(DS.Space.lg),
            horizontalPadding: Double(padding),
            minimumColumns: compactStyle ? 3 : 1,
            maximumPosterWidth: compactStyle ? 150 : nil,
            prefersEvenColumnsAboveMinimum: compactStyle)
        let metrics = MobileLibraryGridLayout.metrics(availableWidth: Double(columnWidth), style: style)
        let posterWidth = CGFloat(metrics.posterWidth)
        let columns = Array(repeating: GridItem(.fixed(posterWidth), spacing: CGFloat(metrics.gutter),
                                                alignment: .top),
                            count: max(metrics.columnCount, 1))
        return LazyVGrid(columns: columns, alignment: .leading, spacing: CGFloat(metrics.rowSpacing)) {
            ForEach(seasons, id: \.containerRowIdentity) { season in
                Button {
                    selectedSeasonKey = season.ratingKey
                } label: {
                    MobileSeasonCell(season: season, width: posterWidth,
                                     isSelected: season.ratingKey == highlightedSeasonKey)
                }
                .cardLink()
                .videoCardContextMenu(for: season)
                .accessibilityAddTraits(season.ratingKey == highlightedSeasonKey ? .isSelected : [])
            }
        }
        .padding(.horizontal, padding)
    }

    // MARK: - Actions and loading

    /// Pushes the plan's episode and starts it through the episode page's own Play admission
    /// (the same one-shot autoplay handshake system entries use).
    private func resume(_ plan: ShowResumePlan) {
        SystemEntryRouter.shared.requestAutoPlay(forRatingKey: plan.episode.ratingKey)
        pushedEpisode = plan.episode
    }

    private func load() async {
        loadState = .loading
        do {
            seasons = try await ContainerBrowserView.fetchChildren(of: show, appModel: appModel)
            loadState = .loaded
        } catch {
            loadState = .failed(friendlyMessage(error))
        }
        if let item = await hydrateShow(), !Task.isCancelled { hydratedShow = item }
        let episodes = await DetailRelatedContentLoader.episodes(ofShow: show,
                                                                 backend: appModel.activeBackend,
                                                                 appModel: appModel)
        guard !Task.isCancelled else { return }
        resumePlan = ShowResumePlan.plan(episodes: episodes)
    }

    /// The list/hub payload often lacks art, rating and summary; hydrate the header.
    private func hydrateShow() async -> MediaItem? {
        #if DEBUG
        if DebugUIFixtureCatalog.isBrowseEnabled { return nil }
        #endif
        let result = await DetailMetadataLoader.load(ratingKey: show.ratingKey,
                                                     backend: appModel.activeBackend,
                                                     appModel: appModel,
                                                     repository: metadataRepository,
                                                     policy: .display)
        return result.item
    }
}

/// A season poster in the show page grid: the 2:3 art (ringed in amber when it is the season the
/// split shows), the season title (Body) and "8 episodes" (Caption).
private struct MobileSeasonCell: View {
    let season: MediaItem
    let width: CGFloat
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            PosterImage(path: season.thumb,
                        width: width,
                        height: DS.Poster.height(for: width))
                .overlay(alignment: .bottom) {
                    ProgressSliver(offset: season.viewOffset, duration: season.duration)
                }
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
                .posterHover()
            VStack(alignment: .leading, spacing: 2) {
                Text(season.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(MediaDetailCaptions.episodeCount(season.leafCount) ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

/// The pushed season level: the season is the navigation title, then "8 episodes" and the
/// episode rows. Reached from the show page (state-driven push, sharing the episode anchor) or
/// from any other surface that links straight to a season.
struct MobileSeasonPage: View {
    let season: MediaItem
    private let externalAnchor: Binding<String?>?
    private let pushedEpisode: Binding<MediaItem?>?

    @Environment(AppModel.self) private var appModel
    @State private var localAnchor: String?

    init(season: MediaItem,
         anchor: Binding<String?>? = nil,
         pushedEpisode: Binding<MediaItem?>? = nil) {
        self.season = season
        self.externalAnchor = anchor
        self.pushedEpisode = pushedEpisode
    }

    private var selectAction: ((MediaItem) -> Void)? {
        guard let pushedEpisode else { return nil }
        return { episode in pushedEpisode.wrappedValue = episode }
    }

    var body: some View {
        let content = MobileSeasonEpisodesView(
            season: season,
            showsTitle: false,
            anchor: externalAnchor ?? $localAnchor,
            onSelect: selectAction)
            .navigationTitle(season.title)
            .navigationBarTitleDisplayMode(.inline)
        if let pushedEpisode {
            content.navigationDestination(item: pushedEpisode) { episode in
                DetailView(item: episode, originBackend: appModel.activeBackend)
            }
        } else {
            content
        }
    }
}

/// One season's episode list: an optional in-column title, "8 episodes", then the rows. Owns its
/// load, its scroll anchor and the Download Season action. Rows push through `onSelect` when the
/// caller drives navigation itself, else through the browse stack's `MediaItem` destination.
struct MobileSeasonEpisodesView: View {
    let season: MediaItem
    let showsTitle: Bool
    @Binding var anchor: String?
    let onSelect: ((MediaItem) -> Void)?

    @Environment(AppModel.self) private var appModel
    @Environment(\.labstreamCompactWidth) private var compactWidth

    @State private var episodes: [MediaItem] = []
    @State private var loadState: BrowseLoadState = .idle
    @State private var showingSeasonDownloadPlanner = false
    /// B70: the backend the season planner was opened for, captured at the tap.
    @State private var seasonDownloadPlannerBackend: DownloadBackendKind = .plex

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                if showsTitle {
                    Text(season.title)
                        .font(.title3.weight(.semibold))
                }
                if let count = MediaDetailCaptions.episodeCount(
                    loadState == .loaded ? episodes.count : season.leafCount) {
                    Text(count)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                list
            }
            .padding(.horizontal, DS.pagePadding(compact: compactWidth))
            .padding(.vertical, DS.Space.lg)
        }
        .scrollPosition(id: $anchor, anchor: .top)
        .toolbar {
            if ContainerBrowserFeaturePolicy.showsSeasonDownloadAction(
                supportsDownloads: PlatformFeaturePolicy.supportsDownloads,
                childrenAreEpisodes: true,
                hasLoadedChildren: loadState == .loaded && !episodes.isEmpty
            ) {
                ToolbarItem(placement: .primaryAction) {
                    Button("Download Season", systemImage: "arrow.down.circle") {
                        seasonDownloadPlannerBackend = appModel.activeBackend
                        showingSeasonDownloadPlanner = true
                    }
                }
            }
        }
        .sheet(isPresented: $showingSeasonDownloadPlanner) {
            SeasonDownloadPlannerSheet(season: season, backend: seasonDownloadPlannerBackend)
        }
        .task(id: season.ratingKey) { await load() }
    }

    @ViewBuilder
    private var list: some View {
        switch loadState {
        case .idle, .loading:
            ProgressView("Loading…")
                .controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: 240)
        case .failed(let message):
            ContentUnavailableView("Couldn’t load \(season.title)",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(message))
                .frame(maxWidth: .infinity, minHeight: 240)
        case .loaded:
            if episodes.isEmpty {
                ContentUnavailableView("No episodes", systemImage: "tv",
                                       description: Text("Nothing to show for \(season.title)."))
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                LazyVStack(alignment: .leading, spacing: DS.Space.md) {
                    ForEach(episodes, id: \.containerRowIdentity) { episode in
                        row(for: episode)
                            .id(episode.ratingKey)
                    }
                }
                .scrollTargetLayout()
            }
        }
    }

    @ViewBuilder
    private func row(for episode: MediaItem) -> some View {
        if let onSelect {
            Button {
                onSelect(episode)
            } label: {
                MobileEpisodeRow(episode: episode)
            }
            .cardLink(cornerRadius: DS.Radius.card)
            .videoCardContextMenu(for: episode)
        } else {
            NavigationLink(value: episode) {
                MobileEpisodeRow(episode: episode)
            }
            .cardLink(cornerRadius: DS.Radius.card)
            .videoCardContextMenu(for: episode)
        }
    }

    private func load() async {
        loadState = .loading
        do {
            episodes = try await ContainerBrowserView.fetchChildren(of: season, appModel: appModel)
            loadState = .loaded
        } catch {
            loadState = .failed(friendlyMessage(error))
        }
    }
}
#endif
