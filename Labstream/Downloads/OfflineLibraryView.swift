import SwiftUI
import PMSKit
import UIKit

/// Lists offline downloads with live progress + delete, and plays a completed
/// file through the custom player (`CustomPlayerView(localFile:item:)`).
///
/// Surfaces the offline-transfer reality (research/10): background transfers may be
/// deferred while the app is backgrounded or the device is locked/asleep, then resume
/// when the app or system transfer daemon is allowed to run again.
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

        // No NavigationStack here: RootView already wraps the Offline tab in one on every
        // platform, so opening a second stack nested large-title collapse and toolbar merging.
        // The navigationTitle/toolbar below attach to this content and merge into the outer stack.
        ScrollViewReader { scrollProxy in
            Group {
                if snapshot.rows.isEmpty {
                    ContentUnavailableView(
                        "No Offline Downloads",
                        systemImage: "arrow.down.circle",
                        description: Text("Download a movie or episode to watch it offline. "
                                          + "Transfers may pause while the app is backgrounded or the device sleeps.")
                    )
                } else {
                    List {
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
                offlineToolbar(snapshot: snapshot)
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

    /// The Offline toolbar. On iOS 26 bare toolbar items get Liquid Glass (and adjacent items
    /// share one glass background) automatically, so the metrics + queue action ride a plain
    /// `ToolbarItemGroup` with no hand-rolled material. visionOS keeps the custom capsule cluster.
    @ToolbarContentBuilder
    private func offlineToolbar(snapshot: OfflineLibrarySnapshot) -> some ToolbarContent {
        if snapshot.aggregateStats.hasVisibleMetrics || snapshot.queueToolbarAction != nil {
            #if os(iOS)
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let speed = snapshot.aggregateStats.activeSpeedBytesPerSecond, speed > 0 {
                    aggregateToolbarMetric(value: "\(Self.aggregateByteString(Int(speed)))/s",
                                           systemImage: "speedometer",
                                           accessibilityLabel: "Active download speed")
                }
                if snapshot.aggregateStats.downloadedBytes > 0 {
                    aggregateToolbarMetric(value: Self.aggregateByteString(snapshot.aggregateStats.downloadedBytes),
                                           systemImage: "externaldrive.fill",
                                           accessibilityLabel: "Downloaded data")
                }
                if let queueToolbarAction = snapshot.queueToolbarAction {
                    queueToolbarButton(queueToolbarAction)
                }
            }
            #else
            ToolbarItem(placement: .topBarTrailing) {
                offlineToolbarCluster(snapshot: snapshot)
            }
            #endif
        }
    }

    #if os(visionOS)
    private func offlineToolbarCluster(snapshot: OfflineLibrarySnapshot) -> some View {
        HStack(spacing: 8) {
            if let speed = snapshot.aggregateStats.activeSpeedBytesPerSecond, speed > 0 {
                aggregateToolbarMetric(value: "\(Self.aggregateByteString(Int(speed)))/s",
                                       systemImage: "speedometer",
                                       accessibilityLabel: "Active download speed")
            }
            if snapshot.aggregateStats.downloadedBytes > 0 {
                aggregateToolbarMetric(value: Self.aggregateByteString(snapshot.aggregateStats.downloadedBytes),
                                       systemImage: "externaldrive.fill",
                                       accessibilityLabel: "Downloaded data")
            }
            if snapshot.aggregateStats.hasVisibleMetrics, snapshot.queueToolbarAction != nil {
                Divider()
                    .frame(height: 18)
                    .accessibilityHidden(true)
            }
            if let queueToolbarAction = snapshot.queueToolbarAction {
                queueToolbarButton(queueToolbarAction)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(.primary.opacity(0.16), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .contain)
    }
    #endif

    private func aggregateToolbarMetric(value: String,
                                        systemImage: String,
                                        accessibilityLabel: String) -> some View {
        Label {
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
        } icon: {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(value)
    }

    private func queueToolbarButton(_ action: DownloadQueueToolbarPolicy.Action) -> some View {
        Button {
            switch action {
            case .pauseQueue:
                manager.pauseQueue()
            case .resumeQueue:
                manager.resumeQueue()
            }
        } label: {
            Label(action.title, systemImage: action.systemImage)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.title)
    }

    private static func aggregateByteString(_ bytes: Int) -> String {
        DownloadStorageLimitPolicy.byteString(bytes)
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
        let isCheckpointPausing = rowSnapshot.isCheckpointPausing
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
                if let bitrate = downloadBitrateText(for: record) {
                    Text(bitrate)
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
                } else if isCheckpointPausing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Pausing at checkpoint")
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

    private func downloadBitrateText(for record: DownloadRecord) -> String? {
        DownloadRowDisplayPolicy.downloadBitrateText(kbps: record.metadata?.downloadBitrateKbps,
                                                     requestedProfileLabel: record.metadata?.requestedProfileLabel)
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
