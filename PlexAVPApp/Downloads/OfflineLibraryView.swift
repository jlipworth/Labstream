import SwiftUI
import PlexKit

/// Lists offline downloads with live progress + delete, and plays a completed
/// file through the shared Task 11 player (`PlayerView(localFile:item:)`).
///
/// Surfaces the offline-transfer reality (research/10): background transfers on
/// visionOS pause while the headset is off and resume when it's worn again, so an
/// in-progress download may appear "stuck" until the user puts the headset back on.
public struct OfflineLibraryView: View {
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
            PlayerView(localFile: record.localURL, item: offlineItem(from: record))
        }
    }

    @ViewBuilder
    private func row(for record: DownloadRecord) -> some View {
        // Drive the row off the explicit, persisted status (D2) instead of inferring
        // completion from `progress >= 1.0` — a stalled job that froze at <100% and a
        // failed-but-100% body are now distinct, observable states.
        let isComplete = record.isComplete
        let isFailed = record.status == .failed
        let isActive = manager.activeJobs.contains(record.ratingKey)
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
                    Text(byteString(record.bytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView(value: record.progress)
                    Text(isActive && record.progress == 0
                         ? "Optimizing on server…"
                         : "\(Int(record.progress * 100))% • \(byteString(record.bytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 16) {
                if isComplete {
                    Button {
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
            if isComplete { playing = record }
            else if isFailed { manager.retry(ratingKey: record.ratingKey) }
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
    /// offline file flows through the same `PlayerView` path with real title/metadata.
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
}
