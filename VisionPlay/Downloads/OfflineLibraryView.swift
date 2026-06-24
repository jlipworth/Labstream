import SwiftUI
import PMSKit

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
        NavigationStack {
            ScrollViewReader { scrollProxy in
                Group {
                    if manager.records.isEmpty {
                        ContentUnavailableView(
                            "No Offline Downloads",
                            systemImage: "arrow.down.circle",
                            description: Text("Download a movie or episode to watch it offline. "
                                              + "Transfers pause while the headset is off and resume when it's worn again.")
                        )
                    } else {
                        List {
                            // Resolve the mixed-backend test ONCE per render (it scans every record);
                            // passing it into each row avoids re-scanning the whole list per row (#84).
                            let mixedBackends = hasMixedBackends
                            SwiftUI.Section {
                                ForEach(manager.records) { record in
                                    row(for: record, showBackendBadge: mixedBackends)
                                        .id(record.ratingKey)
                                }
                                .onDelete { offsets in
                                    for index in offsets {
                                        manager.delete(ratingKey: manager.records[index].ratingKey)
                                    }
                                }
                            } footer: {
                                Text("Background transfers pause while the headset is off "
                                     + "and resume when it's worn again.")
                            }
                        }
                    }
                }
                .navigationTitle("Offline")
                .task(id: focusedRatingKey) {
                    await focusRequestedDownload(using: scrollProxy)
                }
                .onChange(of: manager.records.map(\.ratingKey)) { _, _ in
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
                             onClose: { playing = nil })
        }
    }

    fileprivate static let rowActionControlSize: CGFloat = 56

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
    private func row(for record: DownloadRecord, showBackendBadge: Bool) -> some View {
        // Drive the row off the explicit, persisted status (D2) instead of inferring
        // completion from `progress >= 1.0` — a stalled job that froze at <100% and a
        // failed-but-100% body are now distinct, observable states.
        let isComplete = record.isComplete
        let isFailed = record.status == .failed
        let isUnverified = record.isUnverified
        // #95: a recoverable interruption is resumable, not failed — show a non-red "will resume"
        // affordance and a Resume control that continues from the saved byte offset.
        let isPaused = record.status == .paused
        let error = manager.lastError[record.ratingKey]

        HStack(spacing: 16) {
            // D5: show the locally-cached poster when present (works fully offline);
            // otherwise fall back to a small offline glyph tile.
            offlinePoster(for: record, isComplete: isComplete, isFailed: isFailed, isUnverified: isUnverified)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(displayTitle(for: record)).font(.headline)
                    downloadLaneBadge(for: record)
                    // Only label the backend when the library mixes them, so a
                    // simultaneous Plex + Jellyfin/Emby library (#84) stays legible
                    // and single-backend libraries carry no visual noise.
                    if showBackendBadge {
                        backendBadge(for: record)
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
                    Text(error.map(message(for:)) ?? "Download failed. Tap to retry.")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if isPaused {
                    // #95: paused (recoverably interrupted). Show how far it got and that it
                    // resumes, in secondary (not red) — it's not a failure.
                    Text(pausedCaption(for: record))
                        .font(.caption)
                        .monospacedDigit()
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                } else if isComplete {
                    Text(completeCaption(for: record))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // Unified bar (#97): an exact Content-Length fraction for Plex/static
                    // originals, an estimated fraction for transcoder-streamed JF/Emby rows;
                    // nil only before any bytes flow, when we keep the spinner below.
                    if let progress = displayProgress(for: record) {
                        ProgressView(value: progress)
                            .animation(.linear(duration: 0.2), value: progress)
                        Text(progressCaption(for: record))
                            .font(.caption)
                            .monospacedDigit()
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                        Text(progressCaption(for: record))
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
                    ProgressView()
                        .frame(width: Self.rowActionControlSize, height: Self.rowActionControlSize)
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
        guard manager.records.contains(where: { $0.ratingKey == ratingKey }) else { return }

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

    /// Only worth labelling rows by backend when the library actually mixes them —
    /// a single-backend library needs no badge (keeps the list visually quiet).
    private var hasMixedBackends: Bool {
        Set(manager.records.map { backendKind(for: $0) }).count > 1
    }

    private func tileGlyph(isComplete: Bool, isFailed: Bool, isUnverified: Bool) -> String {
        if isUnverified { return "exclamationmark.circle.fill" }
        if isComplete { return "arrow.down.circle.fill" }
        if isFailed { return "exclamationmark.circle" }
        return "arrow.down.circle"
    }

    /// A subtle source chip ("Plex" / "Jellyfin" / "Emby") shown beside the title
    /// when the library mixes backends (#84). Matches the caption typography so it
    /// reads as part of the row rather than a bolted-on control.
    private func backendBadge(for record: DownloadRecord) -> some View {
        let name = backendKind(for: record).displayName
        return Text(name)
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

    /// The locally-cached poster (D5) when present, else the neutral glyph tile.
    @ViewBuilder
    private func offlinePoster(for record: DownloadRecord, isComplete: Bool, isFailed: Bool, isUnverified: Bool) -> some View {
        if let posterURL = record.posterURL,
           let data = try? Data(contentsOf: posterURL),
           let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
                .frame(width: 44, height: 66)
                .overlay {
                    Image(systemName: tileGlyph(isComplete: isComplete, isFailed: isFailed, isUnverified: isUnverified))
                        .font(.title3)
                        .foregroundStyle(isUnverified ? .yellow : (isComplete ? .green : (isFailed ? .red : .secondary)))
                }
        }
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

    private func message(for error: DownloadManager.DownloadError) -> String {
        switch error {
        case .notAuthenticated:        return "Sign in to download."
        case .optimizeFailed(let m):   return "Optimize failed: \(m)"
        case .optimizeTimedOut:        return "Optimize timed out on the server."
        case .noOptimizedPart:         return "No optimized version was produced."
        case .storageFull:             return "Not enough free space."
        case .storageLimitExceeded(let m): return m
        case .transferFailed(let m):   return "Download failed: \(m)"
        case .invalidDownload(let m):  return "Download invalid: \(m)"
        case .interruptedResumable:    return "Download paused — tap Resume to continue."
        }
    }

    /// #95: caption for a paused (recoverably-interrupted) row: how far it got + that it resumes.
    private func pausedCaption(for record: DownloadRecord) -> String {
        var pieces = ["Paused — tap to resume"]
        if let f = manager.displayFraction(for: record) {
            let pct = "\(Int(f.value * 100))%"
            pieces.append(f.isEstimated ? "~\(pct)" : pct)
        }
        if record.bytes > 0 { pieces.append(byteString(record.bytes)) }
        return pieces.joined(separator: " • ")
    }

    private func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// The downloaded file's resolution label, if captured (offline-download redesign).
    private func resolutionLabel(for record: DownloadRecord) -> String? {
        record.metadata?.resolutionLabel
    }

    /// Progress fraction for the bar. Unified across backends (#97): Plex/static-original
    /// downloads use the exact server-reported Content-Length fraction; Jellyfin/Emby
    /// transcoded downloads (no Content-Length) use the estimated bytes/duration×bitrate
    /// fraction so they show a MOVING determinate bar instead of a bare spinner. `nil` only
    /// when neither is available yet, in which case the caller keeps the spinner.
    private func displayProgress(for record: DownloadRecord) -> Double? {
        manager.displayFraction(for: record)?.value
    }

    /// Caption under the in-progress bar, e.g. "23% • 106.5 MB • 12 MB/s • 1080p".
    /// Each piece is included only when known. Speed comes from the smoothed EMA in
    /// `DownloadManager.refreshRecords` (kept — orthogonal jitter fix). The percentage is
    /// read from the same unified `displayFraction` source the bar uses (#97), so the
    /// caption owns its own lookup rather than threading a second progress value through.
    private func progressCaption(for record: DownloadRecord) -> String {
        let isActive = manager.activeJobs.contains(record.ratingKey)
        if record.bytes == 0 {
            // Phase 1 — server-side optimize/transcode (the rendered file can't download
            // until this finishes). Surface live transcode % + the phase-appropriate
            // estimated time remaining (the transcode-only remaining; the subsequent
            // download time is not yet estimable because no bytes are flowing, so we never
            // fabricate a combined total). `optimizeETA` is single-source: it carries the
            // server-`speed`-based estimate when available, else the progress-rate EMA.
            // Emby convert-then-download renders a persistent file server-side before any byte
            // download. Phrase it as "Preparing on server… N%" (distinct from the Plex optimize
            // "Transcoding N%"); both share the same `optimizeProgress`/`optimizeETA` plumbing.
            let prepHead = record.status == .preparing ? "Preparing on server…" : "Transcoding"
            if let p = manager.optimizeProgress[record.ratingKey] {
                var caption = "\(prepHead) \(Int(p * 100))%"
                if let eta = manager.optimizeETA[record.ratingKey], eta > 0,
                   let left = timeLeftString(eta) {
                    caption += " • ~\(left) left"
                }
                return caption
            }
            if manager.optimizeState[record.ratingKey] == "queued" {
                return record.status == .preparing ? "Preparing on server…" : "Queued on server"
            }
            // #84: a server-prep row whose backend lane is signed out isn't really "preparing" —
            // say so honestly. It stays queued and resumes automatically once the lane returns.
            if !isActive, !manager.isBackendConfigured(for: record) {
                return "Paused — \(backendKind(for: record).displayName) signed out"
            }
            if isActive { return "Preparing on server…" }
            if record.metadata?.optimizeQueueTitle?.isEmpty == false {
                return "Queued on server"
            }
            return "Queued…"
        }

        // Phase 2 — file download of the rendered/original Part. When the byte stream is gated
        // by the server's transcoder (the file is served as it renders), a slow rate means the
        // server is still transcoding — NOT a slow network — so say so rather than implying a
        // network bottleneck or a fabricated network speed. The ETA already reflects the real
        // (gated) byte rate, so it stays honest in either case.
        let transcodeLimited = manager.isDownloadTranscodeLimited(record.ratingKey)
        var pieces: [String] = []
        // #97: surface the percentage in EVERY backend's caption, including active rows
        // (previously only inactive rows showed a number). The fraction is the same unified
        // source that drives the bar; an estimated value (JF/Emby transcode, no Content-Length)
        // is prefixed `~` so we don't imply Content-Length precision we don't have.
        let fraction = manager.displayFraction(for: record)
        let percentPiece = fraction.map { f -> String in
            let pct = "\(Int(f.value * 100))%"
            return f.isEstimated ? "~\(pct)" : pct
        }
        if isActive {
            var head: String
            switch record.metadata?.resolvedDownloadLane() ?? .original {
            case .original:
                head = "Downloading original"
            case .compatibleRemux:
                head = "Remuxing/download"
            case .optimize:
                head = transcodeLimited ? "Downloading (server still transcoding)" : "Transcoding/download"
            }
            if let percentPiece { head += " • \(percentPiece)" }
            if let eta = manager.downloadETA[record.ratingKey], eta > 0,
               let left = timeLeftString(eta) {
                head += " • ~\(left) left"
            }
            pieces.append(head)
        } else if let percentPiece {
            pieces.append(percentPiece)
        }
        pieces.append(byteString(record.bytes))
        // Only show a "/s" reading when it's a genuine NETWORK rate. For a transcode-gated
        // transfer the byte rate is the transcoder's output, not the connection, so suppress it
        // to avoid implying a slow network.
        if isActive, !transcodeLimited,
           let speed = manager.downloadSpeed[record.ratingKey], speed > 0 {
            pieces.append("\(byteString(Int(speed)))/s")
        }
        if let r = resolutionLabel(for: record) { pieces.append(r) }
        return pieces.joined(separator: " • ")
    }

    /// Human estimated-time-remaining string ("under a min" / "N min" / "Nh Mm") for a
    /// transcode or download ETA, or nil when the estimate is out of the trustworthy band
    /// (non-finite, ≤0, or >12h — never show a negative or absurd value). The "~" prefix +
    /// "left" suffix are added at the call site to mark it as an estimate.
    private func timeLeftString(_ seconds: TimeInterval) -> String? {
        guard seconds.isFinite, seconds > 0, seconds < 60 * 60 * 12 else { return nil }
        if seconds < 60 { return "under a min" }
        let totalMinutes = Int((seconds / 60).rounded())
        guard totalMinutes >= 1 else { return nil }
        if totalMinutes < 60 { return "\(totalMinutes) min" }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }

    /// Caption for a completed row: file size + resolution, e.g. "1.2 GB • 1080p".
    private func completeCaption(for record: DownloadRecord) -> String {
        var parts = record.isUnverified
            ? ["Downloaded — playback not verified", byteString(record.bytes)]
            : [byteString(record.bytes)]
        if let r = resolutionLabel(for: record) { parts.append(r) }
        return parts.joined(separator: " • ")
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
