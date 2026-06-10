import SwiftUI
import PlexKit

/// Home tab: the server's hubs (`GET /hubs`) rendered as horizontal poster rails,
/// Swiftfin-style. Each rail is one `Hub`; tapping a poster opens `DetailView`.
struct HomeView: View {
    @Environment(AppModel.self) private var appModel

    @State private var hubs: [Hub] = []
    @State private var loadState: LoadState = .idle

    enum LoadState: Equatable {
        case idle, loading, loaded, failed(String)
    }

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
                if hubs.isEmpty {
                    ContentUnavailableView("Nothing here yet",
                                           systemImage: "house",
                                           description: Text("No hubs returned by the server."))
                    .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    LazyVStack(alignment: .leading, spacing: DS.Space.xxxl) {
                        // Hide music: drop music items from each hub and any hub left empty (#15).
                        ForEach(hubs.hidingMusic) { hub in
                            HubRail(hub: hub)
                        }
                    }
                    .padding(.vertical, DS.Space.xl)
                }
            }
        }
        .navigationTitle("Home")
        .navigationDestination(for: MediaItem.self) { item in
            DetailView(item: item)
        }
        // Re-run whenever the server URL resolves after discovery/rediscovery.
        .task(id: appModel.serverBaseURL) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let server = appModel.serverBaseURL, let token = appModel.serverToken else {
            loadState = .failed("No reachable Plex server selected.")
            return
        }
        loadState = .loading
        let req = BrowseAPI.hubs(server: server, token: token, identity: appModel.identity)
        do {
            let resp = try await appModel.client.send(req, as: HubsResponse.self)
            hubs = resp.mediaContainer.hub
            loadState = .loaded
        } catch {
            loadState = .failed(friendlyMessage(error))
        }
    }
}

/// One horizontal rail of posters for a hub.
private struct HubRail: View {
    let hub: Hub

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Text(hub.title)
                .font(.title2.bold())
                .padding(.horizontal, DS.Space.xxl)

            ScrollView(.horizontal) {
                LazyHStack(spacing: DS.Space.xl) {
                    ForEach(hub.metadata) { item in
                        NavigationLink(value: item) {
                            PosterCell(item: item)
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding(.horizontal, DS.Space.xxl)
                .padding(.vertical, DS.Space.sm)
            }
            .scrollClipDisabled() // let hover-lifted posters breathe past the rail edge
        }
    }
}

/// A poster + title cell used in rails and grids.
///
/// Visual polish: a fixed 2:3 poster, a continue-watching progress sliver when the
/// item has a resume point, and a visionOS hover lift. The title block reserves a
/// stable height so rows of cells with 1- vs 2-line titles still align cleanly.
struct PosterCell: View {
    let item: MediaItem
    var width: CGFloat = DS.Poster.railWidth

    private var height: CGFloat { DS.Poster.height(for: width) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            PosterImage(path: item.thumb, width: width, height: height)
                .overlay(alignment: .bottom) { progressSliver }
                .gazeHighlight()
                .posterHover()

            VStack(alignment: .leading, spacing: 2) {
                // Episodes read like Plex/Emby: show name on top, then
                // "S{parentIndex}E{index} · {title}". Everything else keeps the
                // title + year treatment.
                if item.kind == .episode {
                    Text(item.grandparentTitle ?? item.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(episodeSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(item.title)
                        .font(.headline)
                        .lineLimit(1)
                    if let year = item.year {
                        Text(String(year))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(width: width, alignment: .leading)
        // NOTE (#20): the wrapping NavigationLink uses `.buttonStyle(.card)` (no automatic
        // hover effect); the gaze highlight is the explicit `.gazeHighlight()` on the
        // poster image above.
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
    @ViewBuilder
    private var progressSliver: some View {
        if let offset = item.viewOffset, offset > 0,
           let duration = item.duration, duration > 0 {
            let fraction = min(1, max(0, Double(offset) / Double(duration)))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.black.opacity(0.45))
                    Capsule().fill(.tint)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 4)
            .padding(.horizontal, DS.Space.sm)
            .padding(.bottom, DS.Space.sm)
        }
    }
}

/// Placeholder rails shown while Home loads — a couple of titled rows of shimmering
/// poster blanks so the screen has structure (and no jarring spinner-to-grid jump).
struct SkeletonRails: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxxl) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                        .fill(.regularMaterial)
                        .frame(width: 200, height: 26)
                        .overlay { ShimmerView() }
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                        .padding(.horizontal, DS.Space.xxl)

                    ScrollView(.horizontal) {
                        HStack(spacing: DS.Space.xl) {
                            ForEach(0..<5, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous)
                                    .fill(.regularMaterial)
                                    .frame(width: DS.Poster.railWidth,
                                           height: DS.Poster.height(for: DS.Poster.railWidth))
                                    .overlay { ShimmerView() }
                                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous))
                            }
                        }
                        .padding(.horizontal, DS.Space.xxl)
                    }
                    .scrollDisabled(true)
                }
            }
        }
        .padding(.vertical, DS.Space.xl)
    }
}

/// Map a thrown error (often `PlexError`) to a short user-facing string.
func friendlyMessage(_ error: Error) -> String {
    if let plex = error as? PlexError {
        switch plex {
        case .unauthorized: return "Your session expired. Please sign in again."
        case .serverUnreachable: return "Couldn’t reach the server."
        case .http(let code): return "Server error (HTTP \(code))."
        case .decoding: return "Unexpected response from the server."
        }
    }
    return error.localizedDescription
}

// MARK: - Music hiding (#15)

extension Array where Element == Hub {
    /// Hides music until a dedicated Plexamp-style experience exists (#15): drops music
    /// items (artist/album/track) from each hub and removes any hub left empty (which also
    /// elides wholly-music hubs). Detection comes from `MediaItem.isMusic` so there's a
    /// single source of truth. Easy to remove later to re-enable music.
    var hidingMusic: [Hub] {
        compactMap { hub in
            let kept = hub.metadata.filter { !$0.isMusic }
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
