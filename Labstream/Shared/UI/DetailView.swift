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
    @Environment(\.metadataRepository) private var metadataRepository
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloadManager
    #endif
    @Environment(MusicPlayerController.self) private var musicPlayer
    #if os(iOS)
    /// Keeps regular-width iPhone landscape out of the phone composition (`MobileDetailLayoutPolicy`).
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Book hinge for the side-by-side composition (the one shell pose source).
    @Environment(\.duoPose) private var duoPose
    #endif
    /// True in ANY iOS compact-width context (iPhone, a folded iPhone Duo, a narrow iPad
    /// window). Coarse sizing such as page padding keys on this; the composition itself comes
    /// from `resolvedDetailLayoutMode`. Always false on visionOS, so its metrics stay untouched.
    @Environment(\.labstreamCompactWidth) private var compactWidth
    #if os(visionOS)
    @Environment(WatchTogetherCoordinator.self) private var watchTogetherCoordinator
    /// The browse tab this detail lives under, injected by RootView, so Cinema exit returns to the
    /// originating tab's detail instead of always Home (#87). `nil` → fall back to the system-entry
    /// (Home) path, preserving prior behavior.
    @Environment(\.cinemaOriginTab) private var cinemaOriginTab
    #endif
    #if os(macOS)
    /// Root-level macOS presenter. When available, playback is lifted out of the split-view detail
    /// so it owns the whole main window surface instead of leaving the browse sidebar visible.
    @Environment(\.macPlayerPresentationStore) private var macPlayerPresenter
    #endif

    @State private var detailed: MediaItem
    /// Provenance for the current hydrated detail. Only an exact-current, unpatched native read
    /// may satisfy immediate Play without another authoritative metadata request.
    @State private var detailedMetadataSnapshot: MetadataSnapshot?
    @State private var presentingPlayer = false
    #if !os(tvOS)
    @State private var localPlaybackRequest: LocalPlaybackRequest?
    #endif
    @State private var remotePlayback: MediaBrowserRemotePlayback?
    #if !os(tvOS)
    @State private var showDownloadOptions = false
    @State private var downloadOptionsItem: MediaItem?
    @State private var isPreparingDownloadOptions = false
    #endif
    @State private var playbackErrorMessage: String?
    @State private var isResolvingPlayback = false
    @State private var isTogglingWatched = false
    #if os(visionOS)
    @State private var isPreparingWatchTogether = false
    #endif
    @State private var metadataLoadingRatingKey: String?
    @State private var playbackRequestID: UUID?
    #if os(iOS)
    @State private var mobilePlayerOrientationCoordinator = MobilePlayerOrientationCoordinator()
    #endif
    /// Measured size of the detail scroll container (iOS only; stays zero elsewhere). The
    /// detail composition follows it so a resize or an iPhone Duo fold/unfold re-derives the
    /// layout from the space actually available rather than from the device idiom.
    @State private var detailViewportSize: CGSize = .zero
    #if os(iOS)
    /// The scroll content's global frame: the content region the rails, the side-by-side
    /// placement and the book hinge conversion use.
    @State private var detailContentRegion: CGRect = .zero
    /// Whether the hero title is on screen; the navigation title appears once it is not.
    @State private var heroTitleVisible = true
    /// First visible section, kept across a phone → stacked → side-by-side flip.
    @State private var detailScrollAnchor: String?
    /// "More Like This" (movies only).
    @State private var similarItems: [MediaItem] = []
    #endif
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
    /// Rating key that owns `watchedOverride`. A collapsed-version selection can change while a
    /// mutation is in flight; the old version's optimism must never paint the newly selected one.
    @State private var watchedOverrideItemID: String?
    #if os(macOS)
    @State private var macPlayerPresentationOwnerID = UUID()
    #endif

    /// Playable trailers/extras for the "Trailers & Extras" shelf (#199). Plex delivers
    /// them inline on the metadata payload (`includeExtras=1` → `relatedItems`);
    /// Jellyfin/Emby fetch them when the full item's capability hints
    /// (`relatedAvailability`) say any exist. Empty → the shelf is simply absent.
    @State private var relatedShelf: [MediaItem] = []

    init(item: MediaItem, originBackend: MediaBackendKind? = nil) {
        self.item = item
        self.originBackend = originBackend
        _detailed = State(initialValue: item)
        _detailedMetadataSnapshot = State(initialValue: nil)
    }

    /// Backend that Play / watched / download must act against (#100): the item's origin
    /// backend when known, resolved through the pure `PlaybackBackendResolver` so the rule
    /// ("origin always wins over the current active backend") is unit-testable. Falls back
    /// to the live active backend when no origin was captured.
    private var actionBackend: MediaBackendKind {
        guard let originBackend else { return appModel.activeBackend }
        return PlaybackBackendResolver.backend(forItemOrigin: originBackend,
                                               currentActive: appModel.activeBackend)
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

    /// Poster + metadata arrangement. visionOS and macOS keep the canonical side-by-side HStack
    /// and tvOS its own composition. iPhone/iPad pick from the measured viewport
    /// (`MobileDetailLayoutPolicy`, iPhone Duo design spec, Movie detail): phone, stacked or side
    /// by side, each followed by the same full-width rails.
    @ViewBuilder
    private var detailLayout: some View {
        #if os(tvOS)
        tvDetailLayout
        #elseif os(iOS)
        mobileDetailContent
        #else
        HStack(alignment: .top, spacing: DS.Space.xxxl) {
            posterHero
            metadataColumn
            Spacer(minLength: 0)
        }
        #endif
    }

    #if os(tvOS)
    /// Television detail is deliberately its own composition rather than a magnified iPad
    /// metadata stack. Keep the poster stable on the leading edge, bound the readable text
    /// measure, and establish one predictable vertical path through identity, actions,
    /// playback facts, synopsis, and credits.
    private var tvDetailLayout: some View {
        HStack(alignment: .top, spacing: 56) {
            detailPoster(width: 280)

            tvMetadataColumn
                .frame(maxWidth: 1_180, alignment: .leading)

            Spacer(minLength: 0)
        }
    }

    private var tvMetadataColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            DetailTitleHeader(item: detailed, showItem: showItem)

            if let tagline = detailed.tagline, !tagline.isEmpty {
                Text(tagline)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .italic()
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DetailMetadataRow(year: detailed.year,
                              runtimeMinutes: runtimeMinutes,
                              contentRating: detailed.contentRating,
                              rating: detailed.rating,
                              criticRating: detailed.criticRating,
                              isWatched: isWatched)

            if let genres = detailed.genres, !genres.isEmpty {
                Text(genres.map(\.tag).joined(separator: " · "))
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            actionButtons

            if let media = selectedMedia {
                DetailMediaInfoSummary(specBadges: mediaSpecBadges(media),
                                       chapterCount: detailed.chapters?.count)
            }

            if let summary = detailed.summary, !summary.isEmpty {
                Text(summary)
                    .font(.body)
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DetailCreditsSection(roles: detailed.roles,
                                 directors: detailed.directors,
                                 studios: detailed.studios)
        }
    }
    #endif

    #if os(iOS)
    // MARK: - iPhone/iPad composition (iPhone Duo design spec, Movie detail)

    /// The composition from the measured scroll viewport; `nil` until the first measurement,
    /// while the page draws nothing so no size-class fallback flashes for a frame.
    private var resolvedDetailLayoutMode: MobileDetailLayoutPolicy.Mode? {
        MobileDetailLayoutPolicy.resolvedMode(viewportWidth: Double(detailViewportSize.width),
                                              viewportHeight: Double(detailViewportSize.height),
                                              horizontallyCompact: horizontalSizeClass == .compact)
    }

    private var mobilePagePadding: CGFloat { DS.pagePadding(compact: compactWidth) }

    /// Readable cap for the metadata text column (global rule 10).
    private static let readableTextWidth: CGFloat = 640

    /// Poster width in the side-by-side composition.
    private static let sideBySidePosterWidth: CGFloat = 220

    /// Key art for the full-width band: backend landscape art first, else the poster cropped
    /// into the band, else the placeholder.
    private var keyArtPath: String? {
        switch MobileDetailArtworkPolicy.selection(art: detailed.art, thumb: detailed.thumb) {
        case .landscape(let path), .croppedPoster(let path): path
        case .none: nil
        }
    }

    /// Sections of the page, in the same order in every pose; each carries a stable scroll id so
    /// the reading position survives a phone → stacked → side-by-side flip.
    @ViewBuilder
    private var mobileDetailContent: some View {
        if let mode = resolvedDetailLayoutMode {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    switch mode {
                    case .phone:
                        mobilePhoneHeader
                    case .stacked:
                        mobileStackedHeader
                    case .sideBySide:
                        mobileSideBySideHeader
                    }
                }
                .id("detail.header")

                if let roles = detailed.roles, !roles.isEmpty {
                    DetailCastRail(roles: roles)
                        .padding(.top, DS.Space.xxl)
                        .id("detail.cast")
                }
                if !similarItems.isEmpty {
                    DetailMoreLikeThisRail(items: similarItems)
                        .padding(.top, DS.Space.xxl)
                        .id("detail.similar")
                }
                if !relatedShelf.isEmpty {
                    DetailRelatedMediaShelf(items: relatedShelf,
                                            isBusy: isResolvingPlayback || presentingPlayer,
                                            onPlay: playRelated)
                        .padding(.top, DS.Space.xxl)
                        .id("detail.extras")
                }
            }
            .padding(.bottom, DS.Space.xxxl)
            .scrollTargetLayout()
        } else {
            Color.clear.frame(maxWidth: .infinity, minHeight: 1)
        }
    }

    /// Folded portrait and landscape: full-width 16:9 key art (capped at 40% of the viewport
    /// height), then the metadata in the content region.
    private var mobilePhoneHeader: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            DetailKeyArtBand(path: keyArtPath,
                             height: CGFloat(MobileDetailLayoutPolicy.artworkHeight(
                                viewportWidth: Double(detailContentRegion.width > 0
                                                      ? detailContentRegion.width
                                                      : detailViewportSize.width),
                                viewportHeight: Double(detailViewportSize.height)) ?? 0))
            mobileMetadataBlock
                .padding(.horizontal, mobilePagePadding)
        }
    }

    /// Unfolded upright: a 220-pt key-art hero above the metadata, capped at the readable width
    /// and centred in the content region.
    private var mobileStackedHeader: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            DetailKeyArtBand(path: keyArtPath,
                             height: CGFloat(MobileDetailLayoutPolicy.stackedHeroHeight))
            mobileMetadataBlock
                .frame(maxWidth: Self.readableTextWidth, alignment: .leading)
                .padding(.horizontal, mobilePagePadding)
                .frame(maxWidth: .infinity)
        }
    }

    /// Unfolded sideways: the poster leading and the metadata trailing, ending one margin before
    /// the content edge. In book the poster centres in the leading half and the metadata starts
    /// after the hinge, so the gap sits on the fold.
    private var mobileSideBySideHeader: some View {
        let placement = MobileDetailLayoutPolicy.sideBySidePlacement(
            contentWidth: Double(detailContentRegion.width),
            posterWidth: Double(Self.sideBySidePosterWidth),
            margin: Double(mobilePagePadding),
            gap: Double(DS.Space.xxl),
            hinge: detailHinge)
        let posterLeading = CGFloat(placement.posterLeading)
        let metadataLeading = CGFloat(placement.metadataLeading)
        let metadataWidth = max(min(Self.readableTextWidth,
                                    detailContentRegion.width - metadataLeading - mobilePagePadding), 0)
        return HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: posterLeading, height: 1)
            detailPoster(width: Self.sideBySidePosterWidth)
            Color.clear.frame(width: max(metadataLeading - posterLeading - Self.sideBySidePosterWidth, 0),
                              height: 1)
            mobileMetadataBlock
                .frame(width: metadataWidth, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.top, DS.Space.xl)
    }

    /// A book hinge in the content region's horizontal space, from the one pose source.
    private var detailHinge: (minX: Double, maxX: Double)? {
        guard case .book(let rect) = duoPose, detailContentRegion.width > 0 else { return nil }
        return (Double(rect.minX - detailContentRegion.minX), Double(rect.maxX - detailContentRegion.minX))
    }

    /// Title (once), context line, actions, time left, overview and credits. The navigation
    /// title stays hidden until this hero title scrolls away.
    private var mobileMetadataBlock: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DetailTitleHeader(item: detailed, showItem: showItem)
                .onScrollVisibilityChange(threshold: 0.01) { visible in
                    heroTitleVisible = visible
                }

            DetailContextLine(parts: mobileContextParts)

            mobileActionRow
                .padding(.top, DS.Space.xs)

            if let left = MediaDetailCaptions.timeLeft(for: detailed) {
                Text(left)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let playbackErrorMessage {
                Text(playbackErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            DetailMovieVersionPicker(versions: movieVersions,
                                     activeVersionRatingKey: activeVersionRatingKey,
                                     selectedVersionRatingKey: $selectedVersionRatingKey,
                                     resolvedLabels: movieVersionLabels)

            DetailMediaVersionPicker(media: detailed.media,
                                     selectedMediaIndex: $selectedMediaIndex)

            if let summary = detailed.summary, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, DS.Space.xs)
            }

            if let genres = detailed.genres, !genres.isEmpty {
                Text(genres.map(\.tag).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // Cast has its own rail below; directors and studios stay as caption lines.
            DetailCreditsSection(roles: nil,
                                 directors: detailed.directors,
                                 studios: detailed.studios)

            if let media = selectedMedia {
                DetailMediaInfoSummary(specBadges: mediaSpecBadges(media),
                                       chapterCount: detailed.chapters?.count)
            }
        }
    }

    /// year · runtime · content rating · audience rating, dropped from the end to fit one line.
    private var mobileContextParts: [String] {
        var parts = MediaDetailCaptions.movieContext(detailed)
        if let rating = detailed.rating, rating > 0 {
            parts.append("★ " + String(format: "%.1f", rating))
        }
        return parts
    }

    /// One prominent label-on-glass Resume/Play capsule, then Download and Mark Watched as glass
    /// circles with accessibility titles.
    private var mobileActionRow: some View {
        HStack(spacing: DS.Space.md) {
            playButton
                .controlSize(.large)
            if PlatformFeaturePolicy.supportsDownloads {
                downloadCircleButton
            }
            if supportsWatchedToggle {
                markWatchedCircleButton
            }
        }
    }

    @ViewBuilder
    private var downloadCircleButton: some View {
        if let identity = Self.offlinePlaybackIdentity(ratingKey: downloadRecordKey, manager: downloadManager) {
            Button {
                musicPlayer.pauseForVideo()
                remotePlayback = nil
                playingItem = nil
                presentingPlayer = false
                // Capture rendered authority before orientation; admission runs after it.
                let request = downloadManager.offlinePlaybackLaunchFactory.beginPresentationRequest()
                Task { await presentLocalPlayer(identity, request: request) }
            } label: {
                DetailCircleActionLabel(title: "Play Offline", systemImage: "arrow.down.circle.fill")
            }
            .detailCircleActionStyle(title: "Play Offline")
        } else {
            Button {
                guard !isPreparingDownloadOptions else { return }
                isPreparingDownloadOptions = true
                Task { await prepareDownloadOptions() }
            } label: {
                DetailCircleActionLabel(title: downloadLabel,
                                        systemImage: isDownloading ? "arrow.down.circle.dotted" : "arrow.down",
                                        isBusy: isPreparingDownloadOptions)
            }
            .detailCircleActionStyle(title: downloadLabel)
            .disabled(isDownloading || isPreparingDownloadOptions || !metadataReadyForActions)
        }
    }

    private var markWatchedCircleButton: some View {
        let title = isWatched ? "Mark Unwatched" : "Mark Watched"
        return Button {
            guard !isTogglingWatched else { return }
            isTogglingWatched = true
            Task { await toggleWatched() }
        } label: {
            DetailCircleActionLabel(title: title,
                                    systemImage: isWatched ? "checkmark.circle.fill" : "checkmark")
        }
        .detailCircleActionStyle(title: title)
        .disabled(isTogglingWatched || !metadataReadyForActions)
    }

    /// "More Like This" for movies; episodes keep their show's hierarchy instead.
    private func loadSimilarItems() async {
        guard detailed.kind == .movie else { similarItems = []; return }
        let key = detailed.ratingKey
        let items = await DetailRelatedContentLoader.similar(to: detailed, backend: actionBackend,
                                                             appModel: appModel)
        guard detailed.ratingKey == key, !Task.isCancelled else { return }
        similarItems = items
    }
    #endif

    /// Horizontal inset for the Trailers & Extras shelf (#199) so its content edge lines up
    /// with the hero above — compact-width on iPhone/narrow iPad, the wide page inset elsewhere.
    private var relatedShelfHorizontalPadding: CGFloat {
        DS.Space.xxxl
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
        #if os(tvOS)
        // The page already owns the title in its hero. A tvOS navigation title places a second,
        // dimmed title over the content and can collide with the tagline/metadata while focused.
        .toolbar(.hidden, for: .navigationBar)
        #elseif os(iOS)
        // The hero title is the page's one title; the bar shows it only once it scrolls away.
        .navigationTitle(heroTitleVisible ? "" : detailed.title)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .navigationTitle(detailed.title)
        #endif
        // Re-fetch when the chosen movie version changes (#108) as well as on first appear;
        // `activeVersionRatingKey` defaults to `item.ratingKey`, so single-version items run
        // exactly once as before. The autoplay token is one-shot, so a later version switch
        // can't re-trigger it.
        .task(id: activeVersionRatingKey) {
            #if DEBUG
            if DebugUIFixtureCatalog.isBrowseEnabled { return }
            #endif
            let autoPlay = SystemEntryRouter.shared.consumeAutoPlay(for: activeVersionRatingKey)
            if let handoff = autoPlay?.snapshot,
               metadataRepository?.mayAuthorizeAction(handoff,
                                                       appModel: appModel,
                                                       backend: actionBackend,
                                                       itemID: activeVersionRatingKey) == true {
                // Route-key system entry already performed this exact native Detail read. Preserve
                // its one-shot provenance rather than degrading it to generic display-cache reuse.
                applyHydratedMetadata(handoff.item, snapshot: handoff)
            } else {
                await refreshMetadata()
            }
            // System-entry autoplay (#24): a "Play …" intent armed the router right
            // before pushing this view; after accepting its native handoff or finishing ordinary
            // hydration, present the player through the same admission path as the Play button.
            if autoPlay != nil,
               !detailed.isMusic {
                isResolvingPlayback = true
                let requestID = UUID()
                playbackRequestID = requestID
                await startPlayback(requestID: requestID)
            }
            await loadRelatedMedia()
            #if os(iOS)
            await loadSimilarItems()
            #endif
        }
        // Resolve the collapsed versions' resolution/codec labels for the chooser (#108).
        // Keyed on `item.ratingKey` (the versions come from `item`, which is stable for this
        // detail), so it runs once and never blocks the rest of the screen. No-op for items
        // with a single version.
        .task(id: item.ratingKey) {
            #if DEBUG
            if DebugUIFixtureCatalog.isBrowseEnabled { return }
            #endif
            await resolveMovieVersionLabels()
        }
        #if os(macOS)
        .sheet(isPresented: $showDownloadOptions) {
            DownloadOptionsSheet(item: downloadOptionsItem ?? detailed,
                                 mediaIndex: selectedMediaIndex,
                                 backend: actionBackend)
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
        #if !os(tvOS)
        .fullScreenCover(item: $localPlaybackRequest) { request in
            // CustomPlayerView owns its iOS safe-area policy (#258); see the modifier.
            localPlayerView(for: request)
                .customPlayerPresentationSafeArea()
        }
        #endif
        .fullScreenCover(isPresented: $presentingPlayer) {
            playerCover
        }
        #if !os(tvOS)
        .sheet(isPresented: $showDownloadOptions) {
            DownloadOptionsSheet(item: downloadOptionsItem ?? detailed,
                                 mediaIndex: selectedMediaIndex,
                                 backend: actionBackend)
        }
        #endif
        #endif
    }

    private var leafDetailScroll: some View {
        ScrollView {
            #if os(iOS)
            // The rails and the side-by-side placement measure the content region (the scroll
            // content's own frame, which excludes the vertical bar's inset on either edge).
            // Only the horizontal extent is observed: the global minY/maxY move with every
            // scroll offset, and re-evaluating the page body per scroll frame is wasted work.
            detailLayout
                .onGeometryChange(for: CGRect.self) { proxy in
                    let frame = proxy.frame(in: .global)
                    return CGRect(x: frame.minX, y: 0, width: frame.width, height: 0)
                } action: { region in
                    if detailContentRegion != region { detailContentRegion = region }
                }
            #else
            VStack(alignment: .leading, spacing: 0) {
                #if os(tvOS)
                detailLayout
                    .padding(.horizontal, 96)
                    .padding(.vertical, 64)
                #else
                detailLayout
                    .padding(DS.Space.xxxl)
                #endif
                if !relatedShelf.isEmpty {
                    DetailRelatedMediaShelf(items: relatedShelf,
                                            isBusy: isResolvingPlayback || presentingPlayer,
                                            onPlay: playRelated)
                        .padding(.horizontal, relatedShelfHorizontalPadding)
                        .padding(.bottom, DS.Space.xxxl)
                }
            }
            #endif
        }
        #if os(iOS)
        .scrollPosition(id: $detailScrollAnchor, anchor: .top)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            detailViewportSize = size
        }
        #endif
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
                                   contentID: macPlayerContentID,
                                   onClose: {
                                       presentingPlayer = false
                                       localPlaybackRequest = nil
                                   }) {
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

    #if !os(tvOS)
    @ViewBuilder
    private func localPlayerView(for request: LocalPlaybackRequest) -> some View {
        Self.makeLocalPlayer(request: request, onClose: { localPlaybackRequest = nil })
        #if os(iOS)
        .withMobileOrientationCoordinator(mobilePlayerOrientationCoordinator)
        #endif
        #if os(visionOS)
        .withCinemaOrigin(.offline(ratingKey: request.launch.attemptKey.ratingKey))
        #endif
    }

    /// Production local player assembly; no SwiftUI environment is needed to exercise callbacks.
    static func makeLocalPlayer(request: LocalPlaybackRequest,
                                trickPlayProvider: (any TrickPlayThumbnailProviding)? = nil,
                                onClose: @escaping () -> Void) -> CustomPlayerView {
        CustomPlayerView(offlineLaunch: request.launch, trickPlayProvider: trickPlayProvider, onClose: onClose)
    }
    #endif

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
                        PosterImage(path: art, width: 900, height: 600, cornerRadius: 0, requestScale: 1.0,
                                    showsLoadingShimmer: false)
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

            #if os(visionOS)
            watchTogetherStatus
            #endif
        }
    }

    #if os(visionOS)
    @ViewBuilder
    private var watchTogetherButton: some View {
        Button {
            guard !isPreparingWatchTogether else { return }
            isPreparingWatchTogether = true
            Task { await prepareWatchTogether() }
        } label: {
            Label("Watch Together", systemImage: "shareplay")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, DS.Space.md)
                .padding(.vertical, DS.Space.xs)
        }
        .buttonStyle(.bordered)
        .disabled(isResolvingPlayback
                  || isPreparingWatchTogether
                  || !metadataReadyForActions
                  || !watchTogetherCoordinator.canRequestWatchTogether
                  || detailed.sharePlayMediaIdentity?.coordinatorIdentifier == nil)
    }

    /// SharePlay matching is an action, not presentation. Resolve the same exact-current native
    /// item used by Play/Download before handing anything to the coordinator.
    private func prepareWatchTogether() async {
        defer { isPreparingWatchTogether = false }
        guard let action = await authoritativeItemForAction(),
              !Task.isCancelled,
              metadataReadyForActions,
              watchTogetherCoordinator.canRequestWatchTogether else { return }
        await watchTogetherCoordinator.requestWatchTogether(for: action.item)
    }

    @ViewBuilder
    private var watchTogetherStatus: some View {
        let stateApplies = watchTogetherCoordinator.stateApplies(to: detailed)
        switch watchTogetherCoordinator.state {
        case .inactive:
            EmptyView()
        case .resolving:
            if stateApplies {
                Label("Preparing Watch Together…", systemImage: "shareplay")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .selectionRequired:
            if stateApplies {
                Label("Choose the matching item in the SharePlay sheet.", systemImage: "questionmark.video")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        case .ready:
            if stateApplies {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    Label("\(watchTogetherCoordinator.readyParticipantCount) ready · \(watchTogetherCoordinator.resolvingParticipantCount) resolving",
                          systemImage: "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(.green)
                    if watchTogetherCoordinator.isLocalInitiator {
                        HStack(spacing: DS.Space.sm) {
                            Button(watchTogetherCoordinator.requiresStartAcknowledgement
                                   ? "Start with ready participants" : "Start Watching") {
                                watchTogetherCoordinator.startWithReadyParticipants(
                                    acknowledgeUnresolved: watchTogetherCoordinator.requiresStartAcknowledgement)
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Cancel Watch Together", role: .cancel) {
                                watchTogetherCoordinator.leave()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        case .active:
            if stateApplies {
                HStack(spacing: DS.Space.sm) {
                    Label("Watch Together active · \(watchTogetherCoordinator.readyParticipantCount) ready",
                          systemImage: "shareplay")
                        .font(.callout)
                        .foregroundStyle(.green)
                    Button("Leave") { watchTogetherCoordinator.leave() }
                        .buttonStyle(.bordered)
                }
            }
        case .unavailable(_, let reason):
            if stateApplies {
                Label(reason.userMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }
    #endif

    @ViewBuilder
    private var actionButtonStack: some View {
        #if os(tvOS)
        HStack(spacing: DS.Space.lg) {
            playButton
            if supportsWatchedToggle {
                markWatchedButton
            }
        }
        .controlSize(.regular)
        #else
        if compactWidth {
            // Full-width stacked buttons with CENTERED labels — the system idiom for a
            // prominent full-width action (App Store "Get", TV "Play"); a left-aligned
            // label in a full-width pill reads as a list row. The width stretch lives on
            // each button's label so the glass pill itself spans the column.
            VStack(spacing: DS.Space.md) {
                playButton
                if PlatformFeaturePolicy.supportsDownloads {
                    downloadButton
                }
                #if os(visionOS)
                watchTogetherButton
                #endif
                if supportsWatchedToggle {
                    markWatchedButton
                }
            }
            .controlSize(.large)
        } else {
            HStack(spacing: DS.Space.lg) {
                playButton
                if PlatformFeaturePolicy.supportsDownloads {
                    downloadButton
                }
                #if os(visionOS)
                watchTogetherButton
                #endif
                if supportsWatchedToggle {
                    markWatchedButton
                }
            }
        }
        #endif
    }

    private var playButton: some View {
        Button {
            guard !isResolvingPlayback, !presentingPlayer, metadataReadyForActions else { return }
            isResolvingPlayback = true
            let requestID = UUID()
            playbackRequestID = requestID
            Task { await startPlayback(requestID: requestID) }
        } label: {
            ZStack {
                // Keep the native button's intrinsic geometry stable while playback resolves.
                // Replacing the full label with a bare spinner collapsed the focused tvOS
                // control and made the adjacent watched action jump into its place.
                Label(resumeLabel, systemImage: "play.fill")
                    .opacity(isResolvingPlayback ? 0 : 1)

                if isResolvingPlayback {
                    ProgressView()
                }
            }
            .font(detailActionFont.weight(.semibold))
            #if os(iOS)
            .padding(.horizontal, DS.Space.sm)
            #else
            .frame(maxWidth: compactWidth ? .infinity : nil)
            #endif
        }
        .labstreamGlassProminentButtonStyle()
        #if os(tvOS)
        // Disabling the focused action during resolution forces the focus engine onto the
        // watched button before the player appears. The action guard above already rejects
        // repeat presses, so retain focus until presentation completes.
        .disabled(!metadataReadyForActions)
        #else
        .disabled(isResolvingPlayback || !metadataReadyForActions)
        #endif
    }

    /// "Play Offline" when a local copy exists, otherwise a button that opens the
    /// `DownloadOptionsSheet` (quality picker) with a live progress label mid-transfer.
    #if !os(tvOS)
    @ViewBuilder
    private var downloadButton: some View {
        if let identity = Self.offlinePlaybackIdentity(ratingKey: downloadRecordKey, manager: downloadManager) {
            Button {
                musicPlayer.pauseForVideo()
                remotePlayback = nil
                playingItem = nil
                presentingPlayer = false
                // Capture rendered authority before orientation; admission runs after it.
                let request = downloadManager.offlinePlaybackLaunchFactory.beginPresentationRequest()
                Task { await presentLocalPlayer(identity, request: request) }
            } label: {
                Label("Play Offline", systemImage: "arrow.down.circle.fill")
                    .font(detailActionFont)
                    .frame(maxWidth: compactWidth ? .infinity : nil)
            }
            .labstreamGlassButtonStyle()
        } else {
            Button {
                guard !isPreparingDownloadOptions else { return }
                isPreparingDownloadOptions = true
                Task { await prepareDownloadOptions() }
            } label: {
                ZStack {
                    Label(downloadLabel, systemImage: "arrow.down.circle")
                        .opacity(isPreparingDownloadOptions ? 0 : 1)
                    if isPreparingDownloadOptions { ProgressView() }
                }
                .font(detailActionFont)
                .frame(maxWidth: compactWidth ? .infinity : nil)
            }
            .labstreamGlassButtonStyle()
            .disabled(isDownloading || isPreparingDownloadOptions || !metadataReadyForActions)
        }
    }
    #endif

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
                .font(detailActionFont)
                .frame(maxWidth: compactWidth ? .infinity : nil)
        }
        .labstreamGlassButtonStyle()
        .disabled(isTogglingWatched || !metadataReadyForActions)
    }

    private var detailActionFont: Font {
        #if os(tvOS)
        .body
        #elseif os(iOS)
        // iPhone/iPad buttons use the Body style (three text styles).
        .subheadline
        #else
        .title3
        #endif
    }

    /// Fetch each collapsed version's brief metadata concurrently to build resolution/codec
    /// labels for the chooser (#108, finding 5). Grid items lack `MediaSources`, so without
    /// this every entry would read "Version N". Bounded to `movieVersions` (2–3 items) — a
    /// failure for one version simply leaves its label as the "Version N" fallback.
    @MainActor
    private func resolveMovieVersionLabels() async {
        let versions = movieVersions
        guard versions.count > 1 else { return }
        // Capture the values the fetch needs as locals so the children don't capture `self`
        // (a non-Sendable View) across the task boundary. `appModel` is a @MainActor model.
        let backend = actionBackend
        let model = appModel
        // Start every fetch before awaiting any: the children are main-actor tasks, but each
        // suspends on its network round trip, so the round trips overlap. Unstructured tasks
        // are used because the region-based isolation checker rejects a `@MainActor` task
        // group child returning a tuple; cancellation is forwarded explicitly.
        let fetches = versions.map(\.ratingKey).map { ratingKey in
            (ratingKey, Task {
                await Self.fetchVersionLabel(ratingKey: ratingKey, backend: backend, appModel: model)
            })
        }
        await withTaskCancellationHandler {
            for (ratingKey, fetch) in fetches {
                if let label = await fetch.value, !label.isEmpty {
                    movieVersionLabels[ratingKey] = label
                }
            }
        } onCancel: {
            fetches.forEach { $0.1.cancel() }
        }
    }

    /// Resolve one version's resolution/codec label from its full metadata's first `Media`.
    /// Returns nil on any failure or when no tech specs are available, so the caller keeps the
    /// "Version N" fallback for that entry. Static + explicitly-passed dependencies so the
    /// concurrent fetch tasks never capture the `DetailView` value.
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
            guard let service = try? PlexBrowseService(appModel: appModel) else { return nil }
            full = try? await service.metadata(ratingKey: ratingKey)
        }
        guard let media = full?.media?.first else { return nil }
        let label = MediaVersionLabel.versionLabel(for: media)
        return label == "Version" ? nil : label
    }

    #if os(visionOS)
    /// Origin for an ONLINE (streamed) playback launched from this detail: the originating browse
    /// tab when known, else the system-entry (Home) fallback (#87).
    private var onlineCinemaOrigin: CinemaOrigin {
        CinemaAppRouting.onlineOrigin(for: cinemaOriginTab)
    }
    #endif

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
                                 onClose: { presentingPlayer = false })
                    #if os(iOS)
                    .withMobileOrientationCoordinator(mobilePlayerOrientationCoordinator)
                    #endif
                    #if os(visionOS)
                    .withCinemaOrigin(onlineCinemaOrigin)
                    #endif
                    .id(remote.id)
                    .customPlayerPresentationSafeArea()
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
                                 trickPlayProvider: EmbyTrickPlayThumbnailProvider(
                                    item: playing,
                                    mediaSourceId: remote.mediaSourceId,
                                    server: appModel.embyServerBaseURL,
                                    token: appModel.embyAccessToken,
                                    identity: appModel.identity.emby,
                                    userId: appModel.embyUserID),
                                 onClose: { presentingPlayer = false })
                    #if os(iOS)
                    .withMobileOrientationCoordinator(mobilePlayerOrientationCoordinator)
                    #endif
                    #if os(visionOS)
                    .withCinemaOrigin(onlineCinemaOrigin)
                    #endif
                    .id(remote.id)
                    .customPlayerPresentationSafeArea()
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
                                                        sessionSource: .plex(PlexPlaybackSession(
                                                            server: server,
                                                            token: token,
                                                            machineIdentifier: machineIdentifier)),
                                                        identity: appModel.identity,
                                                        client: appModel.client,
                                                        maxVideoBitrateKbps: activeMaxVideoBitrateKbps,
                                                        qualityDefaultsKey: appModel.activeStreamingQualityDefaultsKey,
                                                        mediaIndex: mediaIndex)
                                 },
                                 trickPlayProvider: PlexBIFTrickPlayThumbnailProvider(item: playing,
                                                                                      mediaIndex: mediaIndex,
                                                                                      server: server,
                                                                                      token: token,
                                                                                      identity: appModel.identity),
                                 onClose: { presentingPlayer = false },
                                 onRequestPlay: playNext)
                    #if os(iOS)
                    .withMobileOrientationCoordinator(mobilePlayerOrientationCoordinator)
                    #endif
                    #if os(visionOS)
                    .withCinemaOrigin(onlineCinemaOrigin)
                    #endif
            }
            // Rebuild the player + its PlaybackController cleanly whenever the playing
            // item changes (Up Next advance), so the outgoing controller is dismantled
            // (its `stop()` flushes a final timeline) and a fresh one starts the next.
            .id(playing.ratingKey)
            .customPlayerPresentationSafeArea()
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
        let previousOverride = watchedOverride
        let previousOverrideItemID = watchedOverrideItemID
        guard let action = await authoritativeItemForAction() else {
            return
        }
        // The server-native state, not a stale or cache-painted presentation value, decides the
        // mutation direction. Apply optimism only after that native admission has completed.
        let targetPlayed = (action.item.viewCount ?? 0) == 0
        let mutationBackend = actionBackend
        let mutationItemID = action.item.ratingKey
        let expectedDetailVersionID = activeVersionRatingKey
        guard let mutationContext = appModel.authenticatedBrowseSession(for: mutationBackend) else {
            return
        }
        let mutationTarget = DetailWatchedMutationTarget(
            backend: mutationBackend,
            authority: mutationContext.authority,
            itemID: mutationItemID,
            detailVersionID: expectedDetailVersionID)
        watchedOverride = targetPlayed
        watchedOverrideItemID = mutationItemID

        do {
            try await DetailWatchedUpdater.setPlayed(item: action.item,
                                                     backend: mutationBackend,
                                                     appModel: appModel,
                                                     played: targetPlayed)
            let currentAuthority = appModel
                .authenticatedBrowseSession(for: mutationBackend)?.authority
            if currentAuthority == mutationTarget.authority {
                // Cache truth follows the exact item sent to the server even if the user selected
                // another collapsed movie version while this request was in flight.
                try? metadataRepository?.patchWatchedState(
                    appModel: appModel,
                    backend: mutationTarget.backend,
                    authority: mutationTarget.authority,
                    itemID: mutationTarget.itemID,
                    played: targetPlayed)
                // Mounted state is narrower: never apply version A's completion to version B.
                if mutationTarget.isStillMounted(
                    backend: actionBackend,
                    authority: appModel.authenticatedBrowseSession(for: actionBackend)?.authority,
                    activeVersionID: activeVersionRatingKey,
                    detailedItemID: detailed.ratingKey),
                   detailedMetadataSnapshot?.backend == mutationTarget.backend,
                   detailedMetadataSnapshot?.authority == mutationTarget.authority,
                   detailedMetadataSnapshot?.item.ratingKey == mutationTarget.itemID {
                    detailedMetadataSnapshot = detailedMetadataSnapshot?
                        .patchingWatchedState(played: targetPlayed)
                }
            }
        } catch {
            // Roll back the optimistic flip; the server rejected the change.
            watchedOverride = previousOverride
            watchedOverrideItemID = previousOverrideItemID
        }
    }

    #if !os(tvOS)
    /// Display-cache values may render the sheet button but cannot supply download negotiation.
    /// Resolve an exact-current native value before presenting the existing direct planner.
    private func prepareDownloadOptions() async {
        defer { isPreparingDownloadOptions = false }
        downloadOptionsItem = nil
        guard let action = await authoritativeItemForAction(),
              !Task.isCancelled,
              metadataReadyForActions else { return }
        downloadOptionsItem = action.item
        showDownloadOptions = true
    }
    #endif

    private typealias AuthoritativeActionItem = (item: MediaItem, snapshot: MetadataSnapshot?)

    /// Return the current native Detail value or perform one authoritative metadata read. This
    /// admission gate is shared by Play, Download, and watched mutation, while their existing
    /// context-fenced launcher/planner/mutator paths retain ownership of each action.
    private func authoritativeItemForAction(itemID: String? = nil) async
        -> AuthoritativeActionItem? {
        let expectedBackend = actionBackend
        let expectedDetailID = activeVersionRatingKey
        let expectedItemID = itemID ?? expectedDetailID
        if expectedItemID == expectedDetailID,
           let detailedMetadataSnapshot,
           metadataRepository?.mayAuthorizeAction(detailedMetadataSnapshot,
                                                   appModel: appModel,
                                                   backend: expectedBackend,
                                                   itemID: expectedItemID)
            ?? detailedMetadataSnapshot.mayAuthorizeAction(in: appModel,
                                                           backend: expectedBackend,
                                                           itemID: expectedItemID) {
            return (detailedMetadataSnapshot.item, detailedMetadataSnapshot)
        }

        let authority = appModel.authenticatedBrowseSession(for: expectedBackend)?.authority
        let result = await DetailMetadataLoader.load(ratingKey: expectedItemID,
                                                     backend: expectedBackend,
                                                     appModel: appModel,
                                                     repository: metadataRepository,
                                                     policy: .authoritative)
        guard !Task.isCancelled,
              actionBackend == expectedBackend,
              activeVersionRatingKey == expectedDetailID,
              appModel.authenticatedBrowseSession(for: expectedBackend)?.authority == authority,
              let item = result.item else { return nil }
        // Shipping RootView always injects the repository, so this is a native provenance value.
        // The nil-snapshot path is retained only for isolated previews/fixtures and is still fenced
        // by the exact authority captured above.
        if let snapshot = result.snapshot {
            guard metadataRepository?.mayAuthorizeAction(snapshot,
                                                         appModel: appModel,
                                                         backend: expectedBackend,
                                                         itemID: expectedItemID)
                ?? snapshot.mayAuthorizeAction(in: appModel,
                                               backend: expectedBackend,
                                               itemID: expectedItemID) else { return nil }
            if expectedItemID == expectedDetailID {
                detailed = item
                detailedMetadataSnapshot = snapshot
                if selectedMediaIndex >= (item.media?.count ?? 1) {
                    selectedMediaIndex = 0
                }
            }
        }
        return (item, result.snapshot)
    }

    private var metadataReadyForActions: Bool {
        metadataLoadingRatingKey == nil && detailed.ratingKey == activeVersionRatingKey
    }

    /// Resolve and present playback. `target` defaults to the page's own item (`detailed`);
    /// a Trailers & Extras shelf passes its extra/trailer leaf instead (#199), reusing the
    /// same per-backend launch path while the page's metadata stays untouched.
    private func startPlayback(requestID: UUID, target: MediaItem? = nil) async {
        defer {
            if playbackRequestID == requestID {
                isResolvingPlayback = false
                playbackRequestID = nil
            }
        }
        guard playbackRequestID == requestID, metadataReadyForActions, !presentingPlayer else { return }
        let displayedSubject = target ?? detailed
        // Defense-in-depth (#15): music is filtered from browse, but never let a music item
        // launch the video player. Unreachable in normal flow.
        guard !displayedSubject.isMusic else { return }
        // Presentation cache can paint this page, but it cannot select stream metadata. Reuse the
        // initial native Detail read when it is still exact-current; otherwise perform one native
        // authority-fenced read before any backend's playback path proceeds.
        guard let action = await authoritativeItemForAction(itemID: displayedSubject.ratingKey),
              playbackRequestID == requestID,
              metadataReadyForActions,
              !presentingPlayer else { return }
        let subject = action.item
        let launchRatingKey = subject.ratingKey
        // The page must still show the same item when an async resolve lands; comparing
        // against the page key (not the launch target) keeps the guard meaningful for
        // shelf extras too.
        let launchDetailKey = detailed.ratingKey
        let launchBackend = actionBackend
        // A shelf extra owns its own media list and must not inherit the parent page's
        // selected version index. The page-selection freshness guard is likewise only
        // relevant when launching the page item itself.
        let launchUsesPageMediaSelection = target == nil
        let launchMediaIndex = launchUsesPageMediaSelection ? selectedMediaIndex : 0
        let span = PerformanceInstrumentation.begin(.playbackResolve,
                                                     backend: actionBackend.performanceLabel,
                                                     fields: [
                                                        "resume": subject.viewOffset ?? 0,
                                                        "quality_kbps": activeMaxVideoBitrateKbps,
                                                     ])
        playbackErrorMessage = nil
        musicPlayer.pauseForVideo()
        playingItem = DetailPlaybackLauncher.itemWithResumeRewind(subject, resumeRewindSeconds: resumeRewindSeconds)
        switch launchBackend {
        case .plex:
            remotePlayback = nil
            await presentResolvedPlayer()
            span.end(fields: ["path_mode": "plex_stream"])
        case .jellyfin, .emby:
            remotePlayback = nil
            var openContext: MediaBrowserPlaybackContext?
            do {
                // Capture credentials before the metadata await so both requests belong to one
                // immutable auth generation. An auth/detail switch while metadata is held rejects
                // the request before PlaybackInfo can create a stale encoder.
                let capturedContext = try DetailPlaybackLauncher.context(
                    backend: launchBackend, appModel: appModel)
                openContext = capturedContext
                let playbackItem = await DetailPlaybackLauncher.metadataItem(
                    ratingKey: launchRatingKey,
                    fallback: subject,
                    trustedDetailSnapshot: action.snapshot,
                    metadataRepository: metadataRepository,
                    context: capturedContext,
                    appModel: appModel,
                    resumeRewindSeconds: resumeRewindSeconds)
                let metadataRequestStillCurrent = playbackRequestID == requestID
                    && metadataReadyForActions
                    && actionBackend == launchBackend
                    && detailed.ratingKey == launchDetailKey
                    && (!launchUsesPageMediaSelection || selectedMediaIndex == launchMediaIndex)
                guard DetailPlaybackLauncher.shouldContinueAfterMetadata(
                    requestStillCurrent: metadataRequestStillCurrent,
                    context: capturedContext,
                    appModel: appModel) else {
                    span.end(result: "cancelled", fields: ["reason": "stale_metadata"])
                    return
                }
                playingItem = playbackItem
                let opened = try await DetailPlaybackLauncher.open(
                    item: playbackItem,
                    context: capturedContext,
                    appModel: appModel,
                    mediaIndex: launchMediaIndex,
                    maxVideoBitrateKbps: activeMaxVideoBitrateKbps)
                let requestStillCurrent = playbackRequestID == requestID
                    && metadataReadyForActions
                    && actionBackend == launchBackend
                    && detailed.ratingKey == launchDetailKey
                    && (!launchUsesPageMediaSelection || selectedMediaIndex == launchMediaIndex)
                let accepted = await DetailPlaybackLauncher.acceptInitialOpen(
                    opened,
                    requestStillCurrent: requestStillCurrent,
                    appModel: appModel,
                    cleanup: { remote in
                        await DetailPlaybackLauncher.stopActiveEncodingNow(
                            remote: remote, appModel: appModel)
                    })
                guard accepted else {
                    // PlaybackInfo may have created a live encoder before the detail/auth context
                    // changed. The stale result cannot be presented, but it still owns that exact
                    // remote and must tear it down with the credentials that minted it.
                    span.end(result: "cancelled", fields: ["reason": "stale_open_success"])
                    return
                }
                remotePlayback = opened.playback
                await presentResolvedPlayer()
                span.end(fields: [
                    "path_mode": "remote_stream",
                    "play_method": opened.playMethod,
                ])
            } catch {
                let requestStillCurrent = playbackRequestID == requestID
                    && metadataReadyForActions
                    && actionBackend == launchBackend
                    && detailed.ratingKey == launchDetailKey
                    && (!launchUsesPageMediaSelection || selectedMediaIndex == launchMediaIndex)
                guard DetailPlaybackLauncher.shouldSurfaceOpenFailure(
                    requestStillCurrent: requestStillCurrent,
                    context: openContext,
                    appModel: appModel) else {
                    // A failure from an abandoned/auth-switched request is not the current
                    // detail's failure. End its instrumentation without replacing current UI.
                    span.end(result: "cancelled", fields: ["reason": "stale_open_failure"])
                    return
                }
                span.end(result: "failure", fields: [
                    "error": PerformanceInstrumentation.errorLabel(error)
                ])
                let failure = PlaybackFailure.classify(error)
                AppDiagnostics.record(.playback, "playback.open_failed", fields: [
                    "failure_code": .label(failure.code.rawValue),
                    "http_status": .int(failure.httpStatus ?? 0),
                    "backend_decision": .int(failure.backendDecision ?? 0),
                ])
                playbackErrorMessage = failure.message
            }
        }
    }

    @MainActor
    private func presentResolvedPlayer() async {
        #if os(iOS)
        await mobilePlayerOrientationCoordinator.enterLandscapeBeforePresentationIfNeeded()
        #endif
        presentingPlayer = true
    }

    #if !os(tvOS)
    @MainActor
    private func presentLocalPlayer(_ identity: OfflineDownloadRowActionIdentity,
                                    request: OfflinePlaybackPresentationRequest) async {
        await Self.presentLocalRequest(identity, manager: downloadManager, request: request,
            resumeRewindSeconds: resumeRewindSeconds, orientation: {
            #if os(iOS)
            await mobilePlayerOrientationCoordinator.enterLandscapeBeforePresentationIfNeeded()
            #endif
        }, restoreOrientation: {
            #if os(iOS)
            mobilePlayerOrientationCoordinator.restoreIfNeeded()
            #endif
        }, present: { localPlaybackRequest = $0 })
    }

    /// Final exact-attempt admission is deliberately after the orientation suspension.
    @MainActor
    static func presentLocalRequest(_ identity: OfflineDownloadRowActionIdentity,
                                    manager: DownloadManager,
                                    request: OfflinePlaybackPresentationRequest,
                                    resumeRewindSeconds: Int = 0,
                                    orientation: () async -> Void,
                                    restoreOrientation: () -> Void = {},
                                    present: (LocalPlaybackRequest) -> Void) async {
        guard case .success(let launch) = await manager.offlinePlaybackLaunchFactory.makeLaunchAfterOrientation(
            for: identity, request: request, resumeRewindSeconds: resumeRewindSeconds,
            orientation: orientation, restoreOrientation: restoreOrientation,
            isCurrent: { manager.offlinePresentationGeneration == request.generation }) else { return }
        present(LocalPlaybackRequest(launch: launch))
    }
    #endif

    // MARK: - Derived state

    private var activeMaxVideoBitrateKbps: Int {
        // Touch the @AppStorage properties so SwiftUI invalidates this view when either cap
        // changes, then resolve through AppModel's connection-aware scope helper.
        _ = homeMaxVideoBitrateKbps
        _ = remoteMaxVideoBitrateKbps
        return appModel.activeStreamingQualityKbps
    }

    #if !os(tvOS)
    struct LocalPlaybackRequest: Identifiable {
        let id = UUID()
        let launch: OfflinePlaybackLaunch
        init(launch: OfflinePlaybackLaunch) { self.launch = launch }
    }
    #endif

    #if !os(tvOS)
    private var downloadRecordKey: String {
        DownloadRecordIdentity.recordKey(for: detailed.ratingKey, backend: actionBackend)
    }

    /// Rendering uses only the published row. File admission belongs to the factory after
    /// orientation; a missing file must not perform disk I/O during SwiftUI body evaluation.
    static func offlinePlaybackIdentity(ratingKey: String, manager: DownloadManager) -> OfflineDownloadRowActionIdentity? {
        guard let row = manager.records.first(where: { $0.ratingKey == ratingKey && $0.isComplete }),
              let attemptID = row.attemptID else { return nil }
        return .init(ratingKey: ratingKey, attemptID: attemptID)
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
    #endif

    private var isWatched: Bool {
        if watchedOverrideItemID == detailed.ratingKey,
           let override = watchedOverride {
            return override
        }
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
        let requestedBackend = actionBackend
        detailedMetadataSnapshot = nil
        metadataLoadingRatingKey = requestedRatingKey
        defer {
            if metadataLoadingRatingKey == requestedRatingKey {
                metadataLoadingRatingKey = nil
            }
        }
        // Resolve metadata against the item's origin backend (#100), not the live active
        // backend, so a detail that lingered across a switch refreshes from the right server.
        let span = PerformanceInstrumentation.begin(.detailMetadata,
                                                     backend: requestedBackend.performanceLabel)
        let result = await DetailMetadataLoader.load(ratingKey: requestedRatingKey,
                                                     backend: requestedBackend,
                                                     appModel: appModel,
                                                     repository: metadataRepository,
                                                     policy: .display)
        guard activeVersionRatingKey == requestedRatingKey,
              actionBackend == requestedBackend,
              !Task.isCancelled else {
            span.end(result: Task.isCancelled ? "cancelled" : "superseded")
            return
        }
        guard let full = result.item else {
            span.end(result: "failure", fields: ["error": result.errorLabel ?? "metadata_unavailable"])
            return
        }
        applyHydratedMetadata(full, snapshot: result.snapshot)

        guard result.snapshot?.provenance.delivery == .staleWhileRevalidate else {
            span.end(fields: ["media_count": full.media?.count ?? 0])
            return
        }

        // SWR is visible, not merely a warm-cache side effect: paint the bounded stale value,
        // then join the repository-owned exact refresh and replace it when that native read lands.
        // `metadataLoadingRatingKey` remains set throughout, so the stale paint cannot admit an
        // action even before provenance is consulted.
        let refreshed = await DetailMetadataLoader.load(ratingKey: requestedRatingKey,
                                                        backend: requestedBackend,
                                                        appModel: appModel,
                                                        repository: metadataRepository,
                                                        policy: .authoritative)
        guard activeVersionRatingKey == requestedRatingKey,
              actionBackend == requestedBackend,
              !Task.isCancelled else {
            span.end(result: Task.isCancelled ? "cancelled" : "superseded")
            return
        }
        guard let refreshedItem = refreshed.item else {
            span.end(result: "stale", fields: ["media_count": full.media?.count ?? 0])
            return
        }
        applyHydratedMetadata(refreshedItem, snapshot: refreshed.snapshot)
        span.end(fields: ["media_count": refreshedItem.media?.count ?? 0,
                          "swr_refresh": 1])
    }

    private func applyHydratedMetadata(_ item: MediaItem, snapshot: MetadataSnapshot?) {
        detailed = item
        detailedMetadataSnapshot = snapshot
        // The hydrated payload may have a different number of media entries; clamp the
        // selection and drop the prior optimistic override. Repository provenance separately
        // decides whether this value may authorize an action.
        if selectedMediaIndex >= (item.media?.count ?? 1) {
            selectedMediaIndex = 0
        }
        watchedOverride = nil
        watchedOverrideItemID = nil
    }

    // MARK: - Trailers & Extras shelf (#199)

    /// Populate the shelf for the CURRENT `detailed` item. Plex is free (extras arrive
    /// inline with the metadata refresh); Jellyfin/Emby fetch only when the full item's
    /// capability hints say related media exists, so most detail opens cost no extra
    /// requests. Failures/unsupported backends degrade to an absent shelf.
    private func loadRelatedMedia() async {
        let key = detailed.ratingKey
        switch actionBackend {
        case .plex:
            relatedShelf = detailed.relatedItems ?? []
        case .jellyfin:
            guard shouldFetchRelatedMedia else { relatedShelf = []; return }
            let items = await JellyfinBrowseService(appModel: appModel).relatedMedia(itemId: key)
            guard detailed.ratingKey == key, !Task.isCancelled else { return }
            relatedShelf = items
        case .emby:
            guard shouldFetchRelatedMedia else { relatedShelf = []; return }
            let items = await EmbyBrowseService(appModel: appModel).relatedMedia(itemId: key)
            guard detailed.ratingKey == key, !Task.isCancelled else { return }
            relatedShelf = items
        }
    }

    private var shouldFetchRelatedMedia: Bool {
        guard let availability = detailed.relatedAvailability else { return false }
        return availability.hasLocalTrailers
            || availability.hasSpecialFeatures
            || !availability.extraIds.isEmpty
    }

    /// Direct playback of a shelf extra/trailer: same request/guard lifecycle as the
    /// primary Play button, but launched for the extra's own leaf item.
    private func playRelated(_ extra: MediaItem) {
        guard !isResolvingPlayback, !presentingPlayer, metadataReadyForActions else { return }
        isResolvingPlayback = true
        let requestID = UUID()
        playbackRequestID = requestID
        Task { await startPlayback(requestID: requestID, target: extra) }
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
