import SwiftUI
import PMSKit

/// An artist's page, Plexamp-style: header (portrait + name + bio) above shelves in
/// Plexamp's order — Popular tracks, Albums, the PMS-categorized release shelves
/// (Singles & EPs / Soundtracks / Compilations / Live / …), Appears On, and Similar
/// Artists.
///
/// Sourcing (all proven against a live PMS — see MUSIC-DESIGN §6):
/// - Own discography: `…/all?type=9&artist.id={rk}` — NOT `/children`, which
///   under-lists (returned size=0 for an artist owning two albums).
/// - Categorized shelves + Similar Artists: `/library/metadata/{rk}/related` hubs
///   (`artist.albums.singles` "Singles & EPs", `.compilation`, `artist.similar`, …).
/// - Appears On: `…/all?type=9&track.originalTitle={name}` — compilation tracks
///   carry the performing artist as TEXT, unlinked to the artist node; exact-match
///   only ("Artist feat. X" credits are missed — PMS has no contains operator).
/// - Popular: plexapi's `popularTracks` query (ratingCount:desc, compilations/live
///   excluded); rows come back with Media/Part, so they play directly.
struct ArtistDetailView: View {
    let artist: MediaItem
    /// Music section the artist was browsed from; nil → children fallback
    /// (cross-section search results), which renders a single Albums shelf.
    var sectionKey: String? = nil

    @Environment(AppModel.self) private var appModel
    @Environment(MusicPlayerController.self) private var player

    @State private var popular: [MediaItem] = []
    /// Own albums not already on a categorized shelf (the LPs, typically).
    @State private var albums: [MediaItem] = []
    /// PMS-categorized release shelves (Singles & EPs / Compilations / …), server order.
    @State private var categorized: [Hub] = []
    @State private var appearsOn: [MediaItem] = []
    @State private var similar: [MediaItem] = []
    @State private var loadState: HomeView.LoadState = .idle
    /// Play/Shuffle Artist in flight (the allLeaves fetch) — disables both buttons.
    @State private var isStartingPlayback = false
    @State private var playError: String?

    /// Header portrait size — larger than a grid cell, smaller than an album hero.
    private let portraitSize: CGFloat = 160

