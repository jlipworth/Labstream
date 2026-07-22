import SwiftUI
import PMSKit

/// Search tab: queries the active backend and renders normalized library/type groups
/// into the same Detail flow as browse. Debounced via `.task(id:)`.
///
/// Results stay inside their source library in backend-native library order. Within
/// a library, video types precede Artists, Albums, Songs, and Playlists; song rows
/// play while music containers retain the library id needed for rich navigation.
struct SearchView: View {
    /// Bumped by RootView's ⌘F shortcut to request focus of the search field. A plain
    /// counter (not a Bool) so every press re-triggers the focus `.task`, even when the
    /// Search tab is already frontmost.
    let focusRequest: Int
    /// Shell hook for leaving the dedicated Search tab/surface after the user clears
    /// the query. In the iOS search-role tab this restores the normal browse tab chrome.
    let onClearSearch: (() -> Void)?
    private let externalQuery: Binding<String>?

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismissSearch) private var dismissSearch

    @State private var internalQuery = ""
    @State private var results: SearchResults = .empty
    @State private var loadState: BrowseLoadState = .idle
    /// The query the current results were fetched for (pop-back no-op guard).
    @State private var loadedQuery: String?
    /// Drives programmatic focus of the `.searchable` field for ⌘F (RootView).
    @FocusState private var searchFieldFocused: Bool

    init(query: Binding<String>? = nil,
         focusRequest: Int = 0,
         onClearSearch: (() -> Void)? = nil) {
        self.externalQuery = query
        self.focusRequest = focusRequest
        self.onClearSearch = onClearSearch
    }

    var body: some View {
        searchSurface
        .labstreamTopLevelNavigationTitle("Search")
        .navigationDestination(for: MediaItem.self) { item in
            // Capture the active backend as the item's origin (#100) so actions resolve
            // against the source backend even after a backend switch.
            DetailView(item: item, originBackend: appModel.activeBackend)
        }
        .navigationDestination(for: SearchMusicDestination.self) { destination in
            musicDestination(for: destination.item, sectionKey: destination.libraryID)
        }
        .navigationDestination(for: RailViewAllDestination.self) { destination in
            RailViewAllView(destination: destination)
        }
        #if !os(tvOS)
        .toolbar {
            if externalQuery == nil, showsClearSearchButton {
                #if os(macOS)
                ToolbarItem {
                    clearSearchToolbarButton
                }
                #else
                ToolbarItem(placement: .topBarTrailing) {
                    clearSearchToolbarButton
                }
                #endif
            }
        }
        #endif
        .task(id: searchTaskID) {
            await runSearch()
        }
        // ⌘F focus: runs on mount (arriving from a tab switch) and on every re-press.
        .task(id: focusRequest) {
            guard externalQuery == nil, focusRequest > 0 else { return }
            // Let the search bar install before requesting focus, especially right after
            // a tab switch mounts this view.
            try? await Task.sleep(for: .milliseconds(50))
            searchFieldFocused = true
        }
    }

    /// `.searchable`'s navigation-owned search field can display the tvOS keyboard without
    /// retaining an editable first responder. The focus engine then moves across letters, but
    /// Select is discarded and the bound query never changes. A real `TextField` gives tvOS one
    /// explicit input owner while retaining the system keyboard, dictation, and Remote app input.
    @ViewBuilder
    private var searchSurface: some View {
        #if os(tvOS)
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Image(systemName: "magnifyingglass")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.secondary)

                TextField("Movies, shows, music…", text: queryBinding)
                    .focused($searchFieldFocused)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .accessibilityIdentifier("tv.search.field")

                if showsClearSearchButton {
                    Button {
                        clearSearch()
                        searchFieldFocused = true
                    } label: {
                        Label("Clear search", systemImage: "xmark.circle.fill")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 28)
            .frame(width: 920, height: 70)
            .background(.thinMaterial, in: Capsule())
            .padding(.top, 28)
            .padding(.bottom, 12)

            searchResultsContent
        }
        .task {
            // Selecting the Search tab should immediately make the system keyboard usable.
            // Defer one run-loop turn so the tab transition has installed this field.
            await Task.yield()
            searchFieldFocused = true
        }
        #if DEBUG
        // TVUI-004 evidence: log binding-level transitions so a manual session shows
        // whether keyboard Selects ever reach the binding (query length only, never text).
        .onChange(of: queryText) { _, value in
            NSLog("%@", "TVSearchEvidence: query length -> \(value.count)")
        }
        .onChange(of: searchFieldFocused) { _, focused in
            NSLog("%@", "TVSearchEvidence: field focused -> \(focused)")
        }
        #endif
        #else
        Group {
            if externalQuery == nil {
                searchResultsContent
                    .searchable(text: queryBinding, prompt: "Movies, shows, music…")
                    .searchFocused($searchFieldFocused)
            } else {
                searchResultsContent
            }
        }
        #endif
    }

    private var searchResultsContent: some View {
        ScrollView {
            switch loadState {
            case .idle:
                ContentUnavailableView("Search your libraries",
                                       systemImage: "magnifyingglass",
                                       description: Text("Find movies, shows, music, and more."))
                .frame(maxWidth: .infinity, minHeight: 300)
            case .loading:
                ProgressView("Searching…")
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: 360)
            case .failed(let message):
                ContentUnavailableView("Search failed",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(message))
                .frame(maxWidth: .infinity, minHeight: 300)
            case .loaded:
                if results.presentationGroups.isEmpty {
                    ContentUnavailableView.search(text: queryText)
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    LazyVStack(alignment: .leading, spacing: DS.Space.xxxl) {
                        ForEach(results.presentationGroups) { group in
                            SearchLibrarySection(group: group,
                                                 query: queryText,
                                                 backend: appModel.activeBackend,
                                                 sessionIdentity: appModel.activeBrowseSessionKey)
                        }
                    }
                    .padding(.vertical, DS.Space.xl)
                }
            }
        }
    }

    private var queryBinding: Binding<String> { externalQuery ?? $internalQuery }
    private var queryText: String { queryBinding.wrappedValue }

    private var searchTaskID: String {
        "\(appModel.activeBrowseSessionKey):\(queryText)"
    }

    private var showsClearSearchButton: Bool {
        !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loadState != .idle
    }

    private var clearSearchToolbarButton: some View {
        Button("Clear") { clearSearch() }
            .accessibilityLabel("Clear Search")
    }

    private func clearSearch() {
        queryBinding.wrappedValue = ""
        results = .empty
        loadedQuery = nil
        loadState = .idle
        searchFieldFocused = false
        dismissSearch()
        onClearSearch?()
    }

    private var currentSearchAuthorityKey: String {
        let currentQuery = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(appModel.activeBrowseSessionKey):\(currentQuery)"
    }

    private func runSearch() async {
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = .empty
            loadState = .idle
            return
        }
        // `.task(id:)` re-fires on pop-back from a result with the query unchanged;
        // re-running then would flash the spinner and dump the scroll position.
        let searchKey = "\(appModel.activeBrowseSessionKey):\(trimmed)"
        if searchKey == loadedQuery, case .loaded = loadState { return }
        // Light debounce so we don't fire a request per keystroke.
        try? await Task.sleep(for: .milliseconds(300))
        guard SearchRequestAuthority.accepts(capturedKey: searchKey,
                                             currentKey: currentSearchAuthorityKey,
                                             isCancelled: Task.isCancelled) else { return }

        if appModel.activeBackend == .jellyfin {
            loadState = .loading
            do {
                let searchResults = try await JellyfinBrowseService(appModel: appModel)
                    .searchResults(query: trimmed)
                if Task.isCancelled { return }
                results = searchResults
                loadedQuery = searchKey
                loadState = .loaded
            } catch {
                if Task.isCancelled { return }
                loadState = .failed(friendlyMessage(error))
            }
            return
        }

        if appModel.activeBackend == .emby {
            loadState = .loading
            do {
                let searchResults = try await EmbyBrowseService(appModel: appModel)
                    .searchResults(query: trimmed)
                if Task.isCancelled { return }
                results = searchResults
                loadedQuery = searchKey
                loadState = .loaded
            } catch {
                if Task.isCancelled { return }
                loadState = .failed(friendlyMessage(error))
            }
            return
        }

        guard let service = try? PlexBrowseService(appModel: appModel) else {
            loadState = .failed("No server selected.")
            return
        }
        loadState = .loading
        do {
            let snapshot = try await service.searchWithLibraries(query: trimmed)
            guard SearchRequestAuthority.accepts(capturedKey: searchKey,
                                                 currentKey: currentSearchAuthorityKey,
                                                 isCancelled: Task.isCancelled) else { return }
            results = .plexNativeHubs(snapshot.hubs, sections: snapshot.libraries)
            loadedQuery = searchKey
            loadState = .loaded
        } catch {
            guard SearchRequestAuthority.accepts(capturedKey: searchKey,
                                                 currentKey: currentSearchAuthorityKey,
                                                 isCancelled: Task.isCancelled) else { return }
            loadState = .failed(friendlyMessage(error))
        }
    }
}

