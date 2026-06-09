import SwiftUI
import PlexKit

/// Lets the user pick a QUALITY before an offline download starts, then kicks off the
/// transfer through `DownloadManager.optimizeAndDownload(_:quality:)`.
///
/// Self-contained and trivial to present — it reads `DownloadManager` and `AppModel`
/// from the environment, so a caller only supplies the item:
///
/// ```swift
/// .sheet(isPresented: $showDownloadOptions) {
///     DownloadOptionsSheet(item: item)
/// }
/// ```
///
/// The chosen quality maps to a video-bitrate cap handed to the SAME universal
/// transcoder the player streams from (a single progressive MP4 we can fetch with one
/// background `URLSession` task), so the offline copy matches what the player would
/// produce at that cap. Once a download exists for the item the sheet shows that
/// state instead of re-offering the picker, and we surface the visionOS reality that
/// background transfers pause while the headset is off.
struct DownloadOptionsSheet: View {
    let item: MediaItem

    @Environment(AppModel.self) private var appModel
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(\.dismiss) private var dismiss

    /// User's quality choice; defaults to the app-wide 1080p/8 Mbps preset.
    @State private var quality: DownloadManager.DownloadQuality = .default

    /// Already downloaded (or downloading) before this sheet was opened?
    private var existingRecord: DownloadRecord? {
        downloadManager.records.first { $0.ratingKey == item.ratingKey }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let record = existingRecord {
                    existingSection(record)
                } else {
                    qualitySection
                    infoSection
                }
            }
            .navigationTitle("Download")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if existingRecord == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Download") { startDownload() }
                    }
                }
            }
        }
    }

    // MARK: - Picker

    private var qualitySection: some View {
        SwiftUI.Section {
            // A radio-style list so each option shows its label + caption.
            ForEach(DownloadManager.DownloadQuality.allCases) { option in
                Button {
                    quality = option
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label)
                                .foregroundStyle(.primary)
                            Text(option.caption)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if option == quality {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Quality")
        } footer: {
            Text("Higher quality means a larger download. The chosen quality is "
                 + "transcoded by your Plex server before transfer.")
        }
    }

    private var infoSection: some View {
        SwiftUI.Section {
            Label {
                Text("Transfers continue in the background and pause while the headset "
                     + "is off, resuming when it's worn again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "wifi")
            }
        }
    }

    // MARK: - Already-downloaded state

    @ViewBuilder
    private func existingSection(_ record: DownloadRecord) -> some View {
        // Drive off the explicit persisted status (D2) so a stalled/failed row is no
        // longer mistaken for an in-progress one.
        let isComplete = record.isComplete
        let isFailed = record.status == .failed
        SwiftUI.Section {
            if isComplete {
                Label("Downloaded for offline viewing", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(ByteCountFormatter.string(fromByteCount: Int64(record.bytes), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isFailed {
                Label("Download failed", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                Button {
                    downloadManager.retry(ratingKey: item.ratingKey)
                    dismiss()
                } label: {
                    Label("Retry Download", systemImage: "arrow.clockwise")
                }
            } else {
                Label("Downloading…", systemImage: "arrow.down.circle")
                ProgressView(value: record.progress)
                Text("\(Int(record.progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                downloadManager.delete(ratingKey: item.ratingKey)
                dismiss()
            } label: {
                Label(isComplete ? "Remove Download" : "Cancel Download",
                      systemImage: "trash")
            }
        }
    }

    // MARK: - Action

    private func startDownload() {
        let chosen = quality
        Task { await downloadManager.optimizeAndDownload(item, quality: chosen) }
        dismiss()
    }
}