    private var isEmpty: Bool {
        popular.isEmpty && albums.isEmpty && categorized.isEmpty
            && appearsOn.isEmpty && similar.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xxl) {
                header

                switch loadState {
                case .idle, .loading:
                    shelfSkeleton
                case .failed(let message):
                    ContentUnavailableView("Couldn’t load \(artist.title)",
                                           systemImage: "exclamationmark.triangle",
                                           description: Text(message))
                        .frame(maxWidth: .infinity, minHeight: 360)
                case .loaded:
                    if isEmpty {
                        ContentUnavailableView("No albums",
                                               systemImage: "music.note",
                                               description: Text("Nothing to show for \(artist.title)."))
                            .frame(maxWidth: .infinity, minHeight: 360)
                    } else {
                        shelves
                    }
                }
            }
            .padding(.vertical, DS.Space.xl)
        }
        .navigationTitle(artist.title)
        .task { await load() }
    }

    /// Portrait + name + short bio.
    private var header: some View {
        HStack(alignment: .top, spacing: DS.Space.xl) {
            PosterImage(path: artist.thumb, width: portraitSize, height: portraitSize,
                        cornerRadius: DS.Radius.poster)

            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Text(artist.title)
                    .font(.largeTitle.bold())
                if let summary = artist.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                // Play/Shuffle the whole discography via `allLeaves` (MUSIC-DESIGN
                // §3.5) — same button treatment as the album header. Radio is v2
                // (Pass-gated, probe-only — §6).
                HStack(spacing: DS.Space.lg) {
                    Button {
                        Task { await playDiscography(shuffled: false) }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.title3.weight(.semibold))
                            .padding(.horizontal, DS.Space.md)
                            .padding(.vertical, DS.Space.xs)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        Task { await playDiscography(shuffled: true) }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .font(.title3)
                    }
                    .buttonStyle(.bordered)
                }
                .disabled(isStartingPlayback)
                .padding(.top, DS.Space.md)

                if let playError {
                    Label(playError, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.yellow)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.xxl)
    }

    /// Fetch every track under the artist in one flat list and play it (in album
    /// order, or shuffled). One request, zero controller changes.
    private func playDiscography(shuffled: Bool) async {
        guard let server = appModel.serverBaseURL, let token = appModel.serverToken else { return }
        isStartingPlayback = true
        playError = nil
        defer { isStartingPlayback = false }
        let req = MusicRequest.allLeaves(server: server, token: token,
                                         identity: appModel.identity,
                                         ratingKey: artist.ratingKey)
        do {
            let resp = try await appModel.client.send(req, as: MetadataResponse.self)
            let tracks = resp.mediaContainer.metadata.filter { $0.kind == .track }
            guard !tracks.isEmpty else {
                playError = "No tracks to play."
                return
            }
            if shuffled {
                player.playAlbumShuffled(tracks: tracks)
            } else {
                player.play(tracks: tracks, startingAt: 0)
            }
        } catch {
            playError = friendlyMessage(error)
        }
    }

    @ViewBuilder
    private var shelves: some View {
        if !popular.isEmpty { popularList }
        if !albums.isEmpty { MusicRail(title: "Albums", items: albums) }
        ForEach(categorized) { hub in
            MusicRail(title: hub.title, items: hub.metadata)
        }
        if !appearsOn.isEmpty { MusicRail(title: "Appears On", items: appearsOn) }
        if !similar.isEmpty { MusicRail(title: "Similar Artists", items: similar) }
    }

    /// Top tracks on a material card, ranked; tap plays the popular list from there.
    private var popularList: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Text("Popular")
                .font(.title2.bold())

            VStack(spacing: 0) {
                ForEach(Array(popular.enumerated()), id: \.element.id) { index, track in
                    Button {
                        player.play(tracks: popular, startingAt: index)
                    } label: {
                        PopularTrackRow(rank: index + 1, track: track,
                                        isCurrent: player.current?.ratingKey == track.ratingKey)
                    }
                    .cardLink(cornerRadius: DS.Radius.chip)
                    // Queue actions (#17 Phase 4); §3.6 contextMenu-on-row-chrome caveat.
                    .contextMenu { TrackQueueMenu(track: track, player: player) }

                    if index < popular.count - 1 {
                        Divider().padding(.leading, DS.Space.xxl + DS.Space.lg)
                    }
                }
            }
            .padding(.vertical, DS.Space.sm)
            .background(.regularMaterial,
                        in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        }
        .padding(.horizontal, DS.Space.xxl)
    }

    /// Shimmering shelf placeholders while everything loads.
    private var shelfSkeleton: some View {
        HStack(spacing: DS.Space.xl) {
            ForEach(0..<6, id: \.self) { _ in
                RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous)
                    .fill(.regularMaterial)
                    .frame(width: MusicArt.railSize, height: MusicArt.railSize)
                    .overlay { ShimmerView() }
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous))
            }
        }
        .padding(.horizontal, DS.Space.xxl)
    }

    private func load() async {
        // `.task` re-fires when popping back from a pushed album; reloading then
        // resets the scroll position the user is returning to. Load once.
        if case .loaded = loadState { return }
        guard let server = appModel.serverBaseURL, let token = appModel.serverToken else {
            loadState = .failed("No server selected.")
            return
        }
        loadState = .loading
        guard let sectionKey else {
            await loadViaChildren(server: server, token: token)
            return
        }
        let identity = appModel.identity

        // Discography is the primary request (drives the failure state); the other
        // shelves are best-effort and degrade to absent.
        async let relatedResp = try? appModel.client.send(
            MusicRequest.relatedHubs(server: server, token: token, identity: identity,
                                     ratingKey: artist.ratingKey),
            as: HubsResponse.self)
        async let appearsResp = try? appModel.client.send(
            MusicRequest.appearsOnAlbums(server: server, token: token, identity: identity,
                                         sectionKey: sectionKey, artistTitle: artist.title),
            as: MetadataResponse.self)
        async let popularResp = try? appModel.client.send(
            MusicRequest.popularTracks(server: server, token: token, identity: identity,
                                       sectionKey: sectionKey,
                                       artistRatingKey: artist.ratingKey),
            as: MetadataResponse.self)

        let own: [MediaItem]
        do {
            let resp = try await appModel.client.send(
                MusicRequest.artistAlbums(server: server, token: token, identity: identity,
                                          sectionKey: sectionKey,
                                          artistRatingKey: artist.ratingKey),
                as: MetadataResponse.self)
            own = resp.mediaContainer.metadata
        } catch {
            loadState = .failed(friendlyMessage(error))
            return
        }

        let hubs = (await relatedResp)?.mediaContainer.hub ?? []
        categorized = hubs.compactMap { hub in
            guard (hub.hubIdentifier ?? "").hasPrefix("artist.albums.") else { return nil }
            let items = hub.metadata.filter { $0.kind == .album }
            guard !items.isEmpty else { return nil }
            return Hub(hubKey: hub.hubKey, key: hub.key, title: hub.title,
                       type: hub.type, hubIdentifier: hub.hubIdentifier,
                       size: items.count, metadata: items)
        }
        similar = hubs.first { ($0.hubIdentifier ?? "").hasPrefix("artist.similar") }?
            .metadata.filter { $0.kind == .artist } ?? []

        // "Albums" = own discography minus anything PMS already shelved (Singles &
        // EPs etc.); "Appears On" = track-credit albums minus the artist's own.
        let categorizedKeys = Set(categorized.flatMap(\.metadata).map(\.ratingKey))
        albums = own.filter { !categorizedKeys.contains($0.ratingKey) }
        let ownKeys = Set(own.map(\.ratingKey))
        appearsOn = ((await appearsResp)?.mediaContainer.metadata ?? [])
            .filter { $0.kind == .album && !ownKeys.contains($0.ratingKey) }
        popular = (await popularResp)?.mediaContainer.metadata.filter { $0.kind == .track } ?? []

        loadState = .loaded
    }

    /// No section key in hand: the legacy children walk, one flat Albums shelf.
    private func loadViaChildren(server: URL, token: String) async {
        let req = BrowseAPI.children(server: server, token: token,
                                     identity: appModel.identity, ratingKey: artist.ratingKey)
        do {
            let resp = try await appModel.client.send(req, as: MetadataResponse.self)
            albums = resp.mediaContainer.metadata.filter { $0.kind == .album }
            loadState = .loaded
        } catch {
            loadState = .failed(friendlyMessage(error))
        }
    }
}