enum SearchRequestAuthority {
    static func accepts(capturedKey: String, currentKey: String, isCancelled: Bool) -> Bool {
        !isCancelled && capturedKey == currentKey
    }
}

/// Navigation identity for a music result includes its source library. A bare
/// `MediaItem` loses this context and makes Plex artist pages fall back to the
/// under-listing `/children` endpoint.
private struct SearchMusicDestination: Hashable {
    let item: MediaItem
    let libraryID: String?
}

/// One source-library section containing one or more type/native result hubs.
private struct SearchLibrarySection: View {
    let group: SearchPresentationGroup
    let query: String
    let backend: MediaBackendKind
    let sessionIdentity: String

    @Environment(\.labstreamCompactWidth) private var compactWidth

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            Text(group.title)
                .font(compactWidth ? .title2.bold() : .title.bold())
                .padding(.horizontal, DS.Scroll.railHorizontalMargin(compact: compactWidth))

            ForEach(group.sections) { section in
                switch section.kind {
                case .artists, .albums, .playlists:
                    SearchMusicRail(section: section, libraryID: group.libraryID)
                case .songs:
                    SearchSongsSection(tracks: section.items)
                case .standard:
                    SearchHubSection(section: section,
                                     destination: destination(for: section))
                }
            }
        }
    }

    /// MediaBrowser (Jellyfin/Emby) search hubs get a "View All" paging destination
    /// scoped to this library; Plex and music hubs don't (music routes through
    /// `SearchMusicRail`, and only mediaBrowser search supports the paged query).
    private func destination(for section: SearchPresentationSection) -> RailViewAllDestination? {
        guard backend.isMediaBrowser,
              let libraryID = group.libraryID,
              let itemTypes = mediaBrowserItemTypes(for: section) else { return nil }
        return RailViewAllDestination(title: section.title, backend: backend,
                                      sessionIdentity: sessionIdentity,
                                      query: .mediaBrowserSearch(text: query,
                                                                 parentID: libraryID,
                                                                 itemTypes: itemTypes))
    }

    private func mediaBrowserItemTypes(for section: SearchPresentationSection) -> String? {
        switch section.items.first?.kind {
        case .movie: return "Movie"
        case .show: return "Series"
        case .season: return "Season"
        case .episode: return "Episode"
        case .other("video"): return "Video"
        default: return nil
        }
    }
}

