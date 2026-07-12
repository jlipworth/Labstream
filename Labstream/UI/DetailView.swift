import SwiftUI
import PMSKit
#if os(iOS)
import UIKit
#endif

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
    #if os(iOS)
    /// Drives iOS detail adaptations: compact phones use the dedicated narrow layout, while
    /// narrow iPad split view can still stack the regular poster/metadata layout.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    /// True in ANY iOS compact-width context — iPhone AND a narrow iPad window (Split View /
    /// Slide Over), which reports compact width but is not the phone idiom. Sizing decisions
    /// that must also shrink for a compact iPad pane key on this rather than
    /// `isCompactPhoneLayout`. Always false on visionOS, so its metrics stay untouched.
    @Environment(\.labstreamCompactWidth) private var compactWidth
    /// The browse tab this detail lives under, injected by RootView, so Cinema exit returns to the
    /// originating tab's detail instead of always Home (#87). `nil` → fall back to the system-entry
    /// (Home) path, preserving prior behavior.
    @Environment(\.cinemaOriginTab) private var cinemaOriginTab
    #if os(macOS)
    /// Root-level macOS presenter. When available, playback is lifted out of the split-view detail
    /// so it owns the whole main window surface instead of leaving the browse sidebar visible.
    @Environment(\.macPlayerPresentationStore) private var macPlayerPresenter
    #endif

    @State private var detailed: MediaItem
    @State private var presentingPlayer = false
    @State private var localPlaybackRequest: LocalPlaybackRequest?
    @State private var remotePlayback: MediaBrowserRemotePlayback?
    @State private var showDownloadOptions = false
    @State private var playbackErrorMessage: String?
    @State private var isResolvingPlayback = false
    @State private var isTogglingWatched = false
    @State private var metadataLoadingRatingKey: String?
    @State private var playbackRequestID: UUID?
    @State private var mobilePlayerOrientationCoordinator = MobilePlayerOrientationCoordinator()
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

    /// Which logical MOVIE VERSION (a distinct backend item — own ratingKey) is selected when
    /// the grid collapsed several editions/files of one movie into this tile (GH #108). `nil`
    /// means "the item this detail was opened with" (`item.ratingKey`). Picking a different
    /// version re-fetches its full metadata into `detailed`, so Play/Download act on the chosen
    /// version's ratingKey. Items with a single version never set this and behave as before.
    @State private var selectedVersionRatingKey: String?

    /// Resolved, human version labels for the collapsed movie-version chooser (#108), keyed by
    /// each version's `ratingKey`. Grid items carry no `MediaSources`, so a brief per-version
    /// metadata fetch (bounded to the 2–3 collapsed siblings, run concurrently) supplies a
    /// meaningful label like "4K · HEVC". Entries that haven't resolved (or whose fetch failed)
    /// fall back to "Version N" individually; the fetch never blocks the rest of the screen.
    @State private var movieVersionLabels: [String: String] = [:]

    /// Optimistic local override of the server's watched state. `nil` means "use the
    /// value from `detailed`"; once the user toggles we hold their intent here so the row
    /// reflects it immediately, before/independent of the scrobble round-trip.
    @State private var watchedOverride: Bool?
    #if os(macOS)
    @State private var macPlayerPresentationOwnerID = UUID()
    #endif

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

    /// The collapsed movie versions for this item (#108), when the grid attached more than one.
    /// Each entry is a distinct backend item (own ratingKey) for the same logical movie.
    private var movieVersions: [MediaItem] {
        guard let versions = item.versions, versions.count > 1 else { return [] }
        return versions
    }

    /// The ratingKey whose full metadata `detailed` should reflect: the user-chosen movie
    /// version (#108) when set, else the item this detail opened with.
    private var activeVersionRatingKey: String {
        selectedVersionRatingKey ?? item.ratingKey
    }

    private var isCompactPhoneLayout: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone && horizontalSizeClass == .compact
        #else
        false
        #endif
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

    #if os(iOS)
    /// Readable-measure cap for the metadata/synopsis column in regular width (iPad). Without
    /// it the synopsis `Text` stretches edge-to-edge and is unreadably wide on a 13" landscape
    /// iPad. The poster + text cluster stays leading (not centered), so this only bounds the
    /// text column, not the page. visionOS keeps its uncapped fixed-window layout.
    private static let readableMetadataWidth: CGFloat = 680
    #endif

    /// Poster + metadata arrangement. visionOS keeps the canonical side-by-side HStack. iOS
    /// caps the metadata column to a readable measure in regular width, and stacks the poster
    /// above the metadata in horizontally-compact widths (iPhone, narrow iPad split).
    @ViewBuilder
    private var detailLayout: some View {
        #if os(iOS)
        if isCompactPhoneLayout {
            compactPhoneDetailLayout
        } else if compactWidth {
            // Compact-width iPad (Split View / Slide Over): stack like the phone layout, but
            // the 300-pt regular hero plus page padding overflows a ~320-pt pane, so use the
            // 220-pt compact hero, centered as in the phone branch above.
            VStack(alignment: .leading, spacing: DS.Space.xxxl) {
                detailPoster(width: DS.Poster.detailWidth(compact: true))
                    .frame(maxWidth: .infinity, alignment: .center)
                metadataColumn
            }
        } else {
            HStack(alignment: .top, spacing: DS.Space.xxxl) {
                posterHero
                metadataColumn
                    .frame(maxWidth: Self.readableMetadataWidth, alignment: .leading)
                Spacer(minLength: 0)
            }
        }
        #else
        HStack(alignment: .top, spacing: DS.Space.xxxl) {
            posterHero
            metadataColumn
            Spacer(minLength: 0)
        }
        #endif
    }

    /// Phone-only hierarchy optimized for a narrow, vertically-scrolling detail page. iPad and
    /// visionOS continue to use `metadataColumn` unchanged.
    private var compactPhoneDetailLayout: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            compactPhoneArtwork

            DetailTitleHeader(item: detailed, showItem: showItem)

            DetailMetadataRow(year: detailed.year,
                              runtimeMinutes: runtimeMinutes,
                              contentRating: detailed.contentRating,
                              rating: detailed.rating,
                              criticRating: detailed.criticRating,
                              isWatched: isWatched)

            playButton
                .controlSize(.large)

            VStack(spacing: DS.Space.md) {
                downloadButton
                if supportsWatchedToggle {
                    markWatchedButton
                }
            }
            .controlSize(.large)

            if let playbackErrorMessage {
                Text(playbackErrorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if let tagline = detailed.tagline, !tagline.isEmpty {
                Text(tagline)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .italic()
            }

            if let genres = detailed.genres, !genres.isEmpty {
                Text(genres.map(\.tag).joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            DetailCreditsSection(roles: detailed.roles,
                                 directors: detailed.directors,
                                 studios: detailed.studios)

            DetailMovieVersionPicker(versions: movieVersions,
                                     activeVersionRatingKey: activeVersionRatingKey,
                                     selectedVersionRatingKey: $selectedVersionRatingKey,
                                     resolvedLabels: movieVersionLabels)

            DetailMediaVersionPicker(media: detailed.media,
                                     selectedMediaIndex: $selectedMediaIndex)

            if let media = selectedMedia {
                DetailMediaInfoSummary(specBadges: mediaSpecBadges(media),
                                       chapterCount: detailed.chapters?.count)
            }

            if let summary = detailed.summary, !summary.isEmpty {
                Text(summary)
                    .font(.body)
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineSpacing(4)
                    .padding(.top, DS.Space.sm)
            }
        }
    }

    /// Full-width 16:9 key art for compact phones. The policy prefers backend landscape art,
    /// deliberately crops a poster fallback to fill the landscape frame, and preserves the
    /// existing `PosterImage` placeholder when neither path exists.
    @ViewBuilder
    private var compactPhoneArtwork: some View {
        GeometryReader { geometry in
            switch MobileDetailArtworkPolicy.selection(art: detailed.art, thumb: detailed.thumb) {
            case .landscape(let path):
                compactPhoneArtworkImage(path: path, size: geometry.size)
            case .croppedPoster(let path):
                // PosterImage renders loaded artwork with `.fill`, intentionally cropping the
                // portrait fallback into this landscape frame rather than letterboxing it.
                compactPhoneArtworkImage(path: path, size: geometry.size)
            case .none:
                compactPhoneArtworkImage(path: nil, size: geometry.size)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
    }

    private func compactPhoneArtworkImage(path: String?, size: CGSize) -> some View {
        PosterImage(path: path,
                    width: size.width,
                    height: size.height,
                    cornerRadius: DS.Radius.card)
            .shadow(color: .black.opacity(0.4), radius: 24, x: 0, y: 16)
    }

    /// Hero sizes to the item's real artwork ratio when the backend reports one
    /// (e.g. a 16:9 episode still renders 16:9 instead of cropped 2:3); Plex and
    /// any item without a ratio keep the canonical 2:3 poster shape (GH #101).
    private var posterHero: some View {
        detailPoster(width: DS.Poster.detailWidth)
    }

    @ViewBuilder
    private func detailPoster(width: CGFloat) -> some View {
        PosterImage(path: detailed.thumb,
                    width: width,
                    height: CGFloat(Double(width) / detailed.resolvedPosterAspect(fallback: Double(DS.Poster.aspect))),
                    cornerRadius: DS.Radius.card)
            .shadow(color: .black.opacity(0.4), radius: 24, x: 0, y: 16)
    }

    /// Title, metadata rows, credits, actions, and synopsis. Leading-aligned; the enclosing
    /// layout decides its width (capped on regular-width iOS, full width elsewhere).
    private var metadataColumn: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            DetailTitleHeader(item: detailed, showItem: showItem)

            if let tagline = detailed.tagline, !tagline.isEmpty {
                Text(tagline)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .italic()
            }

            DetailMetadataRow(year: detailed.year,
                              runtimeMinutes: runtimeMinutes,
                              contentRating: detailed.contentRating,
                              rating: detailed.rating,
                              criticRating: detailed.criticRating,
                              isWatched: isWatched)

            if let genres = detailed.genres, !genres.isEmpty {
                Text(genres.map(\.tag).joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            DetailCreditsSection(roles: detailed.roles,
                                 directors: detailed.directors,
                                 studios: detailed.studios)

            actionButtons

            if let media = selectedMedia {
                DetailMediaInfoSummary(specBadges: mediaSpecBadges(media),
                                       chapterCount: detailed.chapters?.count)
            }

            if let summary = detailed.summary, !summary.isEmpty {
                Text(summary)
                    .font(.body)
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineSpacing(4)
                    .padding(.top, DS.Space.sm)
            }
        }
    }

    /// The play/download detail for a LEAF item (movie or episode). Actions target this
    /// item's own ratingKey, which is guaranteed to own a Media/Part.
    private var leafDetail: some View {
        ZStack {
            #if os(macOS)
            if macPlayerPresenter == nil {
                // Preview/fallback path only. In the app, RootView provides a presenter and the
                // player is elevated above NavigationSplitView so the sidebar/toolbars disappear.
                leafDetailScroll
                    .opacity(isMacPlayerPresented ? 0 : 1)
                    .allowsHitTesting(!isMacPlayerPresented)

                if isMacPlayerPresented {
                    macPlayerPresentation
                        .transition(.opacity.combined(with: .scale(scale: 0.995)))
                        .zIndex(1)
                }
            } else {
                leafDetailScroll
            }
            #else
            leafDetailScroll
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(artBackdrop)
        .animation(.easeInOut(duration: 0.16), value: isMacPlayerPresentedValue)
        .navigationTitle(detailed.title)
        // Re-fetch when the chosen movie version changes (#108) as well as on first appear;
        // `activeVersionRatingKey` defaults to `item.ratingKey`, so single-version items run
        // exactly once as before. The autoplay token is one-shot, so a later version switch
        // can't re-trigger it.
        .task(id: activeVersionRatingKey) {
            await refreshMetadata()
            // System-entry autoplay (#24): a "Play …" intent armed the router right
            // before pushing this view; consume it once metadata is in and present
            // the player — the same sequence as tapping the Play button.
            if SystemEntryRouter.shared.consumeAutoPlay(for: detailed.ratingKey),
               !detailed.isMusic {
                musicPlayer.pauseForVideo()
                playingItem = DetailPlaybackLauncher.itemWithResumeRewind(detailed, resumeRewindSeconds: resumeRewindSeconds)
                await presentResolvedPlayer()
            }
        }
        // Resolve the collapsed versions' resolution/codec labels for the chooser (#108).
        // Keyed on `item.ratingKey` (the versions come from `item`, which is stable for this
        // detail), so it runs once and never blocks the rest of the screen. No-op for items
        // with a single version.
        .task(id: item.ratingKey) {
            await resolveMovieVersionLabels()
        }
        #if os(macOS)
        .sheet(isPresented: $showDownloadOptions) {
            DownloadOptionsSheet(item: detailed,
                                 mediaIndex: selectedMediaIndex,
                                 backend: actionBackend.downloadBackendKind)
        }
        .onChange(of: isMacPlayerPresented) { _, _ in
            syncMacPlayerPresentation()
        }
        .onChange(of: localPlaybackRequest?.id) { _, _ in
            syncMacPlayerPresentation()
        }
        .onChange(of: presentingPlayer) { _, _ in
            syncMacPlayerPresentation()
        }
        .onChange(of: playingItem?.ratingKey) { _, _ in
            syncMacPlayerPresentation()
        }
        .onChange(of: remotePlayback?.id) { _, _ in
            syncMacPlayerPresentation()
        }
        .onDisappear {
            dismissMacPlayerPresentation()
        }
        #else
        .fullScreenCover(item: $localPlaybackRequest) { request in
            localPlayerView(for: request)
                .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $presentingPlayer) {
            playerCover
        }
        .sheet(isPresented: $showDownloadOptions) {
            DownloadOptionsSheet(item: detailed,
                                 mediaIndex: selectedMediaIndex,
                                 backend: actionBackend.downloadBackendKind)
        }
        #endif
    }

    private var leafDetailScroll: some View {
        ScrollView {
            #if os(iOS)
            detailLayout
                .padding(.horizontal, compactWidth ? DS.pagePadding(compact: true) : DS.Space.xxxl)
                .padding(.vertical, isCompactPhoneLayout ? DS.Space.xl : DS.Space.xxxl)
            #else
            detailLayout
                .padding(DS.Space.xxxl)
            #endif
        }
    }

    private var isMacPlayerPresentedValue: Bool {
        #if os(macOS)
        isMacPlayerPresented
        #else
        false
        #endif
    }

    #if os(macOS)
    private var isMacPlayerPresented: Bool {
        presentingPlayer || localPlaybackRequest != nil
    }

    private var macPlayerContentID: AnyHashable {
        if let request = localPlaybackRequest {
            return AnyHashable("local-\(request.id.uuidString)")
        }
        let playingRatingKey = playingItem?.ratingKey ?? detailed.ratingKey
        if let remotePlayback {
            return AnyHashable("\(remotePlayback.backend.rawValue)-\(remotePlayback.id.uuidString)-\(playingRatingKey)")
        }
        return AnyHashable("plex-\(playingRatingKey)")
    }

    private func syncMacPlayerPresentation() {
        guard let macPlayerPresenter else { return }
        guard isMacPlayerPresented else {
            macPlayerPresenter.dismiss(ownerID: macPlayerPresentationOwnerID)
            return
        }

        macPlayerPresenter.present(ownerID: macPlayerPresentationOwnerID,
                                   contentID: macPlayerContentID) {
            macPlayerPresentation
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        }
    }

    private func dismissMacPlayerPresentation() {
        macPlayerPresenter?.dismiss(ownerID: macPlayerPresentationOwnerID)
    }

    @ViewBuilder
    private var macPlayerPresentation: some View {
        if let request = localPlaybackRequest {
            localPlayerView(for: request)
                .id(request.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        } else if presentingPlayer {
            playerCover
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        }
    }
    #endif

    @ViewBuilder
    private func localPlayerView(for request: LocalPlaybackRequest) -> some View {
        CustomPlayerView(localFile: request.url,
                         item: request.item,
                         trickPlayProvider: localTrickPlayProvider(kind: request.trickPlayKind,
                                                                   url: request.trickPlayURL,
                                                                   chapterImageURLs: request.chapterImageURLs,
                                                                   offlineChapters: request.offlineChapters),
                         offlineTextSubtitles: request.offlineTextSubtitles,
                         offlineChapterImageURLs: request.chapterImageURLs,
                         cinemaOrigin: .offline(ratingKey: request.downloadRatingKey),
                         mobileOrientationCoordinator: mobilePlayerOrientationCoordinator,
                         onClose: { localPlaybackRequest = nil })
    }


    // MARK: - Backdrop

    /// A heavily-blurred, dimmed wash of the item's `art` (or poster) bleeding behind
    /// the detail content — the cinematic "key art" treatment Plex/Apple TV use. It is
    /// purely decorative: a gradient scrim keeps text legible and it never intercepts
    /// touches. Falls back to nothing (the window's own material) when art is absent.
    @ViewBuilder
    private var artBackdrop: some View {
        if let art = detailed.art ?? detailed.thumb, !art.isEmpty {
            // Color.clear.overlay, NOT a bare PosterImage: the 900×600 poster frame
            // is an intrinsic size, and a ZStack consulting it inflates the whole
            // page to ~900 pt on narrow windows (live on iPhone via the music twin
            // of this backdrop). Zero-ideal-size + scale-to-cover + clipped keeps
            // the wash purely decorative at any window size.
            Color.clear
                .overlay {
                    GeometryReader { geo in
                        let scale = max(geo.size.width / 900, geo.size.height / 600, 1)
                        PosterImage(path: art, width: 900, height: 600, cornerRadius: 0, requestScale: 1.0)
                            .scaleEffect(scale)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .blur(radius: 60)
                            .opacity(0.30)
                    }
                }
                .clipped()
                .overlay(
                    LinearGradient(colors: [.clear, .black.opacity(0.55)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionButtons: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            actionButtonStack

            DetailMovieVersionPicker(versions: movieVersions,
                                     activeVersionRatingKey: activeVersionRatingKey,
                                     selectedVersionRatingKey: $selectedVersionRatingKey,
                                     resolvedLabels: movieVersionLabels)

            DetailMediaVersionPicker(media: detailed.media,
                                     selectedMediaIndex: $selectedMediaIndex)

            if let playbackErrorMessage {
                Text(playbackErrorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var actionButtonStack: some View {
        if compactWidth {
            // Full-width stacked buttons with CENTERED labels — the system idiom for a
            // prominent full-width action (App Store "Get", TV "Play"); a left-aligned
            // label in a full-width pill reads as a list row. The width stretch lives on
            // each button's label so the glass pill itself spans the column.
            VStack(spacing: DS.Space.md) {
                playButton
                downloadButton
                if supportsWatchedToggle {
                    markWatchedButton
                }
            }
            .controlSize(.large)
        } else {
            HStack(spacing: DS.Space.lg) {
                playButton
                downloadButton
                if supportsWatchedToggle {
                    markWatchedButton
                }
            }
        }
    }

    private var playButton: some View {
        Button {
            guard !isResolvingPlayback, !presentingPlayer, metadataReadyForActions else { return }
            isResolvingPlayback = true
            let requestID = UUID()
            playbackRequestID = requestID
            Task { await startPlayback(requestID: requestID) }
        } label: {
            Group {
                if isResolvingPlayback {
                    ProgressView()
                } else {
                    Label(resumeLabel, systemImage: "play.fill")
                }
            }
            .font(.title3.weight(.semibold))
            .frame(maxWidth: compactWidth ? .infinity : nil)
        }
        .labstreamGlassProminentButtonStyle()
        .disabled(isResolvingPlayback || !metadataReadyForActions)
    }

    /// "Play Offline" when a local copy exists, otherwise a button that opens the
    /// `DownloadOptionsSheet` (quality picker) with a live progress label mid-transfer.
    @ViewBuilder
    private var downloadButton: some View {
        if let local = localURL {
            Button {
                musicPlayer.pauseForVideo()
                let key = downloadRecordKey
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
                playingItem = nil
                presentingPlayer = false
                let request = LocalPlaybackRequest(url: local,
                                                   item: DetailPlaybackLauncher.itemWithResumeRewind(offlineItem, resumeRewindSeconds: resumeRewindSeconds),
                                                   trickPlayURL: trickPlayURL,
                                                   trickPlayKind: trickPlayKind,
                                                   chapterImageURLs: chapterImageURLs,
                                                   offlineChapters: record?.metadata?.chapters ?? [],
                                                   offlineTextSubtitles: record?.metadata?.offlineTextSubtitles ?? [],
                                                   downloadRatingKey: key)
                Task { await presentLocalPlayer(request) }
            } label: {
                Label("Play Offline", systemImage: "arrow.down.circle.fill")
                    .font(.title3)
                    .frame(maxWidth: compactWidth ? .infinity : nil)
            }
            .labstreamGlassButtonStyle()
        } else {
            Button {
                showDownloadOptions = true
            } label: {
                Label(downloadLabel, systemImage: "arrow.down.circle")
                    .font(.title3)
                    .frame(maxWidth: compactWidth ? .infinity : nil)
            }
            .labstreamGlassButtonStyle()
            .disabled(isDownloading || !metadataReadyForActions)
        }
    }

    /// Toggle that scrobbles / unscrobbles the item and flips the local watched state
    /// optimistically so the header updates instantly.
    @ViewBuilder
    private var markWatchedButton: some View {
        Button {
            guard !isTogglingWatched else { return }
            isTogglingWatched = true
            Task { await toggleWatched() }
        } label: {
            Label(isWatched ? "Mark Unwatched" : "Mark Watched",
                  systemImage: isWatched ? "minus.circle" : "checkmark.circle")
                .font(.title3)
                .frame(maxWidth: compactWidth ? .infinity : nil)
        }
        .labstreamGlassButtonStyle()
        .disabled(isTogglingWatched)
    }

    /// Fetch each collapsed version's brief metadata concurrently to build resolution/codec
    /// labels for the chooser (#108, finding 5). Grid items lack `MediaSources`, so without
    /// this every entry would read "Version N". Bounded to `movieVersions` (2–3 items), run
    /// in parallel, and resolved off the main work of the screen — a failure for one version
    /// simply leaves its label as the "Version N" fallback.
    @MainActor
    private func resolveMovieVersionLabels() async {
        let versions = movieVersions
        guard versions.count > 1 else { return }
        // Capture the values the fetch needs as locals so the concurrent children don't
        // capture `self` (a non-Sendable View) across the task boundary. `appModel` is a
        // @MainActor model and the children stay on the main actor.
        let backend = actionBackend
        let model = appModel
        let ratingKeys = versions.map(\.ratingKey)
        // Sequential awaits (bounded to 2–3 versions): each child would be `@MainActor`
        // anyway, so a TaskGroup buys no real cross-actor concurrency here, and the
        // region-based isolation checker rejects a `@MainActor` group child returning a
        // tuple. A plain loop is simpler and avoids that compiler limitation.
        for ratingKey in ratingKeys {
            if let label = await Self.fetchVersionLabel(ratingKey: ratingKey,
                                                        backend: backend,
                                                        appModel: model),
               !label.isEmpty {
                movieVersionLabels[ratingKey] = label
            }
        }
    }

    /// Resolve one version's resolution/codec label from its full metadata's first `Media`.
    /// Returns nil on any failure or when no tech specs are available, so the caller keeps the
    /// "Version N" fallback for that entry. Static + explicitly-passed dependencies so the
    /// concurrent task group never captures the `DetailView` value.
    @MainActor
    private static func fetchVersionLabel(ratingKey: String,
                                          backend: MediaBackendKind,
                                          appModel: AppModel) async -> String? {
        let full: MediaItem?
        switch backend {
        case .jellyfin:
            full = try? await JellyfinBrowseService(appModel: appModel).metadata(itemId: ratingKey)
        case .emby:
            full = try? await EmbyBrowseService(appModel: appModel).metadata(itemId: ratingKey)
        case .plex:
            guard let server = appModel.serverBaseURL, let token = appModel.serverToken else { return nil }
            let req = BrowseAPI.metadata(server: server, token: token,
                                         identity: appModel.identity, ratingKey: ratingKey)
            full = (try? await appModel.client.send(req, as: MetadataResponse.self))?.mediaContainer.metadata.first
        }
        guard let media = full?.media?.first else { return nil }
        let label = MediaVersionLabel.versionLabel(for: media)
        return label == "Version" ? nil : label
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
            switch remote.backend {
            case .jellyfin:
                CustomPlayerView(item: playing,
                                 controllerFactory: {
                                     DetailPlaybackLauncher.playbackController(
                                        remote: remote,
                                        item: playing,
                                        appModel: appModel,
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
                                 mobileOrientationCoordinator: mobilePlayerOrientationCoordinator,
                                 allowsRealityTheater: false)
                    .id(remote.id)
                    .ignoresSafeArea()
            case .emby:
                CustomPlayerView(item: playing,
                                 controllerFactory: {
                                     DetailPlaybackLauncher.playbackController(
                                        remote: remote,
                                        item: playing,
                                        appModel: appModel,
                                        maxVideoBitrateKbps: activeMaxVideoBitrateKbps,
                                        qualityDefaultsKey: appModel.activeStreamingQualityDefaultsKey)
                                 },
                                 // Emby has no Jellyfin-style trickplay tiles; serve coarse,
                                 // chapter-granularity scrub previews instead.
                                 trickPlayProvider: EmbyChapterTrickPlayThumbnailProvider(
                                    item: playing,
                                    server: appModel.embyServerBaseURL,
                                    token: appModel.embyAccessToken,
                                    identity: appModel.identity.emby,
                                    userId: appModel.embyUserID),
                                 cinemaOrigin: onlineCinemaOrigin,
                                 onClose: { presentingPlayer = false },
                                 mobileOrientationCoordinator: mobilePlayerOrientationCoordinator,
                                 allowsRealityTheater: false)
                    .id(remote.id)
                    .ignoresSafeArea()
            case .plex:
                EmptyView()
            }
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
                                 mobileOrientationCoordinator: mobilePlayerOrientationCoordinator,
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
        defer { isTogglingWatched = false }
        guard !isResolvingPlayback else { return }
        let wasWatched = isWatched
        // Optimistic flip.
        watchedOverride = !wasWatched

        do {
            try await DetailWatchedUpdater.setPlayed(item: detailed,
                                                     backend: actionBackend,
                                                     appModel: appModel,
                                                     played: !wasWatched)
        } catch {
            // Roll back the optimistic flip; the server rejected the change.
            watchedOverride = wasWatched
        }
    }

    private var metadataReadyForActions: Bool {
        metadataLoadingRatingKey == nil && detailed.ratingKey == activeVersionRatingKey
    }

    private func startPlayback(requestID: UUID) async {
        defer {
            if playbackRequestID == requestID {
                isResolvingPlayback = false
                playbackRequestID = nil
            }
        }
        guard playbackRequestID == requestID, metadataReadyForActions, !presentingPlayer else { return }
        // Defense-in-depth (#15): music is filtered from browse, but never let a music item
        // launch the video player. Unreachable in normal flow.
        guard !detailed.isMusic else { return }
        let launchRatingKey = detailed.ratingKey
        let launchBackend = actionBackend
        let span = PerformanceInstrumentation.begin(.playbackResolve,
                                                     backend: actionBackend.performanceLabel,
                                                     fields: [
                                                        "resume": detailed.viewOffset ?? 0,
                                                        "quality_kbps": activeMaxVideoBitrateKbps,
                                                     ])
        playbackErrorMessage = nil
        musicPlayer.pauseForVideo()
        playingItem = DetailPlaybackLauncher.itemWithResumeRewind(detailed, resumeRewindSeconds: resumeRewindSeconds)
        switch launchBackend {
        case .plex:
            remotePlayback = nil
            await presentResolvedPlayer()
            span.end(fields: ["path_mode": "plex_stream"])
        case .jellyfin, .emby:
            remotePlayback = nil
            do {
                let playbackItem = await DetailPlaybackLauncher.metadataItem(
                    ratingKey: launchRatingKey,
                    fallback: detailed,
                    backend: launchBackend,
                    appModel: appModel,
                    resumeRewindSeconds: resumeRewindSeconds)
                guard playbackRequestID == requestID,
                      metadataReadyForActions,
                      actionBackend == launchBackend,
                      detailed.ratingKey == launchRatingKey else { return }
                playingItem = playbackItem
                let opened = try await DetailPlaybackLauncher.open(
                    item: playbackItem,
                    backend: launchBackend,
                    appModel: appModel,
                    maxVideoBitrateKbps: activeMaxVideoBitrateKbps)
                guard playbackRequestID == requestID,
                      metadataReadyForActions,
                      actionBackend == launchBackend,
                      detailed.ratingKey == launchRatingKey else { return }
                remotePlayback = opened.playback
                await presentResolvedPlayer()
                span.end(fields: [
                    "path_mode": "remote_stream",
                    "play_method": opened.playMethod,
                ])
            } catch {
                span.end(result: "failure", fields: ["error": PerformanceInstrumentation.errorLabel(error)])
                playbackErrorMessage = friendlyMessage(error)
            }
        }
    }

    @MainActor
    private func presentResolvedPlayer() async {
        await mobilePlayerOrientationCoordinator.enterLandscapeBeforePresentationIfNeeded()
        presentingPlayer = true
    }

    @MainActor
    private func presentLocalPlayer(_ request: LocalPlaybackRequest) async {
        await mobilePlayerOrientationCoordinator.enterLandscapeBeforePresentationIfNeeded()
        localPlaybackRequest = request
    }

    // MARK: - Derived state

    private var activeMaxVideoBitrateKbps: Int {
        // Touch the @AppStorage properties so SwiftUI invalidates this view when either cap
        // changes, then resolve through AppModel's connection-aware scope helper.
        _ = homeMaxVideoBitrateKbps
        _ = remoteMaxVideoBitrateKbps
        return appModel.activeStreamingQualityKbps
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

    private var downloadRecordKey: String {
        DownloadRecordIdentity.recordKey(for: detailed.ratingKey, backend: actionBackend.downloadBackendKind)
    }

    private var localURL: URL? {
        return downloadManager.localURL(for: downloadRecordKey)
    }

    private var isDownloading: Bool {
        let key = downloadRecordKey
        return downloadManager.activeJobs.contains(key) || downloadManager.records.contains {
            $0.ratingKey == key && $0.status.isActiveWork
        }
    }

    private var downloadLabel: String {
        let key = downloadRecordKey
        if let rec = downloadManager.records.first(where: { $0.ratingKey == key }) {
            if rec.status == .failed { return "Download Failed" }
            if rec.status == .paused { return "Download Paused" }
            if rec.isUnverified { return "Downloaded (Unverified)" }
            if rec.isComplete { return "Downloaded" }
            if rec.status == .preparing { return "Preparing on Server" }
            if rec.status == .queued {
                return rec.metadata?.resolvedResumeMode(ratingKey: key) == .serverPrepThenStatic
                    ? "Preparing on Server"
                    : "Queued"
            }
            return "Downloading \(Int(rec.progress * 100))%"
        }
        if downloadManager.activeJobs.contains(key) { return "Starting Download" }
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
        MediaVersionLabel.specBadges(for: media)
    }

    private func refreshMetadata() async {
        let requestedRatingKey = activeVersionRatingKey
        metadataLoadingRatingKey = requestedRatingKey
        defer {
            if metadataLoadingRatingKey == requestedRatingKey {
                metadataLoadingRatingKey = nil
            }
        }
        // Resolve metadata against the item's origin backend (#100), not the live active
        // backend, so a detail that lingered across a switch refreshes from the right server.
        let span = PerformanceInstrumentation.begin(.detailMetadata,
                                                     backend: actionBackend.performanceLabel)
        let result = await DetailMetadataLoader.load(ratingKey: requestedRatingKey,
                                                     backend: actionBackend,
                                                     appModel: appModel)
        guard activeVersionRatingKey == requestedRatingKey, !Task.isCancelled else { return }
        guard let full = result.item else {
            span.end(result: "failure", fields: ["error": result.errorLabel ?? "metadata_unavailable"])
            return
        }
        detailed = full
        // The fresh payload may have a different number of media entries; clamp the
        // selection and drop any stale optimistic watched override now that we have
        // an authoritative value from the server.
        if selectedMediaIndex >= (full.media?.count ?? 1) {
            selectedMediaIndex = 0
        }
        watchedOverride = nil
        span.end(fields: ["media_count": full.media?.count ?? 0])
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