/// One ranked popular-track row: rank (or a tinted waveform when playing), title,
/// and duration. Sibling of `AlbumDetailView`'s TrackRow, with rank instead of
/// track number and no per-row artist (it's always this artist's page).
private struct PopularTrackRow: View {
    let rank: Int
    let track: MediaItem
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: DS.Space.lg) {
            Group {
                if isCurrent {
                    Image(systemName: "waveform")
                        .foregroundStyle(.tint)
                } else {
                    Text(String(rank))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline.monospacedDigit())
            .frame(width: DS.Space.xxl, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                // On a track, `parentTitle` is the album.
                if let album = track.parentTitle, !album.isEmpty {
                    Text(album)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: DS.Space.md)

            if let duration = track.duration {
                Text(formatPopularDuration(milliseconds: duration))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.sm + 2)
        .contentShape(Rectangle())
        // Same treatment as the album track rows: highlight from the wrapping button's
        // `.cardLink(cornerRadius: .chip)`; custom styles misroute pinches (DEVELOPMENT.md).
        .padding(.horizontal, DS.Space.sm)
    }
}

/// Format a track duration as `m:ss`, or `h:mm:ss` at an hour or more.
private func formatPopularDuration(milliseconds: Int) -> String {
    let total = milliseconds / 1000
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
        : String(format: "%d:%02d", minutes, seconds)
}