/// One titled section of search results (a hub) rendered as a horizontal rail.
private struct SearchHubSection: View {
    let section: SearchPresentationSection
    let destination: RailViewAllDestination?

    @Environment(\.labstreamCompactWidth) private var compactWidth

    var body: some View {
        VStack(alignment: .leading, spacing: compactWidth ? DS.Space.sm : DS.Space.lg) {
            RailSectionHeader(title: section.title, destination: destination)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: compactWidth ? DS.Space.md : DS.Space.xl) {
                    ForEach(section.items) { item in
                        NavigationLink(value: item) {
                            RailMediaCell(item: item)
                        }
                        .cardLink()
                        .videoCardContextMenu(for: item)
                    }

                    #if os(tvOS)
                    if let destination {
                        RailViewAllCard(title: section.title,
                                        destination: destination,
                                        width: viewAllCardSize.width,
                                        height: viewAllCardSize.height)
                    }
                    #endif
                }
                .padding(.vertical, DS.Space.sm)
            }
            // contentMargins, not .padding on the lazy content — see the hit-region
            // gotcha in docs/DEVELOPMENT.md (padding shifts gaze/hit shapes left).
            .mediaRailScrollStyle(horizontalMargin: DS.Scroll.railHorizontalMargin(compact: compactWidth))
            #if os(tvOS)
            // Declared focus row (see HubRail): whole-rail target for vertical moves.
            .focusSection()
            #endif
        }
    }

    #if os(tvOS)
    /// Match the trailing View All card to this hub's artwork frame: 16:9 for episode
    /// hubs (the 360-pt tvOS episode still width in `HomeRailCellMetrics`), else the
    /// canonical 2:3 rail poster.
    private var viewAllCardSize: CGSize {
        if section.items.first?.kind == .episode {
            return CGSize(width: 360, height: (360 * 9.0 / 16.0).rounded())
        }
        let width = DS.Poster.railWidth(compact: false)
        return CGSize(width: width, height: DS.Poster.height(for: width))
    }
    #endif
}

