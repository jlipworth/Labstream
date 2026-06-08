import SwiftUI
import PlexKit

/// Item detail: artwork, rich metadata, and the primary actions — a real per-item
/// submenu modeled on the official Plex / Emby item pages.
///
/// Action area:
///   • Play / Resume — presents the AVKit `PlayerView` (streams the chosen version).
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

    @State private var detailed: MediaItem
    @State private var presentingPlayer = false
    @State private var playLocalURL: URL?
    @State private var showDownloadOptions = false

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

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: DS.Space.xxxl) {
                PosterImage(path: detailed.thumb,
                            width: DS.Poster.detailWidth,
                            height: DS.Poster.height(for: DS.Poster.detailWidth),
                            cornerRadius: DS.Radius.card)
                    .shadow(color: .black.opacity(0.4), radius: 24, x: 0, y: 16)

                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    Text(detailed.title)
                        .font(.largeTitle.bold())

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
            DownloadOptionsSheet(item: detailed)
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
                    playLocalURL = nil
                    presentingPlayer = true
                } label: {
                    Label(resumeLabel, systemImage: "play.fill")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, DS.Space.md)
                        .padding(.vertical, DS.Space.xs)
                }
                .buttonStyle(.borderedProminent)

                downloadButton

                markWatchedButton
            }

            versionPicker
        }
    }

    /// "Play Offline" when a local copy exists, otherwise a button that opens the
    /// `DownloadOptionsSheet` (quality picker) with a live progress label mid-transfer.
    @ViewBuilder
    private var downloadButton: some View {
        if let local = localURL {
            Button {
                playLocalURL = local
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
        if let token = appModel.token, let server = appModel.serverBaseURL {
            // Rely on the native AVPlayerViewController controls for dismissal. The old
            // custom xmark overlay floated on top of the transport bar / "…" menu and
            // collided with the native controls ("buttons behind buttons"); the system
            // player already provides a close affordance in the visionOS cinema chrome,
            // so the redundant overlay is removed.
            Group {
                if let local = playLocalURL {
                    PlayerView(localFile: local, item: detailed)
                } else {
                    PlayerView(item: detailed,
                               server: server,
                               token: token,
                               identity: appModel.identity,
                               client: appModel.client,
                               mediaIndex: selectedMediaIndex)
                }
            }
            .ignoresSafeArea()
        } else {
            ContentUnavailableView("Can’t play",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text("No active server session."))
        }
    }

    // MARK: - Watched toggle

    /// Scrobble / unscrobble against PMS, updating the local watched state optimistically.
    ///
    /// We flip `watchedOverride` first so the UI reacts immediately, then fire the
    /// request. On failure we roll the override back. NOTE: never logs the token — the
    /// builders carry it internally and we only ever inspect the `Bool` outcome here.
    private func toggleWatched() async {
        guard let server = appModel.serverBaseURL, let token = appModel.token else { return }
        let wasWatched = isWatched
        // Optimistic flip.
        watchedOverride = !wasWatched

        let req = wasWatched
            ? TimelineRequest.unscrobble(server: server, token: token,
                                         identity: appModel.identity,
                                         ratingKey: detailed.ratingKey)
            : TimelineRequest.scrobble(server: server, token: token,
                                       identity: appModel.identity,
                                       ratingKey: detailed.ratingKey)

        do {
            _ = try await appModel.client.send(req)
        } catch {
            // Roll back the optimistic flip; PMS rejected the change.
            watchedOverride = wasWatched
        }
    }

    // MARK: - Derived state

    private var localURL: URL? {
        downloadManager.localURL(for: detailed.ratingKey)
    }

    private var isDownloading: Bool {
        downloadManager.records.contains { $0.ratingKey == detailed.ratingKey && $0.progress < 1.0 }
    }

    private var downloadLabel: String {
        if let rec = downloadManager.records.first(where: { $0.ratingKey == detailed.ratingKey }),
           rec.progress < 1.0 {
            return "Downloading \(Int(rec.progress * 100))%"
        }
        return "Download"
    }

    private var isWatched: Bool {
        if let override = watchedOverride { return override }
        return (detailed.viewCount ?? 0) > 0
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
        guard let server = appModel.serverBaseURL, let token = appModel.token else { return }
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

/// Safe-index helper used by the version picker / media-info summary so a stale index
/// (after a metadata refresh swaps the versions) can never trap.
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
