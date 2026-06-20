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

    public init(manager: DownloadManager) {
        _manager = State(initialValue: manager)
    }

    public var body: some View {
        NavigationStack {
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
                        SwiftUI.Section {
                            ForEach(manager.records) { record in
                                row(for: record)
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
        }
        .fullScreenCover(item: $playing) { record in
            CustomPlayerView(localFile: record.localURL,
                             item: offlineItem(from: record),
                             trickPlayProvider: localTrickPlayProvider(for: record),
                             offlineTextSubtitles: record.metadata?.offlineTextSubtitles ?? [],
                             onClose: { playing = nil })
        }
    }

    private func localTrickPlayProvider(for record: DownloadRecord) -> (any TrickPlayThumbnailProviding)? {
        if let playlist = record.jellyfinTrickPlayPlaylistURL {
            return LocalJellyfinTrickPlayThumbnailProvider(playlistURL: playlist)
        }
        return LocalBIFTrickPlayThumbnailProvider(bifURL: record.plexBIFURL)
    }

    @ViewBuilder
    private func row(for record: DownloadRecord) -> some View {
        // Drive the row off the explicit, persisted status (D2) instead of inferring
        // completion from `progress >= 1.0` — a stalled job that froze at <100% and a
        // failed-but-100% body are now distinct, observable states.
        let isComplete = record.isComplete
        let isFailed = record.status == .failed
        let error = manager.lastError[record.ratingKey]

        HStack(spacing: 16) {
            // D5: show the locally-cached poster when present (works fully offline);
            // otherwise fall back to a small offline glyph tile.
            offlinePoster(for: record, isComplete: isComplete, isFailed: isFailed)

            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle(for: record)).font(.headline)
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
                } else if isComplete {
                    Text(completeCaption(for: record))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // Both download paths serve a static file with a real Content-Length, so
                    // `record.progress` drives the bar directly. See `displayProgress(for:)`.
                    if let progress = displayProgress(for: record) {
                        ProgressView(value: progress)
                            .animation(.linear(duration: 0.2), value: progress)
                        Text(progressCaption(for: record, progress: progress))
                            .font(.caption)
                            .monospacedDigit()
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                        Text(progressCaption(for: record, progress: nil))
                            .font(.caption)
                            .monospacedDigit()
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            HStack(spacing: 16) {
                if isComplete {
                    Button {
                        // Music and video share one audio session — yield music
                        // before launching the offline player (#17).
                        musicPlayer.pauseForVideo()
                        playing = record
                    } label: {
                        Image(systemName: "play.circle.fill").font(.title2)
                    }
                    .buttonStyle(.plain)
                } else if isFailed {
                    Button {
                        manager.retry(ratingKey: record.ratingKey)
                    } label: {
                        Image(systemName: "arrow.clockwise.circle.fill").font(.title2)
                    }
                    .buttonStyle(.plain)
                } else {
                    ProgressView()
                }

                // Explicit delete on every row (complete / failed / in-progress). The List's
                // swipe-to-delete still works, but a visible trash control is far more
                // discoverable on visionOS — and lets the user clear a FAILED or no-longer-
                // wanted download directly. `manager.delete` cancels any live task and removes
                // the file + cached poster + record.
                Button {
                    manager.delete(ratingKey: record.ratingKey)
                } label: {
                    Image(systemName: "trash.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Delete download")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if isComplete {
                musicPlayer.pauseForVideo()
                playing = record
            } else if isFailed {
                manager.retry(ratingKey: record.ratingKey)
            }
        }
    }

    private func tileGlyph(isComplete: Bool, isFailed: Bool) -> String {
        if isComplete { return "arrow.down.circle.fill" }
        if isFailed { return "exclamationmark.circle" }
        return "arrow.down.circle"
    }

    /// The locally-cached poster (D5) when present, else the neutral glyph tile.
    @ViewBuilder
    private func offlinePoster(for record: DownloadRecord, isComplete: Bool, isFailed: Bool) -> some View {
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
                    Image(systemName: tileGlyph(isComplete: isComplete, isFailed: isFailed))
                        .font(.title3)
                        .foregroundStyle(isComplete ? .green : (isFailed ? .red : .secondary))
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
        }
    }

    private func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// The downloaded file's resolution label, if captured (offline-download redesign).
    private func resolutionLabel(for record: DownloadRecord) -> String? {
        record.metadata?.resolutionLabel
    }

    /// Progress fraction for the bar. Both download paths now serve a STATIC file with a real
    /// Content-Length, so the server-reported `record.progress` is authoritative — no estimate
    /// needed (the bitrate-cap estimation was retired with the progressive path). nil → the
    /// server hasn't reported yet (show an indeterminate bar).
    private func displayProgress(for record: DownloadRecord) -> Double? {
        record.progress > 0 ? record.progress : nil
    }

    /// Caption under the in-progress bar, e.g. "23% • 106.5 MB • 12 MB/s • 1080p".
    /// Each piece is included only when known. Speed comes from the smoothed EMA in
    /// `DownloadManager.refreshRecords` (kept — orthogonal jitter fix).
    private func progressCaption(for record: DownloadRecord, progress: Double?) -> String {
        let isActive = manager.activeJobs.contains(record.ratingKey)
        if record.bytes == 0 {
            // Phase 1 — server-side optimize/transcode (the rendered file can't download
            // until this finishes). Surface live transcode % + the phase-appropriate
            // estimated time remaining (the transcode-only remaining; the subsequent
            // download time is not yet estimable because no bytes are flowing, so we never
            // fabricate a combined total). `optimizeETA` is single-source: it carries the
            // server-`speed`-based estimate when available, else the progress-rate EMA.
            if let p = manager.optimizeProgress[record.ratingKey] {
                var caption = "Transcoding \(Int(p * 100))%"
                if let eta = manager.optimizeETA[record.ratingKey], eta > 0,
                   let left = timeLeftString(eta) {
                    caption += " • ~\(left) left"
                }
                return caption
            }
            if manager.optimizeState[record.ratingKey] == "queued" {
                return "Queued on server"
            }
            return isActive ? "Preparing on server…" : "Queued…"
        }

        // Phase 2 — file download of the rendered/original Part. When the byte stream is gated
        // by the server's transcoder (the file is served as it renders), a slow rate means the
        // server is still transcoding — NOT a slow network — so say so rather than implying a
        // network bottleneck or a fabricated network speed. The ETA already reflects the real
        // (gated) byte rate, so it stays honest in either case.
        let transcodeLimited = manager.isDownloadTranscodeLimited(record.ratingKey)
        var pieces: [String] = []
        if isActive {
            var head = transcodeLimited ? "Downloading (server still transcoding)" : "Downloading"
            if let eta = manager.downloadETA[record.ratingKey], eta > 0,
               let left = timeLeftString(eta) {
                head += " • ~\(left) left"
            }
            pieces.append(head)
        } else if let progress {
            pieces.append("\(Int(progress * 100))%")
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
        var parts = [byteString(record.bytes)]
        if let r = resolutionLabel(for: record) { parts.append(r) }
        return parts.joined(separator: " • ")
    }
}