/// Artist/album/playlist rail that carries the source library into the destination.
private struct SearchMusicRail: View {
    let section: SearchPresentationSection
    let libraryID: String?

    @Environment(\.labstreamCompactWidth) private var compactWidth

    var body: some View {
        VStack(alignment: .leading, spacing: compactWidth ? DS.Space.sm : DS.Space.lg) {
            Text(section.title)
                .font(compactWidth ? .title3.bold() : .title2.bold())
                .padding(.horizontal, DS.Scroll.railHorizontalMargin(compact: compactWidth))

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: compactWidth ? DS.Space.md : DS.Space.xl) {
                    ForEach(section.items) { item in
                        NavigationLink(value: SearchMusicDestination(item: item,
                                                                     libraryID: libraryID)) {
                            RailMediaCell(item: item)
                        }
                        .cardLink()
                    }
                }
                .padding(.vertical, DS.Space.sm)
            }
            .mediaRailScrollStyle(horizontalMargin: DS.Scroll.railHorizontalMargin(compact: compactWidth))
            #if os(tvOS)
            // Declared focus row (see HubRail): whole-rail target for vertical moves.
            .focusSection()
            #endif
        }
    }
}

// MARK: - Songs facet

/// How many song rows show before the "Show all" expander.
private let songsCollapsedCount = 5
/// Queue cap when a song is tapped (matches the rail-replay pattern).
private let songsQueueCap = 20

/// Vertical list of track results on a material card. Tapping a row PLAYS it with
/// the rest of the song results queued behind it — tracks never navigate. Search
/// hub rows are skinny (no Media/Part), so a tap re-fetches full metadata for the
/// queue in one comma-keyed request first (the `MusicTrackRail.play` pattern).
private struct SearchSongsSection: View {
    let tracks: [MediaItem]

    @Environment(AppModel.self) private var appModel
    @Environment(MusicPlayerController.self) private var player
    @Environment(\.labstreamCompactWidth) private var compactWidth

    @State private var showAll = false
    @State private var isStarting = false
    @State private var playError: String?

