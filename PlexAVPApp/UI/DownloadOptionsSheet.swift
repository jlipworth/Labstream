import SwiftUI
import PMSKit

/// Probe-first download sheet (offline-download redesign). On appear it runs the direct-play
/// probe: if the WHOLE file direct-plays it offers a single "Download original — <size> · <res>"
/// action (no quality picker); otherwise it offers the server's real optimize presets. If the
/// probe fails / the server is unreachable, it falls back to offering the optimizer presets.
/// Both routes converge on the same background-`URLSession` + validation pipeline.
struct DownloadOptionsSheet: View {
    let item: MediaItem
    var mediaIndex: Int = 0
    var partIndex: Int = 0

    @Environment(DownloadManager.self) private var downloadManager
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    private enum ProbeState: Equatable {
        case checking
        case direct(sizeBytes: Int?, resolution: String?)
        case optimize(presets: [String], probeFailed: Bool)
    }

    @State private var probeState: ProbeState = .checking
    /// Chosen optimizer preset name (when not direct).
    @State private var selectedPreset: String = "Optimized for TV"

    private var existingRecord: DownloadRecord? {
        downloadManager.records.first { $0.ratingKey == item.ratingKey }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let record = existingRecord {
                    existingSection(record)
                } else {
                    switch probeState {
                    case .checking:
                        SwiftUI.Section { Label("Checking compatibility…", systemImage: "wifi") }
                    case let .direct(sizeBytes, resolution):
                        directSection(sizeBytes: sizeBytes, resolution: resolution)
                        infoSection
                    case let .optimize(presets, probeFailed):
                        optimizeSection(presets: presets, probeFailed: probeFailed)
                        infoSection
                    }
                }
            }
            .navigationTitle("Download")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if existingRecord == nil, probeState != .checking {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Download") { startDownload() }
                    }
                }
            }
        }
        .task { await runProbe() }
    }

    // MARK: - Probe

    private func runProbe() async {
        guard existingRecord == nil else { return }
        guard let token = appModel.serverToken, let server = appModel.serverBaseURL else {
            probeState = .optimize(presets: defaultPresets, probeFailed: true)
            return
        }
        let result = await downloadManager.directPlayProbe(
            for: item, server: server, token: token,
            mediaIndex: mediaIndex, partIndex: partIndex)
        if result.direct {
            let media = item.media?[safe: mediaIndex]
            probeState = .direct(sizeBytes: result.part?.size,
                                 resolution: DownloadManager.resolutionLabel(for: media))
        } else {
            // Try the server's real presets; fall back to the built-in names if unavailable.
            let presets = await downloadManager.optimizePresetNames(server: server, token: token)
            probeState = .optimize(presets: presets.isEmpty ? defaultPresets : presets,
                                   probeFailed: false)
        }
    }

    private var defaultPresets: [String] {
        ["Optimized for TV", "Optimized for Mobile", "Original Quality"]
    }

    // MARK: - Sections

    @ViewBuilder
    private func directSection(sizeBytes: Int?, resolution: String?) -> some View {
        SwiftUI.Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Download original")
                    Text(directDetail(sizeBytes: sizeBytes, resolution: resolution))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: "checkmark.seal") }
        } header: {
            Text("Compatible")
        } footer: {
            Text("This file plays as-is on your headset, so it downloads at full original "
                 + "quality without server transcoding.")
        }
    }

    private func directDetail(sizeBytes: Int?, resolution: String?) -> String {
        var parts: [String] = []
        if let sizeBytes, sizeBytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file))
        }
        if let resolution { parts.append(resolution) }
        return parts.isEmpty ? "Original file" : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func optimizeSection(presets: [String], probeFailed: Bool) -> some View {
        SwiftUI.Section {
            ForEach(presets, id: \.self) { preset in
                Button {
                    selectedPreset = preset
                } label: {
                    HStack {
                        Text(preset).foregroundStyle(.primary)
                        Spacer()
                        if preset == selectedPreset {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Optimize on server")
        } footer: {
            Text(probeFailed
                 ? "Couldn't check compatibility, so your server will render a compatible "
                   + "version. Pick a preset."
                 : "This file needs converting, so your server renders a compatible version. "
                   + "Pick a preset.")
        }
        .onAppear {
            if !presets.contains(selectedPreset), let first = presets.first {
                selectedPreset = first
            }
        }
    }

    private var infoSection: some View {
        SwiftUI.Section {
            Label {
                Text("Transfers continue in the background and pause while the headset "
                     + "is off, resuming when it's worn again.")
                    .font(.footnote).foregroundStyle(.secondary)
            } icon: { Image(systemName: "wifi") }
        }
    }

    // MARK: - Already-downloaded state

    @ViewBuilder
    private func existingSection(_ record: DownloadRecord) -> some View {
        let isComplete = record.isComplete
        let isFailed = record.status == .failed
        SwiftUI.Section {
            if isComplete {
                Label("Downloaded for offline viewing", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(ByteCountFormatter.string(fromByteCount: Int64(record.bytes), countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            } else if isFailed {
                Label("Download failed", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                Button {
                    downloadManager.retry(ratingKey: item.ratingKey)
                    dismiss()
                } label: { Label("Retry Download", systemImage: "arrow.clockwise") }
            } else {
                Label("Downloading…", systemImage: "arrow.down.circle")
                ProgressView(value: record.progress)
                Text("\(Int(record.progress * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                downloadManager.delete(ratingKey: item.ratingKey)
                dismiss()
            } label: {
                Label(isComplete ? "Remove Download" : "Cancel Download", systemImage: "trash")
            }
        }
    }

    // MARK: - Action

    private func startDownload() {
        let choice: DownloadManager.DownloadChoice
        switch probeState {
        case .direct: choice = .original
        case .optimize: choice = .optimize(targetName: selectedPreset)
        case .checking: return
        }
        Task { await downloadManager.download(item, choice: choice,
                                              mediaIndex: mediaIndex, partIndex: partIndex) }
        dismiss()
    }
}
