import SwiftUI
import PMSKit

/// Item detail: artwork, rich metadata, and the primary actions — a real per-item
/// submenu modeled on the official Plex / Emby item pages.
///
/// Action area:
///   • Play / Resume — presents the custom `CustomPlayerView` (streams the chosen version).
///   • Download — opens `DownloadOptionsSheet` so the viewer picks a quality before the
///     optimize → background-download pipeline runs; when a local copy already exists it
///     becomes a "Play Offline" shortcut, and a live progress label shows mid-transfer.
///   • Mark Watched / Unwatched — drives Plex `/:/scrobble` · `/:/unscrobble` and updates
///     the local `viewCount` optimistically so the UI reacts instantly.
///   • Version — when the item ships multiple `Media` entries (e.g. a 4K and a 1080p
///     file) a menu lets the viewer pick which version to play/download.
///
/// On appear it fetches full metadata for the item (the list/hub payload is often
/// trimmed and lacks `Media`/`Part`/genres, which the player and this screen need); it
/// falls back to the passed-in item if the refresh fails.
struct DetailView: View {
    let item: MediaItem

    @Environment(AppModel.self) private var appModel
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(MusicPlayerController.self) private var musicPlayer

    @State private var detailed: MediaItem
    @State private var presentingPlayer = false
    @State private var playLocalURL: URL?
    @State private var remotePlayback: JellyfinRemotePlayback?
    @State private var showDownloadOptions = false
    @State private var playbackErrorMessage: String?
    @State private var isResolvingPlayback = false
    @AppStorage("maxVideoBitrateKbps") private var maxVideoBitrateKbps: Int = 8000

    /// The item currently being PLAYED in the cover. Starts as the detail item, but the
    /// Up Next autoplay (#15) swaps it to the next episode while keeping the cover up — the
    /// `.id` keyed on its `ratingKey` makes `CustomPlayerView` + its controller rebuild for the
    /// new episode. `nil` until the player is first presented.
    @State private var playingItem: MediaItem?

    /// Which `Media` version is selected for play/download. Index into `detailed.media`.
    /// Defaults to `0` (the primary version). Reset whenever a metadata refresh swaps the
    /// underlying item out from under us so we never index past the array.
    @State private var selectedMediaIndex = 0

    /// Optimistic local override of the server's watched state. `nil` means "use the
    /// value from `detailed`"; once the user toggles we hold their intent here so the row
    /// reflects it immediately, before/independent of the scrobble round-trip.
    @State private var watchedOverride: Bool?

    init(item: MediaItem) {
        self.item = item
        _detailed = State(initialValue: item)
    }

    /// An episode's show as a pushable container item (episode hierarchy:
    /// show = grandparent, season = parent).
    private var showItem: MediaItem? {
        guard let key = detailed.grandparentRatingKey,
              let title = detailed.grandparentTitle else { return nil }
        return MediaItem(ratingKey: key, title: title, type: "show",
                         thumb: detailed.grandparentThumb)
    }

    var body: some View {
        // Music never gets the video detail/player (#17 un-hide): any music item
        // that reaches DetailView re-routes into the music module. The old
        // silent `guard !detailed.isMusic` play-button guard is replaced by this
        // routing, so leafDetail below is video-only by construction.
        // (Video/photo playlists are not music — they keep the video path below.)
        if item.isMusic || item.isAudioPlaylist {
            musicRedirect
        }
        // Show/season are CONTAINERS: they carry no Media/Part and must be drilled into
        // (a series download/play of a container ratingKey makes PMS return HTTP 400).
        // Render a season/episode browser for those; the leaf detail (with Play/Download)
        // is reserved for movies and episodes — the items that actually own a Part.
        else if item.isContainer {
            ContainerBrowserView(container: item)
        } else {
            leafDetail
        }
    }

