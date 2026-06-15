import SwiftUI
import PMSKit

/// Probe-first download sheet (offline-download redesign). On appear it checks whether the
/// selected source can be downloaded directly *and* asks the server for its real optimizer
/// presets. Optimizer presets are always shown: a source file may stream/direct-play but still be
/// an offline-unplayable container (for example MKV), so "Original" is only an optional extra.
/// Both routes converge on the same background-`URLSession` + validation pipeline.
struct DownloadOptionsSheet: View {
    let item: MediaItem
    var mediaIndex: Int = 0
    var partIndex: Int = 0

    @Environment(AppModel.self) private var appModel
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(\.dismiss) private var dismiss

    private struct OriginalOption: Equatable {
        let sizeBytes: Int?
        let resolution: String?
    }

    private enum ProbeState: Equatable {
        case checking
        case ready(original: OriginalOption?, presets: [String], probeFailed: Bool,
                   originalStreamableButOfflineUnsupported: Bool)
    }

    private enum DownloadSelection: Equatable {
        case original
        case optimize(String)
    }

    @State private var probeState: ProbeState = .checking
    @State private var selectedChoice: DownloadSelection?

    private var existingRecord: DownloadRecord? {
        let key = downloadManager.recordKey(for: item)
        return downloadManager.records.first { $0.ratingKey == key }
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
                    case let .ready(original, presets, probeFailed, unsupportedOriginal):
                        if let original {
                            directSection(option: original)
                        }
                        if unsupportedOriginal {
                            originalUnsupportedSection
                        }
                        optimizeSection(presets: presets, probeFailed: probeFailed,
                                        originalAvailable: original != nil)
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
                            .disabled(selectedChoice == nil)
                    }
                }
            }
        }
        .task { await runProbe() }
    }

    // MARK: - Probe

    private func runProbe() async {
        guard existingRecord == nil else { return }
        if appModel.activeBackend == .jellyfin {
            runJellyfinProbe()
            return
        }
        guard let token = appModel.serverToken, let server = appModel.serverBaseURL else {
            let presets = defaultPresets
            selectedChoice = .optimize(presets[0])
            probeState = .ready(original: nil, presets: presets, probeFailed: true,
                                originalStreamableButOfflineUnsupported: false)
            return
        }

        async let probeTask = downloadManager.directPlayProbe(
            for: item, server: server, token: token,
            mediaIndex: mediaIndex, partIndex: partIndex)
        async let presetsTask = downloadManager.optimizePresetNames(server: server, token: token)

        let probe = await probeTask
        let fetchedPresets = await presetsTask
        let presets = fetchedPresets.isEmpty ? defaultPresets : fetchedPresets
        let media = item.media?[safe: mediaIndex]
        let part = probe.part ?? media?.part[safe: partIndex]
        let original = (probe.direct && DownloadManager.isLocallyPlayableOriginal(part: part))
            ? OriginalOption(sizeBytes: part?.size,
                             resolution: DownloadManager.resolutionLabel(for: media))
            : nil
        let unsupportedOriginal = probe.direct && original == nil

        // Default to a server-rendered compatible copy when available. The direct probe says a
        // stream can copy, not that the raw file container is a good offline asset.
        selectedChoice = .optimize(presets.first ?? defaultPresets[0])
        probeState = .ready(original: original, presets: presets, probeFailed: false,
                            originalStreamableButOfflineUnsupported: unsupportedOriginal)
    }

    private func runJellyfinProbe() {
        let media = item.media?[safe: mediaIndex]
        let part = media?.part[safe: partIndex]
        let original = DownloadManager.isLocallyPlayableOriginal(part: part)
            ? OriginalOption(sizeBytes: part?.size,
                             resolution: DownloadManager.resolutionLabel(for: media))
            : nil
        let presets = jellyfinPresets
        selectedChoice = .optimize(presets.first ?? "1080p 8 Mbps")
        probeState = .ready(original: original,
                            presets: presets,
                            probeFailed: false,
                            originalStreamableButOfflineUnsupported: original == nil)
    }

    private var defaultPresets: [String] {
        [
            "Optimized for TV", "Optimized for Mobile", "Original Quality",
            "Original", "1080p 20 Mbps", "1080p 12 Mbps", "1080p 10 Mbps",
            "1080p 8 Mbps", "720p 4 Mbps", "720p 3 Mbps",
            "720p 2 Mbps", "480p 1.5 Mbps"
        ]
    }

    private var jellyfinPresets: [String] {
        [
            "1080p 20 Mbps", "1080p 12 Mbps", "1080p 10 Mbps",
            "1080p 8 Mbps", "720p 4 Mbps", "720p 3 Mbps",
            "720p 2 Mbps", "480p 1.5 Mbps"
        ]
    }

    // MARK: - Sections

    @ViewBuilder
    private func directSection(option: OriginalOption) -> some View {
        SwiftUI.Section {
            Button {
                selectedChoice = .original
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.seal")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Download original").foregroundStyle(.primary)
                        Text(directDetail(sizeBytes: option.sizeBytes, resolution: option.resolution))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selectedChoice == .original {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } header: {
            Text("Original")
        } footer: {
            Text("Downloads the source file without server transcoding. Use this only when you want the largest original file and the container is locally playable.")
        }
    }

    private var originalUnsupportedSection: some View {
        SwiftUI.Section {
            Label {
                Text("The original can stream, but its file container may not play as an offline local file here. Use an optimized preset for a compatible offline copy.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "info.circle")
            }
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
    private func optimizeSection(presets: [String], probeFailed: Bool,
                                 originalAvailable: Bool) -> some View {
        SwiftUI.Section {
            ForEach(presets, id: \.self) { preset in
                Button {
                    selectedChoice = .optimize(preset)
                } label: {
                    HStack {
                        Text(preset).foregroundStyle(.primary)
                        Spacer()
                        if selectedChoice == .optimize(preset) {
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
                 ? "Couldn't check compatibility, so your server will render a compatible version. Pick a preset."
                 : originalAvailable
                    ? "Recommended for offline viewing: your server renders a compatible copy using the selected preset."
                    : "Your server renders a compatible offline version. Pick a preset.")
        }
        .onAppear {
            if case .optimize(let selected)? = selectedChoice, presets.contains(selected) {
                return
            }
            if let first = presets.first {
                selectedChoice = .optimize(first)
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
                    retryDownload()
                    dismiss()
                } label: { Label("Retry Download", systemImage: "arrow.clockwise") }
            } else {
                Label("Downloading…", systemImage: "arrow.down.circle")
                ProgressView(value: record.progress)
                Text("\(Int(record.progress * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                downloadManager.delete(ratingKey: downloadManager.recordKey(for: item))
                dismiss()
            } label: {
                Label(isComplete ? "Remove Download" : "Cancel Download", systemImage: "trash")
            }
        }
    }

    // MARK: - Action

    private func retryDownload() {
        if appModel.activeBackend == .jellyfin {
            Task { await downloadManager.downloadJellyfin(item,
                                                          choice: .optimize(targetName: "1080p 8 Mbps"),
                                                          mediaIndex: mediaIndex,
                                                          partIndex: partIndex) }
        } else {
            downloadManager.retry(ratingKey: item.ratingKey)
        }
    }

    private func startDownload() {
        guard let selectedChoice else { return }
        if appModel.activeBackend == .jellyfin {
            let choice: DownloadManager.DownloadChoice
            switch selectedChoice {
            case .original:
                choice = .original
            case .optimize(let preset):
                choice = .optimize(targetName: preset)
            }
            Task { await downloadManager.downloadJellyfin(item, choice: choice,
                                                          mediaIndex: mediaIndex,
                                                          partIndex: partIndex) }
        } else {
            let choice: DownloadManager.DownloadChoice
            switch selectedChoice {
            case .original:
                choice = .original
            case .optimize(let preset):
                choice = .optimize(targetName: preset)
            }
            Task { await downloadManager.download(item, choice: choice,
                                                  mediaIndex: mediaIndex, partIndex: partIndex) }
        }
        dismiss()
    }
}