    private var visibleTracks: [MediaItem] {
        showAll ? tracks : Array(tracks.prefix(songsCollapsedCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Text("Songs")
                .font(compactWidth ? .title3.bold() : .title2.bold())
                .padding(.horizontal, DS.Scroll.railHorizontalMargin(compact: compactWidth))

            VStack(spacing: 0) {
                ForEach(Array(visibleTracks.enumerated()), id: \.element.id) { index, track in
                    Button {
                        Task { await play(from: track) }
                    } label: {
                        SearchTrackRow(track: track,
                                       isCurrent: player.current?.ratingKey == track.ratingKey)
                    }
                    .cardLink(cornerRadius: DS.Radius.chip)
                    .disabled(isStarting)
                    // Queue actions (#17 Phase 4). Search rows are skinny (no
                    // Media/Part), so each action re-fetches full metadata first.
                    .contextMenu {
                        Button {
                            Task { await enqueue(track, .playNext) }
                        } label: {
                            Label("Play Next",
                                  systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                        Button {
                            Task { await enqueue(track, .addToQueue) }
                        } label: {
                            Label("Add to Queue",
                                  systemImage: "text.line.last.and.arrowtriangle.forward")
                        }
                    }

                    if index < visibleTracks.count - 1 {
                        Divider().padding(.leading, DS.Space.xxl + DS.Space.lg)
                    }
                }

                if tracks.count > songsCollapsedCount {
                    Divider().padding(.leading, DS.Space.xxl + DS.Space.lg)
                    Button {
                        withAnimation { showAll.toggle() }
                    } label: {
                        Label(showAll ? "Show fewer" : "Show all \(tracks.count) songs",
                              systemImage: showAll ? "chevron.up" : "chevron.down")
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, DS.Space.lg)
                            .padding(.vertical, DS.Space.md)
                            .contentShape(Rectangle())
                            .padding(.horizontal, DS.Space.sm)
                    }
                    .cardLink(cornerRadius: DS.Radius.chip)
                }
            }
            .padding(.vertical, DS.Space.sm)
            .background(.regularMaterial,
                        in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .padding(.horizontal, DS.Scroll.railHorizontalMargin(compact: compactWidth))

            if let playError {
                Label(playError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, DS.Scroll.railHorizontalMargin(compact: compactWidth))
            }
        }
    }

    private enum QueueAction { case playNext, addToQueue }

    /// Context-menu queue action: hydrate the skinny search row into a full
    /// track (Media/Part) with one metadata request, then hand it to the player.
    private func enqueue(_ track: MediaItem, _ action: QueueAction) async {
        playError = nil

        // MediaBrowser rows are already playable by id — enqueue directly.
        guard appModel.activeBackend == .plex else {
            switch action {
            case .playNext: player.playNext([track])
            case .addToQueue: player.addToQueue([track])
            }
            return
        }

        // Plex: hydrate the skinny search row into a full track (Media/Part) first.
        guard let service = try? PlexBrowseService(appModel: appModel) else { return }
        do {
            guard let full = try await service.metadataItems(ratingKeys: track.ratingKey)
                .first(where: { $0.kind == .track }) else {
                playError = "Couldn’t load that song."
                return
            }
            switch action {
            case .playNext: player.playNext([full])
            case .addToQueue: player.addToQueue([full])
            }
        } catch {
            playError = friendlyMessage(error)
        }
    }

    private func play(from tapped: MediaItem) async {
        isStarting = true
        playError = nil
        defer { isStarting = false }

        // MediaBrowser audio rows are already playable by id (the universal stream
        // endpoint needs only the item id), so queue them directly.
        guard appModel.activeBackend == .plex else {
            let queue = Array(tracks.prefix(songsQueueCap))
            guard !queue.isEmpty else { return }
            let index = queue.firstIndex { $0.ratingKey == tapped.ratingKey } ?? 0
            player.play(tracks: queue, startingAt: index)
            return
        }

        // Plex search rows are skinny (no Media/Part) — re-fetch full metadata so the
        // tracks carry a playable part key.
        guard let service = try? PlexBrowseService(appModel: appModel) else { return }
        // Queue = the song results (capped), starting at the tapped one; if the
        // tapped track somehow falls outside the cap, play it alone.
        var keys = tracks.prefix(songsQueueCap).map(\.ratingKey)
        if !keys.contains(tapped.ratingKey) { keys = [tapped.ratingKey] }
        do {
            let full = try await service.metadataItems(ratingKeys: keys.joined(separator: ","))
                .filter { $0.kind == .track }
            guard !full.isEmpty else {
                playError = "Couldn’t load that song."
                return
            }
            let index = full.firstIndex { $0.ratingKey == tapped.ratingKey } ?? 0
            player.play(tracks: full, startingAt: index)
        } catch {
            playError = friendlyMessage(error)
        }
    }
}

/// One song result row: 44-pt album art, title, artist · album, duration, and a
/// play glyph (tinted waveform when it's the playing track). Sibling of
/// `AlbumDetailView`'s TrackRow with art instead of a track number.
private struct SearchTrackRow: View {
    let track: MediaItem
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: DS.Space.lg) {
            PosterImage(path: track.musicArtPath, width: 44, height: 44,
                        cornerRadius: DS.Radius.chip)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                // On a *track*, `grandparentTitle` is the artist and `parentTitle`
                // the album (artist → album → track).
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: DS.Space.md)

            if let duration = track.duration {
                Text(formatSongDuration(milliseconds: duration))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Image(systemName: isCurrent ? "waveform" : "play.fill")
                .font(.subheadline)
                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.sm)
        .contentShape(Rectangle())
        // Highlight comes from the wrapping button's `.cardLink(cornerRadius: .chip)` —
        // a custom ButtonStyle misroutes pinches to neighboring rows (DEVELOPMENT.md).
        // The outer inset keeps the row highlight clear of the card's corner curve.
        .padding(.horizontal, DS.Space.sm)
    }

    private var subtitle: String {
        [track.grandparentTitle, track.parentTitle]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// Format a song duration as `m:ss`, or `h:mm:ss` at an hour or more.
private func formatSongDuration(milliseconds: Int) -> String {
    let total = milliseconds / 1000
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
        : String(format: "%d:%02d", minutes, seconds)
}