    /// Music routing for items that land here from generic surfaces (Home hubs,
    /// stale links): containers go to their music views; a TRACK opens its album
    /// (tracks never navigate to a detail page — the album page plays them).
    @ViewBuilder
    private var musicRedirect: some View {
        switch item.kind {
        case .artist, .album, .playlist:
            // Cross-section surface → no music sectionKey (artist view uses its
            // children fallback).
            musicDestination(for: item, sectionKey: nil)
        case .track:
            if let album = parentAlbumItem {
                AlbumDetailView(album: album)
            } else {
                ContentUnavailableView("Open from the Music tab",
                                       systemImage: "music.note",
                                       description: Text("This track has no album link to browse into."))
            }
        default:
            EmptyView()
        }
    }

    /// A track's parent album as a navigable item (same synthesis as
    /// NowPlayingView's go-to-album).
    private var parentAlbumItem: MediaItem? {
        guard item.kind == .track, let key = item.parentRatingKey else { return nil }
        return MediaItem(ratingKey: key, title: item.parentTitle ?? "Album",
                         type: "album", thumb: item.parentThumb)
    }

    /// The play/download detail for a LEAF item (movie or episode). Actions target this
    /// item's own ratingKey, which is guaranteed to own a Media/Part.
    private var leafDetail: some View {
        ScrollView {
            HStack(alignment: .top, spacing: DS.Space.xxxl) {
                PosterImage(path: detailed.thumb,
                            width: DS.Poster.detailWidth,
                            height: DS.Poster.height(for: DS.Poster.detailWidth),
                            cornerRadius: DS.Radius.card)
                    .shadow(color: .black.opacity(0.4), radius: 24, x: 0, y: 16)

                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    // For an episode, lead with the show name + "S{parentIndex}E{index}"
                    // so the header reads like Plex/Emby, then the episode title.
                    if detailed.kind == .episode {
                        VStack(alignment: .leading, spacing: DS.Space.xs) {
                            if let show = detailed.grandparentTitle, !show.isEmpty {
                                // Tappable like the music pages' artist links: pushes
                                // the show's season browser onto the same stack.
                                if let showItem {
                                    NavigationLink(value: showItem) {
                                        Text(show)
                                            .font(.title3.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, DS.Space.sm)
                                            .contentShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .hoverEffect(.highlight)
                                    .padding(.leading, -DS.Space.sm)
                                } else {
                                    Text(show)
                                        .font(.title3.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            HStack(spacing: DS.Space.sm) {
                                if let code = detailed.seasonEpisodeCode {
                                    Text(code)
                                        .font(.title3.weight(.bold))
                                        .foregroundStyle(.tint)
                                }
                                Text(detailed.title)
                                    .font(.largeTitle.bold())
                            }
                        }
                    } else {
                        Text(detailed.title)
                            .font(.largeTitle.bold())
                    }

                    if let tagline = detailed.tagline, !tagline.isEmpty {
                        Text(tagline)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .italic()
                    }

                    metadataRow

                    if let genres = detailed.genres, !genres.isEmpty {
                        Text(genres.map(\.tag).joined(separator: " · "))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    actionButtons

                    mediaInfoSummary

                    if let summary = detailed.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.body)
                            .foregroundStyle(.primary.opacity(0.9))
                            .lineSpacing(4)
                            .padding(.top, DS.Space.sm)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(DS.Space.xxxl)
        }
        .background(artBackdrop)
        .navigationTitle(detailed.title)
        .task { await refreshMetadata() }
        .fullScreenCover(isPresented: $presentingPlayer) {
            playerCover
        }
        .sheet(isPresented: $showDownloadOptions) {
            DownloadOptionsSheet(item: detailed, mediaIndex: selectedMediaIndex)
        }
    }

    // MARK: - Backdrop

    /// A heavily-blurred, dimmed wash of the item's `art` (or poster) bleeding behind
    /// the detail content — the cinematic "key art" treatment Plex/Apple TV use. It is
    /// purely decorative: a gradient scrim keeps text legible and it never intercepts
    /// touches. Falls back to nothing (the window's own material) when art is absent.
    @ViewBuilder
    private var artBackdrop: some View {
        if let art = detailed.art ?? detailed.thumb, !art.isEmpty {
            PosterImage(path: art, width: 900, height: 600, cornerRadius: 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .blur(radius: 60)
                .opacity(0.30)
                .overlay(
                    LinearGradient(colors: [.clear, .black.opacity(0.55)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    // MARK: - Metadata header

    /// Year · runtime · content-rating capsule · critic rating · watched badge.
    @ViewBuilder
    private var metadataRow: some View {
        HStack(spacing: 16) {
            if let year = detailed.year {
                Text(String(year))
            }
            if let mins = runtimeMinutes {
                Text("\(mins) min")
            }
            if let cr = detailed.contentRating, !cr.isEmpty {
                Text(cr)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, DS.Space.sm)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(.secondary, lineWidth: 1)
                    )
            }
            if let rating = detailed.rating, rating > 0 {
                Label(String(format: "%.1f", rating), systemImage: "star.fill")
                    .foregroundStyle(.yellow)
            }
            if isWatched {
                Label("Watched", systemImage: "checkmark.circle.fill")
            }
        }
        .font(.title3)
        .foregroundStyle(.secondary)
    }

    /// A tasteful, INFORMATIONAL summary of the selected version's tech specs plus a
    /// chapter/subtitle count when PMS exposes them. Deep chapter/subtitle CONTROL lives
    /// in the player — this is just a glance-able readout.
    @ViewBuilder
    private var mediaInfoSummary: some View {
        if let media = selectedMedia {
            HStack(spacing: DS.Space.sm) {
                ForEach(mediaSpecBadges(media), id: \.self) { spec in
                    SpecChip(text: spec, monospaced: true)
                }
                if let chapters = detailed.chapters, !chapters.isEmpty {
                    Label("\(chapters.count) chapters", systemImage: "list.bullet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, DS.Space.xs)
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionButtons: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            HStack(spacing: DS.Space.lg) {
                Button {
                    Task { await startPlayback() }
                } label: {
                    Group {
                        if isResolvingPlayback {
                            ProgressView()
                        } else {
                            Label(resumeLabel, systemImage: "play.fill")
                        }
                    }
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, DS.Space.md)
                    .padding(.vertical, DS.Space.xs)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isResolvingPlayback)

                downloadButton

                if supportsWatchedToggle {
                    markWatchedButton
                }
            }

            versionPicker

            if let playbackErrorMessage {
                Text(playbackErrorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    /// "Play Offline" when a local copy exists, otherwise a button that opens the
    /// `DownloadOptionsSheet` (quality picker) with a live progress label mid-transfer.
    @ViewBuilder
    private var downloadButton: some View {
        if let local = localURL {
            Button {
                musicPlayer.pauseForVideo()
                playLocalURL = local
                remotePlayback = nil
                playingItem = detailed
                presentingPlayer = true
            } label: {
                Label("Play Offline", systemImage: "arrow.down.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.bordered)
        } else {
            Button {
                showDownloadOptions = true
            } label: {
                Label(downloadLabel, systemImage: "arrow.down.circle")
                    .font(.title3)
            }
            .buttonStyle(.bordered)
            .disabled(isDownloading)
        }
    }

    /// Toggle that scrobbles / unscrobbles the item and flips the local watched state
    /// optimistically so the header updates instantly.
    @ViewBuilder
    private var markWatchedButton: some View {
        Button {
            Task { await toggleWatched() }
        } label: {
            Label(isWatched ? "Mark Unwatched" : "Mark Watched",
                  systemImage: isWatched ? "minus.circle" : "checkmark.circle")
                .font(.title3)
        }
        .buttonStyle(.bordered)
    }

    /// Version picker — only shown when the item ships more than one `Media` entry. Each
    /// row labels the version by resolution / codec / bitrate so the viewer can pick the
    /// 4K vs. the 1080p file, etc. The chosen index threads into both playback and the
    /// media-info summary.
    @ViewBuilder
    private var versionPicker: some View {
        if let media = detailed.media, media.count > 1 {
            Menu {
                ForEach(Array(media.enumerated()), id: \.element.id) { index, m in
                    Button {
                        selectedMediaIndex = index
                    } label: {
                        if index == selectedMediaIndex {
                            Label(versionLabel(m), systemImage: "checkmark")
                        } else {
                            Text(versionLabel(m))
                        }
                    }
                }
            } label: {
                Label("Version: \(versionLabel(media[safe: selectedMediaIndex] ?? media[0]))",
                      systemImage: "rectangle.stack.badge.play")
                    .font(.callout)
            }
            .menuStyle(.borderlessButton)
        }
    }

    @ViewBuilder
    private var playerCover: some View {
        // The item currently in the cover: starts as `detailed`, then swaps to the next
        // episode on Up Next autoplay (#15). Fall back to `detailed` defensively.
        let playing = playingItem ?? detailed
        if let local = playLocalURL {
            CustomPlayerView(localFile: local, item: playing,
                             onClose: { presentingPlayer = false })
                .ignoresSafeArea()
        } else if let remote = remotePlayback {
            CustomPlayerView(item: playing,
                             controllerFactory: {
                                 PlaybackController(remoteStreamURL: remote.url,
                                                    item: playing,
                                                    identity: appModel.identity,
                                                    client: appModel.client,
                                                    httpHeaders: remote.headers,
                                                    sourceMetadata: remote.sourceMetadata,
                                                    playMethod: remote.playMethod,
                                                    onStopRemoteSession: {
                                                        Task {
                                                            await JellyfinBrowseService(appModel: appModel)
                                                                .stopActiveEncoding(playSessionId: remote.playSessionId)
                                                        }
                                                    },
                                                    remoteStreamReopener: { request in
                                                        let result = try await JellyfinBrowseService(appModel: appModel)
                                                            .playbackOpen(item: playing,
                                                                          maxVideoBitrateKbps: request.bitrateKbps,
                                                                          resumeOffsetMs: request.offsetMs,
                                                                          audioStreamIndex: request.audioStreamIndex,
                                                                          subtitleStreamIndex: request.subtitleStreamIndex)
                                                        return RemoteStreamOpenResult(
                                                            url: result.url,
                                                            headers: result.requiredHTTPHeaders,
                                                            sourceMetadata: result.sourceMetadata,
                                                            playMethod: result.playMethod,
                                                            onStop: {
                                                                Task {
                                                                    await JellyfinBrowseService(appModel: appModel)
                                                                        .stopActiveEncoding(playSessionId: result.playSessionId)
                                                                }
                                                            })
                                                    },
                                                    maxVideoBitrateKbps: maxVideoBitrateKbps)
                             },
                             onClose: { presentingPlayer = false })
                .id(remote.id)
                .ignoresSafeArea()
        } else if let token = appModel.serverToken, let server = appModel.serverBaseURL {
            // The custom player owns its own chrome, including a top-leading Close affordance,
            // so a `.fullScreenCover` is always escapable (the old AVKit path had no system
            // Close button inside a cover on visionOS).
            Group {
                let mediaIndex = playing.ratingKey == detailed.ratingKey ? selectedMediaIndex : 0
                let machineIdentifier = appModel.selectedServer?.clientIdentifier
                let playNext: (MediaItem) -> Void = { next in
                    // Up Next advance: swap the presented item to the next episode. The `.id`
                    // keyed on ratingKey tears down the old controller and rebuilds the player
                    // for the new episode, keeping the cover up for a continuous experience.
                    playLocalURL = nil
                    playingItem = next
                }

                // The Plex resource clientIdentifier IS the server's machine identifier; the
                // play-queue API needs it to resolve the next episode for the Up Next card.
                CustomPlayerView(item: playing,
                                 controllerFactory: {
                                     PlaybackController(item: playing,
                                                        server: server,
                                                        token: token,
                                                        identity: appModel.identity,
                                                        client: appModel.client,
                                                        maxVideoBitrateKbps: maxVideoBitrateKbps,
                                                        mediaIndex: mediaIndex,
                                                        machineIdentifier: machineIdentifier)
                                 },
                                 onClose: { presentingPlayer = false },
                                 onRequestPlay: playNext)
            }
            // Rebuild the player + its PlaybackController cleanly whenever the playing
            // item changes (Up Next advance), so the outgoing controller is dismantled
            // (its `stop()` flushes a final timeline) and a fresh one starts the next.
            .id(playing.ratingKey)
            .ignoresSafeArea()
        } else {
            ContentUnavailableView("Can’t play",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text("No active server session."))
        }
    }

    // MARK: - Watched toggle

    /// Scrobble / unscrobble against the active backend, updating the local watched state
    /// optimistically.
    ///
    /// We flip `watchedOverride` first so the UI reacts immediately, then fire the
    /// request. On failure we roll the override back. NOTE: never logs the token — the
    /// builders carry it internally and we only ever inspect the `Bool` outcome here.
    private func toggleWatched() async {
        let wasWatched = isWatched
        // Optimistic flip.
        watchedOverride = !wasWatched

        do {
            switch appModel.activeBackend {
            case .plex:
                guard let server = appModel.serverBaseURL,
                      let token = appModel.serverToken else {
                    watchedOverride = wasWatched
                    return
                }
                let req = wasWatched
                    ? TimelineRequest.unscrobble(server: server, token: token,
                                                 identity: appModel.identity,
                                                 ratingKey: detailed.ratingKey)
                    : TimelineRequest.scrobble(server: server, token: token,
                                               identity: appModel.identity,
                                               ratingKey: detailed.ratingKey)
                _ = try await appModel.client.send(req)
            case .jellyfin:
                try await JellyfinBrowseService(appModel: appModel)
                    .setPlayed(itemId: detailed.ratingKey, played: !wasWatched)
            }
        } catch {
            // Roll back the optimistic flip; the server rejected the change.
            watchedOverride = wasWatched
        }
    }

    private func startPlayback() async {
        // Defense-in-depth (#15): music is filtered from browse, but never let a music item
        // launch the video player. Unreachable in normal flow.
        guard !detailed.isMusic else { return }
        playbackErrorMessage = nil
        musicPlayer.pauseForVideo()
        playLocalURL = nil
        playingItem = detailed
        switch appModel.activeBackend {
        case .plex:
            remotePlayback = nil
            presentingPlayer = true
        case .jellyfin:
            isResolvingPlayback = true
            do {
                let service = JellyfinBrowseService(appModel: appModel)
                let playbackItem = (try? await service.metadata(itemId: detailed.ratingKey)) ?? detailed
                playingItem = playbackItem
                let result = try await service
                    .playbackOpen(item: playbackItem, maxVideoBitrateKbps: maxVideoBitrateKbps)
                remotePlayback = JellyfinRemotePlayback(url: result.url,
                                                        headers: result.requiredHTTPHeaders,
                                                        playSessionId: result.playSessionId,
                                                        sourceMetadata: result.sourceMetadata,
                                                        playMethod: result.playMethod)
                presentingPlayer = true
            } catch {
                playbackErrorMessage = friendlyMessage(error)
            }
            isResolvingPlayback = false
        }
    }

    // MARK: - Derived state

    private var localURL: URL? {
        return downloadManager.localURL(for: downloadManager.recordKey(for: detailed))
    }

    private var isDownloading: Bool {
        let key = downloadManager.recordKey(for: detailed)
        return downloadManager.records.contains {
            $0.ratingKey == key && ($0.status == .queued || $0.status == .downloading)
        }
    }

    private var downloadLabel: String {
        let key = downloadManager.recordKey(for: detailed)
        if let rec = downloadManager.records.first(where: { $0.ratingKey == key }) {
            if rec.status == .failed { return "Download Failed" }
            if rec.status == .complete { return "Downloaded" }
            return "Downloading \(Int(rec.progress * 100))%"
        }
        return "Download"
    }

    private var isWatched: Bool {
        if let override = watchedOverride { return override }
        return (detailed.viewCount ?? 0) > 0
    }

    private var supportsWatchedToggle: Bool {
        switch appModel.activeBackend {
        case .plex, .jellyfin:
            return true
        }
    }

    private var resumeLabel: String {
        if let offset = detailed.viewOffset, offset > 0 { return "Resume" }
        return "Play"
    }

    private var runtimeMinutes: Int? {
        guard let ms = detailed.duration, ms > 0 else { return nil }
        return ms / 60000
    }

    /// The `Media` entry the viewer has selected, if any.
    private var selectedMedia: Media? {
        detailed.media?[safe: selectedMediaIndex]
    }

    /// Tech-spec badges (resolution · codec · bitrate · container) for a version.
    private func mediaSpecBadges(_ media: Media) -> [String] {
        var specs: [String] = []
        if let res = resolutionLabel(media) { specs.append(res) }
        if let codec = media.videoCodec?.uppercased() { specs.append(codec) }
        if let audio = media.audioCodec?.uppercased() { specs.append(audio) }
        if let bitrate = media.bitrate, bitrate > 0 {
            specs.append(String(format: "%.1f Mbps", Double(bitrate) / 1000))
        }
        if let container = media.container?.uppercased() { specs.append(container) }
        return specs
    }

    /// Compact label for a version in the picker, e.g. "4K · HEVC · 24.0 Mbps".
    private func versionLabel(_ media: Media) -> String {
        var parts: [String] = []
        if let res = resolutionLabel(media) { parts.append(res) }
        if let codec = media.videoCodec?.uppercased() { parts.append(codec) }
        if let bitrate = media.bitrate, bitrate > 0 {
            parts.append(String(format: "%.1f Mbps", Double(bitrate) / 1000))
        }
        return parts.isEmpty ? "Version" : parts.joined(separator: " · ")
    }

    /// Human resolution from a `Media`'s pixel dimensions (4K / 1080p / 720p / …).
    private func resolutionLabel(_ media: Media) -> String? {
        guard let h = media.height, h > 0 else { return nil }
        switch h {
        case 2000...: return "4K"
        case 1400..<2000: return "1440p"
        case 1000..<1400: return "1080p"
        case 700..<1000: return "720p"
        case 400..<700: return "480p"
        default: return "\(h)p"
        }
    }

    private func refreshMetadata() async {
        if appModel.activeBackend == .jellyfin {
            if let full = try? await JellyfinBrowseService(appModel: appModel).metadata(itemId: item.ratingKey) {
                detailed = full
                selectedMediaIndex = 0
                watchedOverride = nil
            }
            return
        }
        guard let server = appModel.serverBaseURL, let token = appModel.serverToken else { return }
        let req = BrowseAPI.metadata(server: server, token: token,
                                     identity: appModel.identity, ratingKey: item.ratingKey)
        if let resp = try? await appModel.client.send(req, as: MetadataResponse.self),
           let full = resp.mediaContainer.metadata.first {
            detailed = full
            // The fresh payload may have a different number of versions; clamp the
            // selection and drop any stale optimistic watched override now that we have
            // an authoritative value from the server.
            if selectedMediaIndex >= (full.media?.count ?? 1) {
                selectedMediaIndex = 0
            }
            watchedOverride = nil
        }
    }
}

private struct JellyfinRemotePlayback: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let headers: [String: String]
    let playSessionId: String
    let sourceMetadata: JellyfinPlaybackSourceMetadata
    let playMethod: JellyfinPlayMethod
}

/// Browser for a TV CONTAINER (a `show` or a `season`).
///
/// - A `show` lists its seasons; selecting one pushes another `DetailView`, which (since a
///   season is itself a container) recurses into this browser to show that season's
///   episodes.
/// - A `season` lists its episodes directly.
///
/// Selecting an episode pushes `DetailView(item: episode)` — a LEAF — whose Play/Download/
/// Mark actions target the episode's own ratingKey (the item that owns a Media/Part),
/// which is the fix for the series-download HTTP 400.
///
/// Children come from `GET /library/metadata/{ratingKey}/children` via `BrowseAPI.children`.
struct ContainerBrowserView: View {
    let container: MediaItem

    @Environment(AppModel.self) private var appModel

    @State private var children: [MediaItem] = []
    @State private var loadState: HomeView.LoadState = .idle

    private let columns = [GridItem(.adaptive(minimum: DS.Poster.gridMin, maximum: DS.Poster.gridMax),
                                    spacing: DS.Space.xl)]

    /// A season lists episodes (drawn as wide episode rows); a show lists seasons (posters).
    private var childrenAreEpisodes: Bool { container.kind == .season }

    var body: some View {
        ScrollView {
            switch loadState {
            case .idle, .loading:
                ProgressView("Loading…")
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: 360)
            case .failed(let message):
                ContentUnavailableView("Couldn’t load \(container.title)",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(message))
                    .frame(maxWidth: .infinity, minHeight: 360)
            case .loaded:
                if children.isEmpty {
                    ContentUnavailableView(childrenAreEpisodes ? "No episodes" : "No seasons",
                                           systemImage: "tv",
                                           description: Text("Nothing to show for \(container.title)."))
                        .frame(maxWidth: .infinity, minHeight: 360)
                } else if childrenAreEpisodes {
                    episodeList
                } else {
                    seasonGrid
                }
            }
        }
        .navigationTitle(container.grandparentTitle ?? container.title)
        .task { await load() }
    }

    /// Seasons as a poster grid (same look as a library section).
    private var seasonGrid: some View {
        LazyVGrid(columns: columns, spacing: DS.Space.xxl) {
            ForEach(children) { season in
                NavigationLink(value: season) {
                    PosterCell(item: season, width: DS.Poster.gridMin)
                }
                .cardLink()
            }
        }
        .padding(DS.Space.xl)
    }

    /// Episodes as a vertical list of wide rows, each reading
    /// "S{parentIndex}E{index} · {title}" — Plex/Emby style.
    private var episodeList: some View {
        LazyVStack(spacing: DS.Space.md) {
            ForEach(children) { episode in
                NavigationLink(value: episode) {
                    EpisodeRow(episode: episode)
                }
                .cardLink(cornerRadius: DS.Radius.card)
            }
        }
        .padding(DS.Space.xl)
    }

    private func load() async {
        // `.task` re-fires when popping back from a pushed season/episode; reloading
        // then resets the scroll position the user is returning to. Load once.
        if case .loaded = loadState { return }
        if appModel.activeBackend == .jellyfin {
            loadState = .loading
            do {
                children = try await JellyfinBrowseService(appModel: appModel).items(parentId: container.ratingKey, recursive: false)
                loadState = .loaded
            } catch {
                loadState = .failed(friendlyMessage(error))
            }
            return
        }

        guard let server = appModel.serverBaseURL, let token = appModel.serverToken else {
            loadState = .failed("No server selected.")
            return
        }
        loadState = .loading
        let req = BrowseAPI.children(server: server, token: token,
                                     identity: appModel.identity, ratingKey: container.ratingKey)
        do {
            let resp = try await appModel.client.send(req, as: MetadataResponse.self)
            children = resp.mediaContainer.metadata
            loadState = .loaded
        } catch {
            loadState = .failed(friendlyMessage(error))
        }
    }
}

/// A wide episode row used inside a season: thumbnail + "S{x}E{y} · Title" + summary,
/// with a continue-watching sliver when the episode carries a resume offset.
struct EpisodeRow: View {
    let episode: MediaItem

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.lg) {
            PosterImage(path: episode.thumb ?? episode.parentThumb,
                        width: 200,
                        height: 112,
                        cornerRadius: DS.Radius.poster)
                .overlay(alignment: .bottom) { progressSliver }

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(episodeTitle)
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                if let summary = episode.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Space.md)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        // NOTE: highlight comes from the wrapping link's `.cardLink(cornerRadius: DS.Radius.card)`
        // — a custom ButtonStyle here misroutes pinches to neighboring rows (DEVELOPMENT.md).
    }

    /// "S{parentIndex}E{index} · {title}", falling back to the bare title.
    private var episodeTitle: String {
        if let code = episode.seasonEpisodeCode {
            return "\(code) · \(episode.title)"
        }
        return episode.title
    }

    @ViewBuilder
    private var progressSliver: some View {
        if let offset = episode.viewOffset, offset > 0,
           let duration = episode.duration, duration > 0 {
            let fraction = min(1, max(0, Double(offset) / Double(duration)))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.black.opacity(0.45))
                    Capsule().fill(.tint).frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 4)
            .padding(.horizontal, DS.Space.sm)
            .padding(.bottom, DS.Space.sm)
        }
    }
}

/// Safe-index helper used by the version picker / media-info summary so a stale index
/// (after a metadata refresh swaps the versions) can never trap. Module-internal so the
/// download pipeline can also index media/parts defensively (offline-download redesign).
extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
