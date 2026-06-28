import SwiftUI
import PMSKit
import UIKit

/// Lists offline downloads with live progress + delete, and plays a completed
/// file through the custom player (`CustomPlayerView(localFile:item:)`).
///
/// Surfaces the offline-transfer reality (research/10): background transfers on
/// visionOS pause while the headset is off and resume when it's worn again, so an
/// in-progress download may appear "stuck" until the user puts the headset back on.
public struct OfflineLibraryView: View {
    @Environment(MusicPlayerController.self) private var musicPlayer
    @State private var manager: DownloadManager
    @State private var playing: DownloadRecord?
    @Binding private var focusedRatingKey: String?
    @State private var highlightedRatingKey: String?

    public init(manager: DownloadManager, focusedRatingKey: Binding<String?> = .constant(nil)) {
        _manager = State(initialValue: manager)
        _focusedRatingKey = focusedRatingKey
    }

    public var body: some View {
        let snapshot = manager.offlineLibrarySnapshot

        NavigationStack {
            ScrollViewReader { scrollProxy in
                Group {
                    if snapshot.rows.isEmpty {
                        ContentUnavailableView(
                            "No Offline Downloads",
                            systemImage: "arrow.down.circle",
                            description: Text("Download a movie or episode to watch it offline. "
                                              + "Transfers pause while the headset is off and resume when it's worn again.")
                        )
                    } else {
                        List {
                            if snapshot.aggregateStats.hasVisibleMetrics {
                                SwiftUI.Section {
                                    aggregateSummary(for: snapshot.aggregateStats)
                                }
                            }
                            SwiftUI.Section {
                                ForEach(snapshot.rows) { rowSnapshot in
                                    row(for: rowSnapshot)
                                        .id(rowSnapshot.id)
                                }
                                .onDelete { offsets in
                                    for index in offsets {
                                        manager.delete(ratingKey: snapshot.rows[index].id)
                                    }
                                }
                            } footer: {
                                Text(snapshot.footerText)
                            }
                        }
                    }
                }
                .navigationTitle("Offline")
                .toolbar {
                    if let queueToolbarAction = snapshot.queueToolbarAction {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                switch queueToolbarAction {
                                case .pauseQueue:
                                    manager.pauseQueue()
                                case .resumeQueue:
                                    manager.resumeQueue()
                                }
                            } label: {
                                Label(queueToolbarAction.title,
                                      systemImage: queueToolbarAction.systemImage)
                            }
                        }
                    }
                }
                .task(id: focusedRatingKey) {
                    await focusRequestedDownload(using: scrollProxy)
                }
                .onChange(of: snapshot.ratingKeys) { _, _ in
                    Task { @MainActor in
                        await focusRequestedDownload(using: scrollProxy)
                    }
                }
            }
        }
        .fullScreenCover(item: $playing) { record in
            CustomPlayerView(localFile: record.localURL,
                             item: offlineItem(from: record),
                             trickPlayProvider: localTrickPlayProvider(for: record),
                             offlineTextSubtitles: record.metadata?.offlineTextSubtitles ?? [],
                             offlineChapterImageURLs: record.chapterImageURLs,
                             cinemaOrigin: .offline(ratingKey: record.ratingKey),
                             onLocalPlaybackProgress: { positionMs, durationMs in
                                 manager.updateLocalPlaybackPosition(ratingKey: record.ratingKey,
                                                                     positionMs: positionMs,
                                                                     durationMs: durationMs)
                             },
                             onClose: { playing = nil })
        }
    }

    fileprivate static let rowActionControlSize: CGFloat = 56

    private func aggregateSummary(for stats: OfflineDownloadAggregateStats) -> some View {
        HStack(spacing: 12) {
            if let speed = stats.activeSpeedBytesPerSecond, speed > 0 {
                aggregateMetric(title: "Active speed",
                                value: "\(Self.aggregateByteString(Int(speed)))/s",
                                systemImage: "speedometer")
            }
            if stats.downloadedBytes > 0 {
                aggregateMetric(title: "Downloaded",
                                value: Self.aggregateByteString(stats.downloadedBytes),
                                systemImage: "externaldrive.fill")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func aggregateMetric(title: String, value: String, systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private static func aggregateByteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func localTrickPlayProvider(for record: DownloadRecord) -> (any TrickPlayThumbnailProviding)? {
        // Emby has no scrub-preview tile cache; its offline scrubber is fed by the per-chapter image
        // cache (#89), so prefer the Emby chapter provider when this is an Emby download with images.
        if backendKind(for: record) == .emby,
           let provider = LocalEmbyChapterTrickPlayThumbnailProvider(chapters: record.metadata?.chapters ?? [],
                                                                     imageURLsByChapterIndex: record.chapterImageURLs) {
            return provider
        }
        if let playlist = record.jellyfinTrickPlayPlaylistURL {
            return LocalJellyfinTrickPlayThumbnailProvider(playlistURL: playlist)
        }
        return LocalBIFTrickPlayThumbnailProvider(bifURL: record.plexBIFURL)
    }

    @ViewBuilder
    private func row(for rowSnapshot: OfflineDownloadRowSnapshot) -> some View {
        let record = rowSnapshot.record
        // Drive the row off the explicit, persisted status (D2) instead of inferring
        // completion from `progress >= 1.0` — a stalled job that froze at <100% and a
        // failed-but-100% body are now distinct, observable states.
        let isComplete = record.isComplete
        let isRetrying = rowSnapshot.isRetrying
        let isFailed = record.status == .failed && !isRetrying
        let isUnverified = record.isUnverified
        // #95: a recoverable interruption is resumable, not failed — show a non-red "will resume"
        // affordance and a Resume control that continues from the saved byte offset.
        let isPaused = record.status == .paused

        HStack(spacing: 16) {
            // D5: show the locally-cached poster when present (works fully offline);
            // otherwise fall back to a small offline glyph tile.
            OfflinePosterTile(posterURL: record.posterURL,
                              isComplete: isComplete,
                              isFailed: isFailed,
                              isUnverified: isUnverified)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(displayTitle(for: record)).font(.headline)
                    downloadLaneBadge(for: record)
                    // Only label the backend when the library mixes them, so a
                    // simultaneous Plex + Jellyfin/Emby library (#84) stays legible
                    // and single-backend libraries carry no visual noise.
                    if rowSnapshot.showBackendBadge {
                        backendBadge(name: rowSnapshot.backendName)
                    }
                }
                if let subtitle = subtitle(for: record) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isFailed {
                    // Prefer the surfaced reason; fall back to a generic failed line so
                    // a `.failed` row reconciled at launch (no live error) still explains.
                    Text(rowSnapshot.errorMessage ?? rowSnapshot.statusCaption)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if isRetrying {
                    ProgressView()
                    Text(rowSnapshot.statusCaption)
                        .font(.caption)
                        .monospacedDigit()
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                } else if isPaused {
                    // #95: paused (recoverably interrupted). Show how far it got and that it
                    // resumes, in secondary (not red) — it's not a failure.
                    Text(rowSnapshot.statusCaption)
                        .font(.caption)
                        .monospacedDigit()
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                } else if isComplete {
                    Text(rowSnapshot.statusCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // Unified bar (#97): an exact Content-Length fraction for Plex/static
                    // originals, an estimated fraction for transcoder-streamed JF/Emby rows;
                    // nil only before any bytes flow, when we keep the spinner below.
                    if let progress = rowSnapshot.displayProgress {
                        ProgressView(value: progress)
                            .animation(.linear(duration: 0.2), value: progress)
                        Text(rowSnapshot.statusCaption)
                            .font(.caption)
                            .monospacedDigit()
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                        Text(rowSnapshot.statusCaption)
                            .font(.caption)
                            .monospacedDigit()
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            HStack(spacing: 12) {
                if isComplete {
                    Button {
                        // Music and video share one audio session — yield music
                        // before launching the offline player (#17).
                        musicPlayer.pauseForVideo()
                        playing = record
                    } label: {
                        Image(systemName: "play.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .offlineRowActionControl()
                    .accessibilityLabel("Play offline download")
                } else if isFailed {
                    Button {
                        manager.retry(ratingKey: record.ratingKey)
                    } label: {
                        Image(systemName: "arrow.clockwise.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .offlineRowActionControl()
                } else if isRetrying {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Retrying download")
                } else if isPaused {
                    // #95: Resume continues from the saved byte offset (manager.retry resumes a
                    // `.paused` row from persisted resume data).
                    Button {
                        manager.retry(ratingKey: record.ratingKey)
                    } label: {
                        Image(systemName: "play.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .offlineRowActionControl()
                    .accessibilityLabel("Resume download")
                } else {
                    Button {
                        manager.pause(ratingKey: record.ratingKey)
                    } label: {
                        Image(systemName: "pause.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .offlineRowActionControl()
                    .accessibilityLabel("Pause download")
                }

                // Explicit delete on every row (complete / failed / in-progress). The List's
                // swipe-to-delete still works, but a visible trash control is far more
                // discoverable on visionOS — and lets the user clear a FAILED or no-longer-
                // wanted download directly. `manager.delete` cancels any live task and removes
                // the file + cached poster + record.
                Button {
                    manager.delete(ratingKey: record.ratingKey)
                } label: {
                    Image(systemName: "trash.circle.fill")
                }
                .buttonStyle(.plain)
                .offlineRowActionControl()
                .foregroundStyle(.secondary)
                .accessibilityLabel("Delete download")
            }
        }
        .padding(.vertical, 4)
        .background {
            if highlightedRatingKey == record.ratingKey {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(.tint.opacity(0.16))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: highlightedRatingKey)
        .contentShape(Rectangle())
        .onTapGesture {
            if isComplete {
                musicPlayer.pauseForVideo()
                playing = record
            } else if isFailed || isPaused {
                // #95: tapping a paused row resumes it (manager.retry continues from the offset).
                manager.retry(ratingKey: record.ratingKey)
            }
        }
    }

    @MainActor
    private func focusRequestedDownload(using scrollProxy: ScrollViewProxy) async {
        guard let ratingKey = focusedRatingKey else { return }
        guard manager.offlineLibrarySnapshot.rows.contains(where: { $0.id == ratingKey }) else { return }

        // RootView may set the focus request in the same transaction as switching to the Offline
        // tab after the Cinema window is recreated. Yield once so the list row exists before the
        // scroll, mirroring the proven tab-switch/navigation timing used by RootView.
        await Task.yield()
        withAnimation(.easeInOut(duration: 0.25)) {
            scrollProxy.scrollTo(ratingKey, anchor: .center)
        }
        highlightedRatingKey = ratingKey
        focusedRatingKey = nil

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if highlightedRatingKey == ratingKey {
                highlightedRatingKey = nil
            }
        }
    }

    /// Backend that owns this row, via the single migration fallback on the
    /// persisted snapshot (#84): a stored `backendKind` wins; pre-#84 rows fall
    /// back to the ratingKey prefix. Drives the mixed-backend badge below.
    private func backendKind(for record: DownloadRecord) -> DownloadBackendKind {
        record.metadata?.resolvedBackendKind(ratingKey: record.ratingKey)
            ?? DownloadBackendKind(ratingKeyPrefix: record.ratingKey)
    }

    /// A subtle source chip ("Plex" / "Jellyfin" / "Emby") shown beside the title
    /// when the library mixes backends (#84). Matches the caption typography so it
    /// reads as part of the row rather than a bolted-on control.
    private func backendBadge(name: String) -> some View {
        Text(name)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(.thinMaterial, in: Capsule())
            .accessibilityLabel("Source: \(name)")
    }

    /// Show the download route next to the title so Jellyfin/Emby rows make it clear whether
    /// the server is sending a raw file, a compatible remux, or a live transcode. This is useful
    /// context for resumability and "why is this slower?" without making normal downloads look
    /// like failures.
    private func downloadLaneBadge(for record: DownloadRecord) -> some View {
        let label: String
        let systemImage: String
        let tint: Color
        switch record.metadata?.resolvedDownloadLane() ?? .original {
        case .original where record.metadata?.isServerPreparedVersion == true:
            // A server-prepared (transcoded) version rides the `.original` static lane for resumable
            // byte-for-byte transfer, but it isn't the user's source file — badge it "Transcode"
            // (consistent with on-demand optimize and the prep-phase pill), not "Original".
            label = "Transcode"
            systemImage = "gauge.with.dots.needle.bottom.50percent"
            tint = .orange
        case .original:
            label = "Original"
            systemImage = "checkmark.seal"
            tint = .secondary
        case .compatibleRemux:
            label = "Remux"
            systemImage = "arrow.triangle.2.circlepath"
            tint = .orange
        case .optimize:
            label = "Transcode"
            systemImage = "gauge.with.dots.needle.bottom.50percent"
            tint = .orange
        }
        return Label(label, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption2)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .accessibilityLabel("Download route: \(label)")
    }

    /// Keep downloaded episodes self-identifying and sortable by eye even without the server:
    /// "Show · S1E3 · Episode Title" instead of only the episode title.
    private func displayTitle(for record: DownloadRecord) -> String {
        guard let item = record.metadata?.makeMediaItem(), item.kind == .episode else {
            return record.title
        }
        return item.displaySubtitleLine
    }

    /// A secondary line built from the persisted snapshot (D5): year + runtime +
    /// content rating, when available. Returns nil for rows with no metadata.
    private func subtitle(for record: DownloadRecord) -> String? {
        guard let meta = record.metadata else { return nil }
        var parts: [String] = []
        if let year = meta.year { parts.append(String(year)) }
        if let duration = meta.duration, duration > 0 {
            let minutes = max(1, duration / 60_000)
            parts.append("\(minutes) min")
        }
        if let rating = meta.contentRating, !rating.isEmpty { parts.append(rating) }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    /// Reconstruct a faithful `MediaItem` from the persisted snapshot (D5) so the
    /// offline file flows through the same `CustomPlayerView` path with real title/metadata.
    /// Rows persisted before D5 fall back to a minimal movie.
    private func offlineItem(from record: DownloadRecord) -> MediaItem {
        record.metadata?.makeMediaItem()
            ?? MediaItem(ratingKey: record.ratingKey, title: record.title, type: "movie")
    }

}

/// Locally-cached offline artwork. Loading happens from `.task(id:)` with the disk read off the
/// main actor, not inline in row rendering, so frequent progress refreshes don't repeatedly stat,
/// read, and decode poster files while the user scrolls.
private struct OfflinePosterTile: View {
    let posterURL: URL?
    let isComplete: Bool
    let isFailed: Bool
    let isUnverified: Bool

    @State private var image: UIImage?
    @State private var loadedPosterURL: URL?

    var body: some View {
        Group {
            if loadedPosterURL == posterURL, let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .frame(width: 44, height: 66)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: posterURL) {
            await loadPoster()
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.regularMaterial)
            .overlay {
                Image(systemName: tileGlyph)
                    .font(.title3)
                    .foregroundStyle(isUnverified ? .yellow : (isComplete ? .green : (isFailed ? .red : .secondary)))
            }
    }

    private var tileGlyph: String {
        if isUnverified { return "exclamationmark.circle.fill" }
        if isComplete { return "arrow.down.circle.fill" }
        if isFailed { return "exclamationmark.circle" }
        return "arrow.down.circle"
    }

    @MainActor
    private func loadPoster() async {
        image = nil
        loadedPosterURL = nil
        guard let posterURL else { return }
        if let cached = OfflinePosterImageCache.shared.image(for: posterURL) {
            image = cached
            loadedPosterURL = posterURL
            return
        }

        let decoded = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: posterURL) else { return nil as UIImage? }
            return UIImage(data: data)
        }.value
        guard !Task.isCancelled,
              let decoded else { return }
        OfflinePosterImageCache.shared.insert(decoded, for: posterURL)
        image = decoded
        loadedPosterURL = posterURL
    }
}

@MainActor
private final class OfflinePosterImageCache {
    static let shared = OfflinePosterImageCache()

    private let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 256
        return cache
    }()

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func insert(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}

private struct OfflineRowActionControlModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 34, weight: .semibold))
            .frame(width: OfflineLibraryView.rowActionControlSize,
                   height: OfflineLibraryView.rowActionControlSize)
            .contentShape(Circle())
    }
}

private extension View {
    func offlineRowActionControl() -> some View {
        modifier(OfflineRowActionControlModifier())
    }
}
