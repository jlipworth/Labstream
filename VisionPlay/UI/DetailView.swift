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
    /// The backend this detail's item ORIGINATED from, captured when the view is pushed
    /// (#100). Play / watched-toggle / download resolve against this backend rather than
    /// the live `appModel.activeBackend`, so a stale detail that survives a backend switch
    /// can never send its ratingKey to the wrong server. `nil` → fall back to the active
    /// backend (preserves behavior for any caller that doesn't pass an origin).
    let originBackend: MediaBackendKind?

    @Environment(AppModel.self) private var appModel
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(MusicPlayerController.self) private var musicPlayer
    /// The browse tab this detail lives under, injected by RootView, so Cinema exit returns to the
    /// originating tab's detail instead of always Home (#87). `nil` → fall back to the system-entry
    /// (Home) path, preserving prior behavior.
    @Environment(\.cinemaOriginTab) private var cinemaOriginTab

    @State private var detailed: MediaItem
    @State private var presentingPlayer = false
    @State private var localPlaybackRequest: LocalPlaybackRequest?
    @State private var remotePlayback: JellyfinRemotePlayback?
    @State private var embyRemotePlayback: EmbyRemotePlayback?
    @State private var showDownloadOptions = false
    @State private var playbackErrorMessage: String?
    @State private var isResolvingPlayback = false
    @AppStorage(PlaybackPreferences.Keys.remoteQualityKbps) private var remoteMaxVideoBitrateKbps = PlaybackPreferences.defaultRemoteQualityKbps
    @AppStorage(PlaybackPreferences.Keys.homeQualityKbps) private var homeMaxVideoBitrateKbps = PlaybackPreferences.defaultHomeQualityKbps
    @AppStorage(PlaybackPreferences.Keys.resumeRewindSeconds) private var resumeRewindSeconds = 0

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

    init(item: MediaItem, originBackend: MediaBackendKind? = nil) {
        self.item = item
        self.originBackend = originBackend
        _detailed = State(initialValue: item)
    }

    /// Backend that Play / watched / download must act against (#100): the item's origin
    /// backend when known, resolved through the pure `PlaybackBackendResolver` so the rule
    /// ("origin always wins over the current active backend") is unit-testable. Falls back
    /// to the live active backend when no origin was captured.
    private var actionBackend: MediaBackendKind {
        guard let originBackend else { return appModel.activeBackend }
        return MediaBackendKind(
            PlaybackBackendResolver.backend(forItemOrigin: originBackend.backendChoice,
                                            currentActive: appModel.activeBackend.backendChoice))
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
                // Hero sizes to the item's real artwork ratio when the backend reports one
                // (e.g. a 16:9 episode still renders 16:9 instead of cropped 2:3); Plex and
                // any item without a ratio keep the canonical 2:3 poster shape (GH #101).
                PosterImage(path: detailed.thumb,
                            width: DS.Poster.detailWidth,
                            height: CGFloat(Double(DS.Poster.detailWidth) / detailed.resolvedPosterAspect(fallback: Double(DS.Poster.aspect))),
                            cornerRadius: DS.Radius.card)
                    .shadow(color: .black.opacity(0.4), radius: 24, x: 0, y: 16)

                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    // For an episode, keep the small contextual "eyebrow" (show + S/E code)
                    // separate from the large episode title. Putting S58E2 and a long title in
                    // one HStack makes the title wrap awkwardly beside the code instead of using
                    // the full text column width (GH #101/#106 live-test polish).
                    if detailed.kind == .episode {
                        VStack(alignment: .leading, spacing: DS.Space.xs) {
                            HStack(spacing: DS.Space.sm) {
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
                                if let code = detailed.seasonEpisodeCode {
                                    Text(code)
                                        .font(.title3.weight(.bold))
                                        .foregroundStyle(.tint)
                                }
                            }
                            Text(detailed.title)
                                .font(.largeTitle.bold())
                                .fixedSize(horizontal: false, vertical: true)
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

                    creditsSection

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
        .task {
            await refreshMetadata()
            // System-entry autoplay (#24): a "Play …" intent armed the router right
            // before pushing this view; consume it once metadata is in and present
            // the player — the same sequence as tapping the Play button.
            if SystemEntryRouter.shared.consumeAutoPlay(for: detailed.ratingKey),
               !detailed.isMusic {
                musicPlayer.pauseForVideo()
                playingItem = itemWithResumeRewind(detailed)
                presentingPlayer = true
            }
        }
        .fullScreenCover(item: $localPlaybackRequest) { request in
            CustomPlayerView(localFile: request.url,
                             item: request.item,
                             trickPlayProvider: localTrickPlayProvider(kind: request.trickPlayKind,
                                                                       url: request.trickPlayURL,
                                                                       chapterImageURLs: request.chapterImageURLs,
                                                                       offlineChapters: request.offlineChapters),
                             offlineTextSubtitles: request.offlineTextSubtitles,
                             offlineChapterImageURLs: request.chapterImageURLs,
                             cinemaOrigin: .offline(ratingKey: request.downloadRatingKey),
                             onClose: { localPlaybackRequest = nil })
                .ignoresSafeArea()
        }
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
            PosterImage(path: art, width: 900, height: 600, cornerRadius: 0, requestScale: 1.0)
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
            // Critic rating sits next to the star only when the backend exposes a distinct
            // critic/aggregate field. Plex `audienceRating` is intentionally not mapped here.
            if let critic = detailed.criticRating, critic > 0 {
                Label(String(format: "%.1f", critic), systemImage: "rosette")
                    .foregroundStyle(.orange)
            }
            if isWatched {
                Label("Watched", systemImage: "checkmark.circle.fill")
            }
        }
        .font(.title3)
        .foregroundStyle(.secondary)
    }

    /// Cast / director / studio credits (#76). Each line renders only when its tag list is
    /// non-empty, so movies-without-cast or backends-without-people degrade to nothing.
    @ViewBuilder
    private var creditsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            creditLine(label: "Cast", tags: detailed.roles, limit: 6)
            creditLine(label: "Director", tags: detailed.directors, limit: 3)
            creditLine(label: "Studio", tags: detailed.studios, limit: 3)
        }
    }

    @ViewBuilder
    private func creditLine(label: String, tags: [Tag]?, limit: Int) -> some View {
        if let tags, !tags.isEmpty {
            let names = tags.prefix(limit).map(\.tag).joined(separator: ", ")
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(label):").foregroundStyle(.secondary)
                Text(names).foregroundStyle(.primary.opacity(0.85))
            }
            .font(.callout)
        }
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
                let key = downloadManager.recordKey(for: detailed, backend: actionBackend.downloadBackendKind)
                let record = downloadManager.records.first { $0.ratingKey == key && $0.isComplete }
                // Prefer the persisted download snapshot as the authoritative source: it describes the
                // exact downloaded variant (part, chapters, cached subtitles), whereas the live
                // `detailed` can reflect a different server stream/part than the file on disk. Fall back
                // to `detailed` only when no snapshot was captured.
                let offlineItem = record?.metadata?.makeMediaItem() ?? detailed
                AppDiagnostics.record(.playback, "playback.offline_launch", fields: [
                    "download_id": .identifier(key),
                    "has_file": .bool(FileManager.default.fileExists(atPath: local.path)),
                    "has_metadata": .bool(record?.metadata != nil),
                    "chapter_count": .int(record?.metadata?.chapters?.count ?? 0),
                    "subtitle_count": .int(record?.metadata?.offlineTextSubtitles?.count ?? 0),
                ])
                let trickPlayURL: URL?
                let trickPlayKind: LocalTrickPlayKind?
                let chapterImageURLs = downloadManager.chapterImageURLs(for: key)
                if key.hasPrefix("jellyfin:") {
                    trickPlayURL = downloadManager.jellyfinTrickPlayPlaylistURL(for: key)
                    trickPlayKind = .jellyfinTiles
                } else if key.hasPrefix("emby:") {
                    // Emby has no scrub-preview tiles; its offline scrubber is fed by the cached
                    // per-chapter images (#89).
                    trickPlayURL = nil
                    trickPlayKind = .embyChapterImages
                } else {
                    trickPlayURL = downloadManager.plexBIFURL(for: key)
                    trickPlayKind = .plexBIF
                }
                remotePlayback = nil
                embyRemotePlayback = nil
                playingItem = nil
                presentingPlayer = false
                localPlaybackRequest = LocalPlaybackRequest(url: local,
                                                            item: itemWithResumeRewind(offlineItem),
                                                            trickPlayURL: trickPlayURL,
                                                            trickPlayKind: trickPlayKind,
                                                            chapterImageURLs: chapterImageURLs,
                                                            offlineChapters: record?.metadata?.chapters ?? [],
                                                            offlineTextSubtitles: record?.metadata?.offlineTextSubtitles ?? [],
                                                            downloadRatingKey: key)
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

    /// Origin for an ONLINE (streamed) playback launched from this detail: the originating browse
    /// tab when known, else the system-entry (Home) fallback (#87).
    private var onlineCinemaOrigin: CinemaOrigin {
        cinemaOriginTab.map(CinemaOrigin.onlineTab) ?? .systemEntry
    }

    @ViewBuilder
    private var playerCover: some View {
        // The item currently in the cover: starts as `detailed`, then swaps to the next
        // episode on Up Next autoplay (#15). Fall back to `detailed` defensively.
        let playing = playingItem ?? detailed
        if let remote = remotePlayback {
            CustomPlayerView(item: playing,
                             controllerFactory: {
                                 PlaybackController(remoteStreamURL: remote.url,
                                                    item: playing,
                                                    identity: appModel.identity,
                                                    client: appModel.client,
                                                    httpHeaders: remote.headers,
                                                    remotePlaySessionId: remote.playSessionId,
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
                                                            playSessionId: result.playSessionId,
                                                            sourceMetadata: result.sourceMetadata,
                                                            playMethod: result.playMethod,
                                                            onStop: {
                                                                Task {
                                                                    await JellyfinBrowseService(appModel: appModel)
                                                                        .stopActiveEncoding(playSessionId: result.playSessionId)
                                                                }
                                                            })
                                                    },
                                                    maxVideoBitrateKbps: activeMaxVideoBitrateKbps,
                                                    qualityDefaultsKey: appModel.activeStreamingQualityDefaultsKey)
                             },
                             trickPlayProvider: JellyfinTrickPlayThumbnailProvider(
                                item: playing,
                                server: appModel.jellyfinServerBaseURL,
                                token: appModel.jellyfinAccessToken,
                                identity: appModel.identity.jellyfin),
                             cinemaOrigin: onlineCinemaOrigin,
                             onClose: { presentingPlayer = false },
                             allowsRealityTheater: false)
                .id(remote.id)
                .ignoresSafeArea()
        } else if let remote = embyRemotePlayback {
            CustomPlayerView(item: playing,
                             controllerFactory: {
                                 PlaybackController(remoteStreamURL: remote.url,
                                                    item: playing,
                                                    identity: appModel.identity,
                                                    client: appModel.client,
                                                    httpHeaders: remote.headers,
                                                    remotePlaySessionId: remote.playSessionId,
                                                    sourceMetadata: remote.sourceMetadata.asRemoteCarrier(),
                                                    playMethod: remote.playMethod.asRemoteCarrier(),
                                                    onStopRemoteSession: {
                                                        Task {
                                                            await EmbyBrowseService(appModel: appModel)
                                                                .stopActiveEncoding(playSessionId: remote.playSessionId)
                                                        }
                                                    },
                                                    remoteStreamReopener: { request in
                                                        let result = try await EmbyBrowseService(appModel: appModel)
                                                            .playbackOpen(item: playing,
                                                                          maxVideoBitrateKbps: request.bitrateKbps,
                                                                          resumeOffsetMs: request.offsetMs,
                                                                          audioStreamIndex: request.audioStreamIndex,
                                                                          subtitleStreamIndex: request.subtitleStreamIndex)
                                                        return RemoteStreamOpenResult(
                                                            url: result.url,
                                                            headers: result.requiredHTTPHeaders,
                                                            playSessionId: result.playSessionId,
                                                            sourceMetadata: result.sourceMetadata.asRemoteCarrier(),
                                                            playMethod: result.playMethod.asRemoteCarrier(),
                                                            onStop: {
                                                                // Active-encoding cleanup only when the source used
                                                                // server-side encoding; harmless no-op otherwise.
                                                                Task {
                                                                    if result.usesServerEncoding {
                                                                        await EmbyBrowseService(appModel: appModel)
                                                                            .stopActiveEncoding(playSessionId: result.playSessionId)
                                                                    }
                                                                }
                                                            })
                                                    },
                                                    maxVideoBitrateKbps: activeMaxVideoBitrateKbps,
                                                    qualityDefaultsKey: appModel.activeStreamingQualityDefaultsKey)
                             },
                             // Emby has no Jellyfin-style trickplay tiles; serve coarse,
                             // chapter-granularity scrub previews from the per-chapter image
                             // endpoint instead (nil when the item has no chapter images).
                             trickPlayProvider: EmbyChapterTrickPlayThumbnailProvider(
                                item: playing,
                                server: appModel.embyServerBaseURL,
                                token: appModel.embyAccessToken,
                                identity: appModel.identity.emby,
                                userId: appModel.embyUserID),
                             cinemaOrigin: onlineCinemaOrigin,
                             onClose: { presentingPlayer = false },
                             allowsRealityTheater: false)
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
                                                        maxVideoBitrateKbps: activeMaxVideoBitrateKbps,
                                                        qualityDefaultsKey: appModel.activeStreamingQualityDefaultsKey,
                                                        mediaIndex: mediaIndex,
                                                        machineIdentifier: machineIdentifier)
                                 },
                                 trickPlayProvider: PlexBIFTrickPlayThumbnailProvider(item: playing,
                                                                                      mediaIndex: mediaIndex,
                                                                                      server: server,
                                                                                      token: token,
                                                                                      identity: appModel.identity,
                                                                                      client: appModel.client),
                                 cinemaOrigin: onlineCinemaOrigin,
                                 onClose: { presentingPlayer = false },
                                 onRequestPlay: playNext,
                                 allowsRealityTheater: true)
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
            switch actionBackend {
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
            case .emby:
                try await EmbyBrowseService(appModel: appModel)
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
        let span = PerformanceInstrumentation.begin(.playbackResolve,
                                                     backend: actionBackend.performanceLabel,
                                                     fields: [
                                                        "resume": detailed.viewOffset ?? 0,
                                                        "quality_kbps": activeMaxVideoBitrateKbps,
                                                     ])
        playbackErrorMessage = nil
        musicPlayer.pauseForVideo()
        playingItem = itemWithResumeRewind(detailed)
        switch actionBackend {
        case .plex:
            remotePlayback = nil
            embyRemotePlayback = nil
            presentingPlayer = true
            span.end(fields: ["path_mode": "plex_stream"])
        case .jellyfin:
            isResolvingPlayback = true
            embyRemotePlayback = nil
            do {
                let service = JellyfinBrowseService(appModel: appModel)
                let fetched = (try? await service.metadata(itemId: detailed.ratingKey)) ?? detailed
                let playbackItem = itemWithResumeRewind(fetched)
                playingItem = playbackItem
                let result = try await service
                    .playbackOpen(item: playbackItem, maxVideoBitrateKbps: activeMaxVideoBitrateKbps)
                remotePlayback = JellyfinRemotePlayback(url: result.url,
                                                        headers: result.requiredHTTPHeaders,
                                                        playSessionId: result.playSessionId,
                                                        sourceMetadata: result.sourceMetadata,
                                                        playMethod: result.playMethod)
                presentingPlayer = true
                span.end(fields: [
                    "path_mode": "remote_stream",
                    "play_method": result.playMethod.rawValue,
                ])
            } catch {
                span.end(result: "failure", fields: ["error": PerformanceInstrumentation.errorLabel(error)])
                playbackErrorMessage = friendlyMessage(error)
            }
            isResolvingPlayback = false
        case .emby:
            isResolvingPlayback = true
            remotePlayback = nil
            do {
                let service = EmbyBrowseService(appModel: appModel)
                let fetched = (try? await service.metadata(itemId: detailed.ratingKey)) ?? detailed
                let playbackItem = itemWithResumeRewind(fetched)
                playingItem = playbackItem
                let result = try await service
                    .playbackOpen(item: playbackItem, maxVideoBitrateKbps: activeMaxVideoBitrateKbps)
                embyRemotePlayback = EmbyRemotePlayback(url: result.url,
                                                        headers: result.requiredHTTPHeaders,
                                                        playSessionId: result.playSessionId,
                                                        sourceMetadata: result.sourceMetadata,
                                                        playMethod: result.playMethod)
                presentingPlayer = true
                span.end(fields: [
                    "path_mode": "remote_stream",
                    "play_method": result.playMethod.rawValue,
                ])
            } catch {
                span.end(result: "failure", fields: ["error": PerformanceInstrumentation.errorLabel(error)])
                playbackErrorMessage = friendlyMessage(error)
            }
            isResolvingPlayback = false
        }
    }

    // MARK: - Derived state

    private var activeMaxVideoBitrateKbps: Int {
        // Touch the @AppStorage properties so SwiftUI invalidates this view when either cap
        // changes, then resolve through AppModel's connection-aware scope helper.
        _ = homeMaxVideoBitrateKbps
        _ = remoteMaxVideoBitrateKbps
        return appModel.activeStreamingQualityKbps
    }

    private func adjustedResumeOffsetMs(_ offset: Int?) -> Int? {
        guard let offset, offset > 0, resumeRewindSeconds > 0 else { return offset }
        return max(0, offset - resumeRewindSeconds * 1000)
    }

    private func itemWithResumeRewind(_ item: MediaItem) -> MediaItem {
        guard item.viewOffset != nil, resumeRewindSeconds > 0 else { return item }
        return item.copyWith(viewOffset: adjustedResumeOffsetMs(item.viewOffset))
    }

    private enum LocalTrickPlayKind {
        case plexBIF
        case jellyfinTiles
        case embyChapterImages
    }

    private struct LocalPlaybackRequest: Identifiable {
        let id = UUID()
        let url: URL
        let item: MediaItem
        let trickPlayURL: URL?
        let trickPlayKind: LocalTrickPlayKind?
        let chapterImageURLs: [Int: URL]
        let offlineChapters: [OfflineChapter]
        let offlineTextSubtitles: [OfflineTextSubtitleTrack]
        /// The persisted offline row id (namespaced for Jellyfin/Emby). This can differ from the
        /// reconstructed `item.ratingKey`, so Cinema exit must preserve this value to focus the
        /// correct Offline row across all backends (#87).
        let downloadRatingKey: String
    }

    private func localTrickPlayProvider(kind: LocalTrickPlayKind?,
                                        url: URL?,
                                        chapterImageURLs: [Int: URL],
                                        offlineChapters: [OfflineChapter]) -> (any TrickPlayThumbnailProviding)? {
        switch kind {
        case .plexBIF:
            return LocalBIFTrickPlayThumbnailProvider(bifURL: url)
        case .jellyfinTiles:
            return LocalJellyfinTrickPlayThumbnailProvider(playlistURL: url)
        case .embyChapterImages:
            return LocalEmbyChapterTrickPlayThumbnailProvider(chapters: offlineChapters,
                                                              imageURLsByChapterIndex: chapterImageURLs)
        case nil:
            return nil
        }
    }

    private var localURL: URL? {
        return downloadManager.localURL(for: downloadManager.recordKey(for: detailed, backend: actionBackend.downloadBackendKind))
    }

    private var isDownloading: Bool {
        let key = downloadManager.recordKey(for: detailed, backend: actionBackend.downloadBackendKind)
        return downloadManager.records.contains {
            $0.ratingKey == key && ($0.status == .queued || $0.status == .downloading)
        }
    }

    private var downloadLabel: String {
        let key = downloadManager.recordKey(for: detailed, backend: actionBackend.downloadBackendKind)
        if let rec = downloadManager.records.first(where: { $0.ratingKey == key }) {
            if rec.status == .failed { return "Download Failed" }
            if rec.status == .paused { return "Download Paused" }
            if rec.isUnverified { return "Downloaded (Unverified)" }
            if rec.isComplete { return "Downloaded" }
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
        case .plex, .jellyfin, .emby:
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
        // Resolve metadata against the item's origin backend (#100), not the live active
        // backend, so a detail that lingered across a switch refreshes from the right server.
        let span = PerformanceInstrumentation.begin(.detailMetadata,
                                                     backend: actionBackend.performanceLabel)
        if actionBackend == .jellyfin {
            if let full = try? await JellyfinBrowseService(appModel: appModel).metadata(itemId: item.ratingKey) {
                detailed = full
                selectedMediaIndex = 0
                watchedOverride = nil
                span.end(fields: ["media_count": full.media?.count ?? 0])
            } else {
                span.end(result: "failure", fields: ["error": "metadata_unavailable"])
            }
            return
        }
        if actionBackend == .emby {
            if let full = try? await EmbyBrowseService(appModel: appModel).metadata(itemId: item.ratingKey) {
                detailed = full
                selectedMediaIndex = 0
                watchedOverride = nil
                span.end(fields: ["media_count": full.media?.count ?? 0])
            } else {
                span.end(result: "failure", fields: ["error": "metadata_unavailable"])
            }
            return
        }
        guard let server = appModel.serverBaseURL, let token = appModel.serverToken else {
            span.end(result: "failure", fields: ["error": "missing_plex_server"])
            return
        }
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
            span.end(fields: ["media_count": full.media?.count ?? 0])
        } else {
            span.end(result: "failure", fields: ["error": "metadata_unavailable"])
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

private struct EmbyRemotePlayback: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let headers: [String: String]
    let playSessionId: String
    let sourceMetadata: EmbyPlaybackSourceMetadata
    let playMethod: EmbyPlayMethod
}

// The shared remote-stream player path (`RemoteStreamOpenResult`/`PlaybackController`)
// carries Jellyfin-typed metadata. Bridge the Emby lane's own types onto that neutral
// carrier at this seam so the player path is reused verbatim (no PlaybackController change).
extension EmbyPlaybackSourceMetadata {
    func asRemoteCarrier() -> JellyfinPlaybackSourceMetadata {
        JellyfinPlaybackSourceMetadata(container: container,
                                       width: width,
                                       height: height,
                                       bitrate: bitrate,
                                       videoCodec: videoCodec,
                                       audioCodec: audioCodec)
    }
}

extension EmbyPlayMethod {
    func asRemoteCarrier() -> JellyfinPlayMethod {
        switch self {
        case .directPlay: return .directPlay
        case .directStream: return .directStream
        case .transcode: return .transcode
        }
    }
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
        .id(container.ratingKey)
        .task(id: container.ratingKey) { await load() }
    }

    /// Seasons as a poster grid (same look as a library section).
    private var seasonGrid: some View {
        LazyVGrid(columns: columns, spacing: DS.Space.xxl) {
            ForEach(Array(children.enumerated()), id: \.element.containerRowIdentity) { _, season in
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
            ForEach(Array(children.enumerated()), id: \.element.containerRowIdentity) { _, episode in
                NavigationLink(value: episode) {
                    EpisodeRow(episode: episode)
                }
                .cardLink(cornerRadius: DS.Radius.card)
            }
        }
        .padding(DS.Space.xl)
    }

    private func recordContainerChildrenDiagnostics(_ loaded: [MediaItem],
                                                    normalized: [MediaItem],
                                                    backend: String) {
        guard childrenAreEpisodes else { return }
        let summary = BrowseDiagnostics.containerChildren(rawItems: loaded,
                                                          normalizedItems: normalized,
                                                          backend: backend,
                                                          container: container,
                                                          childrenAreEpisodes: childrenAreEpisodes)
        AppDiagnostics.record(.browse, "container.children", fields: summary.fields)
        #if DEBUG
        NSLog("%@", "container.children \(summary.consoleLine)")
        #endif
    }

    private func load() async {
        // Always reload when this browser appears. Season/episode payloads are small, and this
        // avoids keeping a stale, duplicated child snapshot alive across navigation restoration
        // or backend/model changes.
        children = []
        if appModel.activeBackend == .jellyfin {
            loadState = .loading
            do {
                let loaded = try await JellyfinBrowseService(appModel: appModel)
                    .items(parentId: container.ratingKey, recursive: false)
                let normalized = loaded.normalizedForContainerBrowser(childrenAreEpisodes: childrenAreEpisodes)
                recordContainerChildrenDiagnostics(loaded, normalized: normalized, backend: "Jellyfin")
                children = normalized
                loadState = .loaded
            } catch {
                loadState = .failed(friendlyMessage(error))
            }
            return
        }
        if appModel.activeBackend == .emby {
            loadState = .loading
            do {
                let loaded = try await EmbyBrowseService(appModel: appModel)
                    .items(parentId: container.ratingKey, recursive: false)
                let normalized = loaded.normalizedForContainerBrowser(childrenAreEpisodes: childrenAreEpisodes)
                recordContainerChildrenDiagnostics(loaded, normalized: normalized, backend: "Emby")
                children = normalized
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
            let loaded = resp.mediaContainer.metadata
            let normalized = loaded.normalizedForContainerBrowser(childrenAreEpisodes: childrenAreEpisodes)
            recordContainerChildrenDiagnostics(loaded, normalized: normalized, backend: "Plex")
            children = normalized
            loadState = .loaded
        } catch {
            loadState = .failed(friendlyMessage(error))
        }
    }
}

private extension MediaItem {
    /// Stable per-row identity for season/episode container browsers. Keep backend id in the
    /// SwiftUI identity so taps still route to the exact item when rows are legitimately distinct.
    var containerRowIdentity: String {
        [ratingKey, type, parentIndex.map(String.init), index.map(String.init), title]
            .compactMap { $0 }
            .joined(separator: "|")
    }

    /// Visible episode identity for de-duping server duplicates. Jellyfin can expose multiple
    /// physical entries/versions with distinct item ids but identical S/E/title/artwork; a season
    /// browser should show one row for that episode, not four indistinguishable rows.
    var episodeDisplayIdentity: String {
        [parentIndex.map(String.init), index.map(String.init), title]
            .compactMap { $0 }
            .joined(separator: "|")
    }
}

private extension Array where Element == MediaItem {
    /// Normalize a show/season child payload at the UI boundary: sort episode lists by numeric
    /// S/E order and collapse visible duplicate episode rows. Use display identity for episodes
    /// (S/E/title) rather than backend id, because duplicate files can arrive as separate Jellyfin
    /// items while being impossible to distinguish in this list.
    func normalizedForContainerBrowser(childrenAreEpisodes: Bool) -> [MediaItem] {
        let ordered = childrenAreEpisodes ? sortedByEpisodeOrder() : self
        var seen = Set<String>()
        return ordered.filter { item in
            let key = childrenAreEpisodes ? item.episodeDisplayIdentity : item.containerRowIdentity
            return seen.insert(key).inserted
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

    private var progressSliver: some View {
        ProgressSliver(offset: episode.viewOffset, duration: episode.duration)
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


private extension MediaItem {
    func copyWith(viewOffset: Int?) -> MediaItem {
        MediaItem(ratingKey: ratingKey, key: key, title: title, type: type,
                  duration: duration, viewOffset: viewOffset, viewCount: viewCount,
                  year: year, summary: summary, thumb: thumb, art: art, media: media,
                  librarySectionID: librarySectionID, librarySectionKey: librarySectionKey,
                  chapters: chapters, markers: markers, rating: rating,
                  contentRating: contentRating, tagline: tagline, genres: genres,
                  criticRating: criticRating, roles: roles, directors: directors,
                  studios: studios, logo: logo,
                  grandparentTitle: grandparentTitle, grandparentRatingKey: grandparentRatingKey,
                  grandparentThumb: grandparentThumb, parentTitle: parentTitle,
                  parentRatingKey: parentRatingKey, parentThumb: parentThumb,
                  parentIndex: parentIndex, index: index, originalTitle: originalTitle,
                  lastViewedAt: lastViewedAt, parentYear: parentYear,
                  ratingCount: ratingCount, composite: composite, leafCount: leafCount,
                  playlistType: playlistType,
                  primaryImageAspectRatio: primaryImageAspectRatio)
    }
}
