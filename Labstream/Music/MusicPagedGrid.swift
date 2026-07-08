import SwiftUI
import PMSKit

/// The shared Artists/Albums grid for the Music tab across all three backends (#111).
///
/// Reuses the SAME `LibraryPagingModel` + `LibraryAlphabetRail` as the movies/TV
/// `LibraryGridView`, so the music grids get random-access paging, the A–Z jump rail, and a
/// sort menu for free. It renders `SquareArtCell`s (square albums with an "Artist · year"
/// subtitle, circular artists) and navigates with `NavigationLink(value:)` so the ancestor's
/// `musicDestination(for:sectionKey:)` routes the tap. Changing sort rebuilds the paging
/// source (new identity), which reloads the grid from the top.
struct MusicPagedGrid: View {
    let libraryID: String
    let libraryTitle: String
    let kind: MusicGridKind

    @Environment(AppModel.self) private var appModel

    @State private var paging = LibraryPagingModel()
    @State private var sort: MusicBrowseSort

    init(libraryID: String, libraryTitle: String, kind: MusicGridKind) {
        self.libraryID = libraryID
        self.libraryTitle = libraryTitle
        self.kind = kind
        // Albums lead newest-first, artists alphabetically — matching the prior grids.
        _sort = State(initialValue: kind == .albums ? .recentlyAdded : .name)
    }

    private var sortCases: [MusicBrowseSort] {
        kind == .albums ? MusicBrowseSort.albumCases : MusicBrowseSort.artistCases
    }

    @Environment(\.labstreamCompactWidth) private var compactWidth

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: MusicArt.gridMin(compact: compactWidth),
                            maximum: MusicArt.gridMax(compact: compactWidth)),
                  spacing: MusicArt.gridGutter(compact: compactWidth))]
    }

    private var pagingSource: LibraryPagingSource {
        .music(kind: kind, libraryID: libraryID, libraryTitle: libraryTitle,
               sort: sort, appModel: appModel)
    }

    private var loadIdentity: String { pagingSource.identity }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                switch paging.loadState {
                case .idle, .loading:
                    MusicSkeleton()
                case .failed(let message):
                    ContentUnavailableView("Couldn’t load \(libraryTitle)",
                                           systemImage: "exclamationmark.triangle",
                                           description: Text(message))
                        .frame(maxWidth: .infinity, minHeight: 360)
                case .loaded:
                    if paging.slots.isEmpty {
                        ContentUnavailableView(kind == .albums ? "No Albums" : "No Artists",
                                               systemImage: "music.note",
                                               description: Text("Nothing to show in \(libraryTitle)."))
                            .frame(maxWidth: .infinity, minHeight: 360)
                    } else {
                        loadedGrid
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
        .task(id: loadIdentity) { await load() }
        .refreshable { await load(force: true) }
    }

    private var loadedGrid: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            HStack {
                sortMenu
                Spacer()
            }
            .padding(.horizontal, DS.pagePadding(compact: compactWidth))

            LazyVGrid(columns: columns, spacing: MusicArt.gridRowSpacing(compact: compactWidth)) {
                // Position-keyed: a slot's identity is its place in the listing; its content
                // arrives when the page loads (same contract as the video grid's slots).
                ForEach(Array(paging.slots.enumerated()), id: \.offset) { index, slot in
                    MusicPagedGridSlot(index: index,
                                       item: slot,
                                       subtitle: slot.flatMap(subtitle(_:)),
                                       onPlaceholderAppear: { prefetchPage(containing: index) })
                    .id(index)
                }
            }
            .padding(.horizontal, DS.pagePadding(compact: compactWidth))
            // On compact the 16-pt page padding leaves the last column under the
            // A–Z section index, which intercepts taps while scrubbing — reserve
            // the rail's narrow strip instead of overlapping (same fix as the
            // video LibraryGridView). macOS also reserves the floating rail so the
            // denser desktop music grid doesn't tuck its final album/artist card
            // underneath the index.
            .padding(.trailing, alphabetRailGridReservation)
        }
        .padding(.vertical, MusicArt.gridVerticalPadding)
    }

    private var alphabetRailGridReservation: CGFloat {
        guard paging.alphabetBuckets.count > 1 else { return 0 }
        #if os(macOS)
        return MusicArt.macAlphabetRailGridReservation
        #else
        return compactWidth ? LibraryAlphabetRail.compactGridTrailingReservation : 0
        #endif
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(sortCases) { Text($0.label).tag($0) }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
                .font(.callout)
        }
        .labstreamGlassButtonStyle()
    }

    /// "Artist · 1973" on albums, dropping whichever half is missing; nil for artists.
    private func subtitle(_ item: MediaItem) -> String? {
        guard kind == .albums else { return nil }
        let parts = [item.parentTitle, item.year.map(String.init)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func load(force: Bool = false) async {
        // `.task(id:)` re-fires on pop-back and on a sort change; the model loads once per
        // source identity (which folds in the sort), so a real sort change reloads while a
        // pop-back is a no-op that preserves scroll position.
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

private struct MusicPagedGridSlot: View {
    let index: Int
    let item: MediaItem?
    let subtitle: String?
    let onPlaceholderAppear: () -> Void

    var body: some View {
        Group {
            if let item {
                NavigationLink(value: item) {
                    SquareArtCell(item: item, subtitle: subtitle)
                }
                .cardLink()
                // Keep the outer numeric `.id(index)` as the scroll target, but force the
                // inner subtree to be replaced when a sparse slot flips from placeholder to
                // loaded content. Fast A-Z jumps can otherwise leave LazyVGrid reusing a
                // placeholder subtree even after the page fetch filled the slot.
                .id("loaded-\(item.ratingKey)")
            } else {
                MusicPlaceholderCell()
                    .id("placeholder-\(index)")
                    .onAppear(perform: onPlaceholderAppear)
            }
        }
    }
}

/// Shimmer stand-in matching a loaded music cell's footprint (square art + one text line),
/// shown for a not-yet-fetched slot. The square counterpart of `LibraryPlaceholderPoster`.
private struct MusicPlaceholderCell: View {
    @Environment(\.labstreamCompactWidth) private var compactWidth

    var body: some View {
        let side = MusicArt.gridMin(compact: compactWidth)
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous)
                .fill(.regularMaterial)
                .frame(width: side, height: side)
                .overlay { ShimmerView() }
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous))
            RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                .fill(.regularMaterial)
                .frame(width: side * 0.6, height: 16)
        }
        .frame(width: side, alignment: .leading)
    }
}
