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
            CustomPlayerView(localFile: record.localURL, item: offlineItem(from: record))
        }
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
                Text(record.title).font(.headline)
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
                    // The server streams transcoded downloads without a Content-Length,
                    // so `record.progress` is 0 even as bytes climb. Drive the bar off an
                    // estimate (quality cap × runtime) when we have one; otherwise show an
                    // indeterminate bar. See `displayProgress(for:)`.
                    if let progress = displayProgress(for: record) {
                        ProgressView(value: progress)
                        Text(progressCaption(for: record, progress: progress))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                        Text(progressCaption(for: record, progress: nil))
                            .font(.caption)
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
        case .transferFailed(let m):   return "Download failed: \(m)"
        case .invalidDownload(let m):  return "Download invalid: \(m)"
        }
    }

    private func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// The download quality chosen at enqueue time, if persisted (D5).
    private func quality(for record: DownloadRecord) -> DownloadManager.DownloadQuality? {
        record.metadata?.quality.flatMap(DownloadManager.DownloadQuality.init(rawValue:))
    }

    /// Progress fraction for the bar: the server-reported value when present (direct
    /// downloads send a Content-Length), otherwise an estimate from quality × runtime
    /// (transcoded downloads stream without one). Clamped to 0.99 so an underestimate
    /// never shows 100% before the file is actually validated complete. nil → the
    /// caller shows an indeterminate bar (Original quality / unknown runtime).
    private func displayProgress(for record: DownloadRecord) -> Double? {
        if record.progress > 0 { return record.progress }
        if let total = DownloadManager.estimatedTranscodeBytes(
                quality: quality(for: record), durationMs: record.metadata?.duration),
           total > 0, record.bytes > 0 {
            return min(0.99, Double(record.bytes) / Double(total))
        }
        return nil
    }

    /// Caption under the in-progress bar, e.g. "23% • 106.5 MB • 12 MB/s • ~2 min left • 1080p".
    /// Each piece is included only when known, so an estimate-less Original download still
    /// shows bytes + speed + the quality marker.
    private func progressCaption(for record: DownloadRecord, progress: Double?) -> String {
        let isActive = manager.activeJobs.contains(record.ratingKey)
        // No bytes yet on an active job = the server is still spinning up the transcode.
        if record.bytes == 0 { return isActive ? "Preparing on server…" : "Queued…" }

        var pieces: [String] = []
        if let progress { pieces.append("\(Int(progress * 100))%") }
        pieces.append(byteString(record.bytes))
        if let speed = manager.downloadSpeed[record.ratingKey], speed > 0 {
            pieces.append("\(byteString(Int(speed)))/s")
            if let total = DownloadManager.estimatedTranscodeBytes(
                    quality: quality(for: record), durationMs: record.metadata?.duration),
               total > record.bytes {
                pieces.append("~\(etaString(Double(total - record.bytes) / speed)) left")
            }
        }
        if let q = quality(for: record)?.shortLabel { pieces.append(q) }
        return pieces.joined(separator: " • ")
    }

    /// Caption for a completed row: file size + the quality marker, e.g. "1.2 GB • 1080p".
    private func completeCaption(for record: DownloadRecord) -> String {
        var parts = [byteString(record.bytes)]
        if let q = quality(for: record)?.shortLabel { parts.append(q) }
        return parts.joined(separator: " • ")
    }

    /// Human ETA: seconds under 90s show as "N sec", else rounded minutes, else hours.
    private func etaString(_ seconds: Double) -> String {
        if seconds < 90 { return "\(max(1, Int(seconds.rounded()))) sec" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, mins = minutes % 60
        return mins == 0 ? "\(hours) hr" : "\(hours) hr \(mins) min"
    }
}
