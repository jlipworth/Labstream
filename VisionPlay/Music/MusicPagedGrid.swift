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

    private let columns = [GridItem(.adaptive(minimum: MusicArt.gridMin, maximum: MusicArt.gridMax),
                                    spacing: DS.Space.xl)]

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
                Spacer()
                sortMenu
            }
            .padding(.horizontal, DS.Space.xxl)

            LazyVGrid(columns: columns, spacing: DS.Space.xxl) {
                // Position-keyed: a slot's identity is its place in the listing; its content
                // arrives when the page loads (same contract as the video grid's slots).
                ForEach(Array(paging.slots.enumerated()), id: \.offset) { index, slot in
                    if let item = slot {
                        NavigationLink(value: item) {
                            SquareArtCell(item: item, size: MusicArt.gridMin, subtitle: subtitle(item))
                        }
                        .cardLink()
                        .id(index)
                    } else {
                        MusicPlaceholderCell()
                            .id(index)
                            .onAppear { prefetchPage(containing: index) }
                    }
                }
            }
            .padding(.horizontal, DS.Space.xxl)
        }
        .padding(.vertical, DS.Space.xl)
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
        .buttonStyle(.bordered)
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

/// Shimmer stand-in matching a loaded music cell's footprint (square art + one text line),
/// shown for a not-yet-fetched slot. The square counterpart of `LibraryPlaceholderPoster`.
private struct MusicPlaceholderCell: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous)
                .fill(.regularMaterial)
                .frame(width: MusicArt.gridMin, height: MusicArt.gridMin)
                .overlay { ShimmerView() }
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous))
            RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                .fill(.regularMaterial)
                .frame(width: MusicArt.gridMin * 0.6, height: 16)
        }
        .frame(width: MusicArt.gridMin, alignment: .leading)
    }
}
