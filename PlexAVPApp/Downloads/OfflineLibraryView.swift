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
        let isComplete = record.progress >= 1.0
        let isActive = manager.activeJobs.contains(record.ratingKey)
        let error = manager.lastError[record.ratingKey]

        HStack(spacing: 16) {
            // A small offline glyph tile keeps each row visually anchored even though
            // local records don't carry poster artwork.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: isComplete ? "arrow.down.circle.fill" : "arrow.down.circle")
                        .font(.title3)
                        .foregroundStyle(isComplete ? .green : .secondary)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(record.title).font(.headline)
                if let error {
                    Text(message(for: error))
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
            if isComplete {
                Button {
                    playing = record
                } label: {
                    Image(systemName: "play.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
            } else if isActive || error == nil {
                ProgressView()
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { if isComplete { playing = record } }
    }

    /// Build a minimal `MediaItem` so the offline file can flow through the same
    /// `PlayerView` path. The player only needs `title` (and `ratingKey`/`type`)
    /// for a local file; stream metadata isn't required offline.
    private func offlineItem(from record: DownloadRecord) -> MediaItem {
        MediaItem(ratingKey: record.ratingKey, title: record.title, type: "movie")
    }

    private func message(for error: DownloadManager.DownloadError) -> String {
        switch error {
        case .notAuthenticated:        return "Sign in to download."
        case .optimizeFailed(let m):   return "Optimize failed: \(m)"
        case .optimizeTimedOut:        return "Optimize timed out on the server."
        case .noOptimizedPart:         return "No optimized version was produced."
        case .storageFull:             return "Not enough free space."
        case .transferFailed(let m):   return "Download failed: \(m)"
        }
    }

    private func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
