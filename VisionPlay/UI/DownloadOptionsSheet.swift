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

    @AppStorage(PlaybackPreferences.Keys.defaultDownloadQuality) private var defaultDownloadQuality = PlaybackPreferences.defaultDownloadQuality

    private struct OriginalOption: Equatable {
        let sizeBytes: Int?
        let resolution: String?
    }

    /// #83: the "Original quality (compatible)" remux option — offered when the raw container is not
    /// locally playable but the server can copy the video into an MP4. Carries the codec summary
    /// for the row caption.
    private struct CompatibleRemuxOption: Equatable {
        let codecSummary: String?
    }

    private enum ProbeState: Equatable {
        case checking
        case ready(original: OriginalOption?, compatibleRemux: CompatibleRemuxOption?,
                   presets: [String], probeFailed: Bool,
                   originalStreamableButOfflineUnsupported: Bool)
    }

    private enum DownloadSelection: Equatable {
        case original
        case optimizeCompatible
        case optimize(String)
    }

    @State private var probeState: ProbeState = .checking
    @State private var selectedChoice: DownloadSelection?

    private var existingRecord: DownloadRecord? {
        let key = downloadManager.recordKey(for: item, backend: appModel.activeBackend.downloadBackendKind)
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
                    case let .ready(original, compatibleRemux, presets, probeFailed, unsupportedOriginal):
                        if let original {
                            directSection(option: original)
                        }
                        if let compatibleRemux {
                            compatibleRemuxSection(option: compatibleRemux)
                        }
                        if unsupportedOriginal, compatibleRemux == nil {
                            originalUnsupportedSection
                        }
                        if let plexOriginalPreset = plexOriginalOptimizePreset(in: presets) {
                            plexOriginalQualitySection(preset: plexOriginalPreset)
                        }
                        optimizeSection(presets: optimizePresetsExcludingPlexOriginal(presets),
                                        allPresets: presets,
                                        probeFailed: probeFailed,
                                        originalAvailable: original != nil)
                        storageLimitSection
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
                            .disabled(selectedChoice == nil || selectedStorageLimitMessage != nil)
                    }
                }
            }
        }
        .task { await runProbe() }
    }

    // MARK: - Probe

    private func runProbe() async {
        guard existingRecord == nil else { return }
        downloadLog.notice("download-sheet-run-probe item=\(item.ratingKey, privacy: .public) activeBackend=\(appModel.activeBackend.rawValue, privacy: .public) mediaIndex=\(mediaIndex, privacy: .public)")
        if appModel.activeBackend == .jellyfin {
            await runJellyfinProbe()
            return
        }
        if appModel.activeBackend == .emby {
            await runEmbyProbe()
            return
        }
        guard let token = appModel.serverToken, let server = appModel.serverBaseURL else {
            let presets = defaultPresets
            selectedChoice = .optimize(presets[0])
            probeState = .ready(original: nil, compatibleRemux: nil, presets: presets, probeFailed: true,
                                originalStreamableButOfflineUnsupported: false)
            return
        }

        async let probeTask = downloadManager.directPlayProbe(
            for: item, server: server, token: token,
            mediaIndex: mediaIndex, partIndex: partIndex)
        async let presetsTask = downloadManager.optimizePresetNames(server: server, token: token)

        let probe = await probeTask
        let fetchedPresets = filteredOptimizePresets(await presetsTask)
        let presets = fetchedPresets.isEmpty ? defaultPresets : fetchedPresets
        let media = item.media?[safe: mediaIndex]
        let part = probe.part ?? media?.part[safe: partIndex]
        let original = (probe.direct && DownloadManager.isLocallyPlayableOriginal(part: part))
            ? OriginalOption(sizeBytes: part?.size,
                             resolution: DownloadManager.resolutionLabel(for: media))
            : nil
        let unsupportedOriginal = probe.direct && original == nil

        // Plex uses its optimized-version model (no client-side remux lane); never offer it here.
        selectedChoice = preferredSelection(originalAvailable: original != nil,
                                            compatibleRemuxAvailable: false, presets: presets)
        probeState = .ready(original: original, compatibleRemux: nil, presets: presets, probeFailed: false,
                            originalStreamableButOfflineUnsupported: unsupportedOriginal)
    }

    private func runJellyfinProbe() async {
        let media = item.media?[safe: mediaIndex]
        let part = media?.part[safe: partIndex]
        let originalLocallyPlayable = DownloadManager.isLocallyPlayableOriginal(part: part)
        let original = originalLocallyPlayable
            ? OriginalOption(sizeBytes: part?.size,
                             resolution: DownloadManager.resolutionLabel(for: media))
            : nil
        let mediaSourceId = selectedMediaSourceID(media: media, part: part)
        // The list/detail MediaItem may not carry full stream codec metadata for Jellyfin, so do
        // not decide remux eligibility from the local Part alone. Ask PlaybackInfo whenever the
        // raw file is not already locally playable, then use the server's authoritative codec and
        // codec/container verdict to decide whether "Original quality (compatible)" can be offered.
        let shouldProbeRemux = !originalLocallyPlayable
        downloadLog.notice("download-sheet-jellyfin-probe-start item=\(item.ratingKey, privacy: .public) originalPlayable=\(originalLocallyPlayable, privacy: .public) mediaSource=\(mediaSourceId ?? "nil", privacy: .public)")
        var probeFailed = false
        var compatibleRemux: CompatibleRemuxOption?
        if shouldProbeRemux {
            guard let server = appModel.jellyfinServerBaseURL,
                  let token = appModel.jellyfinAccessToken,
                  let userId = appModel.jellyfinUserID else {
                probeFailed = true
                compatibleRemux = nil
                let presets = jellyfinPresets
                selectedChoice = preferredSelection(originalAvailable: original != nil,
                                                    compatibleRemuxAvailable: false,
                                                    presets: presets)
                probeState = .ready(original: original,
                                    compatibleRemux: nil,
                                    presets: presets,
                                    probeFailed: true,
                                    originalStreamableButOfflineUnsupported: original == nil)
                return
            }
            var didRetryCancellation = false
            while true {
                do {
                    let req = try JellyfinPlayback.downloadPlaybackInfoRequest(
                        server: server, token: token, identity: appModel.identity.jellyfin,
                        itemId: item.ratingKey, userId: userId, mediaSourceId: mediaSourceId,
                        maxStaticBitrate: 200_000_000)
                    let (data, response) = try await URLSession.shared.data(for: req)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw URLError(.badServerResponse)
                    }
                    let info = try JellyfinPlaybackInfoResponse.decode(from: data)
                    let decision = try JellyfinPlayback.downloadDecision(response: info,
                                                                         preferredMediaSourceId: mediaSourceId)
                    let remuxEligibility = OfflineDownloadDecision.compatibleRemuxEligibility(
                        videoCodec: decision.videoCodec,
                        audioCodec: decision.audioCodec,
                        sourceContainer: decision.container)
                    compatibleRemux = remuxEligibility.shouldOffer(originalLocallyPlayable: originalLocallyPlayable)
                        ? CompatibleRemuxOption(codecSummary: remuxEligibility.codecSummary)
                        : nil
                    downloadLog.notice("download-sheet-jellyfin-probe-result item=\(item.ratingKey, privacy: .public) directStream=\(decision.supportsDirectStream, privacy: .public) video=\(remuxEligibility.videoCodec ?? "nil", privacy: .public) audio=\(remuxEligibility.audioCodec ?? "nil", privacy: .public) container=\(remuxEligibility.sourceContainer, privacy: .public) offer=\(compatibleRemux != nil, privacy: .public)")
                    break
                } catch {
                    if isCancellation(error) {
                        if Task.isCancelled {
                            downloadLog.notice("download-sheet-jellyfin-probe-cancelled item=\(item.ratingKey, privacy: .public) taskCancelled=true")
                            return
                        }
                        if !didRetryCancellation {
                            didRetryCancellation = true
                            downloadLog.notice("download-sheet-jellyfin-probe-cancelled item=\(item.ratingKey, privacy: .public) retry=true")
                            continue
                        }
                    }
                    probeFailed = true
                    compatibleRemux = nil
                    downloadLog.error("download-sheet-jellyfin-probe-failed item=\(item.ratingKey, privacy: .public) error=\(String(describing: error), privacy: .public)")
                    break
                }
            }
        }
        let presets = jellyfinPresets
        downloadLog.notice("download-sheet-jellyfin-ready item=\(item.ratingKey, privacy: .public) probeFailed=\(probeFailed, privacy: .public) original=\(original != nil, privacy: .public) remux=\(compatibleRemux != nil, privacy: .public)")
        selectedChoice = preferredSelection(originalAvailable: original != nil,
                                            compatibleRemuxAvailable: compatibleRemux != nil,
                                            presets: presets)
        probeState = .ready(original: original,
                            compatibleRemux: compatibleRemux,
                            presets: presets,
                            probeFailed: probeFailed,
                            originalStreamableButOfflineUnsupported: original == nil && compatibleRemux == nil)
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == URLError.cancelled.rawValue
    }

    /// Emby probe: POST the DOWNLOAD PlaybackInfo (Static-mp4 device profile) and read the
    /// AUTHORITATIVE negotiated verdict — `SupportsDirectPlay` + container — to decide whether to
    /// offer the original. Mirrors `runJellyfinProbe`'s outcome shape but, unlike Jellyfin (which
    /// only checks the container locally), Emby must ask the server because the naked-item
    /// direct-play flag is optimistic and untrustworthy. On any failure we fall back to presets
    /// only (probeFailed), exactly like the Plex path.
    private func runEmbyProbe() async {
        let media = item.media?[safe: mediaIndex]
        let part = media?.part[safe: partIndex]
        let presets = embyPresets
        let mediaSourceId = selectedMediaSourceID(media: media, part: part)
        guard let server = appModel.embyServerBaseURL,
              let token = appModel.embyAccessToken,
              let userId = appModel.embyUserID else {
            selectedChoice = .optimize(presets[0])
            probeState = .ready(original: nil, compatibleRemux: nil, presets: presets, probeFailed: true,
                                originalStreamableButOfflineUnsupported: false)
            return
        }

        let identity = appModel.identity.emby
        var negotiatedDirectPlay = false
        var negotiatedContainer: String?
        var negotiatedVideoCodec: String?
        var negotiatedAudioCodec: String?
        var probeFailed = false
        do {
            let req = try EmbyPlayback.downloadPlaybackInfoRequest(
                server: server, token: token, identity: identity,
                userId: userId, itemId: item.ratingKey,
                mediaSourceId: mediaSourceId,
                maxStaticBitrate: 200_000_000)
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            let info = try EmbyPlaybackInfoResponse.decode(from: data)
            let decision = try EmbyPlayback.downloadDecision(response: info)
            negotiatedDirectPlay = decision.supportsDirectPlay
            negotiatedContainer = decision.container
            negotiatedVideoCodec = decision.videoCodec
            negotiatedAudioCodec = decision.audioCodec
        } catch {
            probeFailed = true
        }

        let containerPlayable = DownloadManager.isLocallyPlayableOriginal(part: part)
            || ["mp4", "m4v", "mov"].contains((negotiatedContainer ?? "").lowercased())
        let original = (negotiatedDirectPlay && containerPlayable)
            ? OriginalOption(sizeBytes: part?.size,
                             resolution: DownloadManager.resolutionLabel(for: media))
            : nil
        // #83: use the dedicated compatible-remux PlaybackInfo profile for codec/container probing.
        // The normal download profile remains conservative for the forced-transcode lane.
        var compatibleRemux: CompatibleRemuxOption?
        if !probeFailed, original == nil {
            do {
                let remuxReq = try EmbyPlayback.compatibleRemuxDownloadPlaybackInfoRequest(
                    server: server, token: token, identity: identity,
                    userId: userId, itemId: item.ratingKey,
                    mediaSourceId: mediaSourceId,
                    maxStaticBitrate: 200_000_000)
                let (data, response) = try await URLSession.shared.data(for: remuxReq)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                let info = try EmbyPlaybackInfoResponse.decode(from: data)
                let decision = try EmbyPlayback.downloadDecision(response: info,
                                                                 preferredMediaSourceId: mediaSourceId)
                negotiatedVideoCodec = decision.videoCodec
                negotiatedAudioCodec = decision.audioCodec
                negotiatedContainer = decision.container
                let remuxEligibility = OfflineDownloadDecision.compatibleRemuxEligibility(
                    videoCodec: negotiatedVideoCodec,
                    audioCodec: negotiatedAudioCodec,
                    sourceContainer: negotiatedContainer)
                compatibleRemux = remuxEligibility.shouldOffer(originalLocallyPlayable: false)
                    ? CompatibleRemuxOption(codecSummary: remuxEligibility.codecSummary)
                    : nil
            } catch {
                probeFailed = true
                compatibleRemux = nil
            }
        }
        // "Streamable but offline-unsupported" = the server would direct-play it but the container
        // can't be a raw offline local file (e.g. mkv) and no compatible remux is offered.
        let unsupportedOriginal = !probeFailed && negotiatedDirectPlay && original == nil && compatibleRemux == nil

        selectedChoice = preferredSelection(originalAvailable: original != nil,
                                            compatibleRemuxAvailable: compatibleRemux != nil,
                                            presets: presets)
        probeState = .ready(original: original,
                            compatibleRemux: compatibleRemux,
                            presets: presets,
                            probeFailed: probeFailed,
                            originalStreamableButOfflineUnsupported: unsupportedOriginal)
    }

    private var defaultPresets: [String] {
        filteredOptimizePresets([
            "Original video quality",
            "1080p 20 Mbps", "1080p 12 Mbps", "1080p 10 Mbps",
            "1080p 8 Mbps", "720p 4 Mbps", "720p 3 Mbps",
            "720p 2 Mbps", "480p 1.5 Mbps"
        ])
    }

    private func filteredOptimizePresets(_ presets: [String]) -> [String] {
        presets.filter { preset in
            ![
                "Original Quality",
                "Optimized for TV",
                "Optimized for Mobile",
            ].contains { hidden in
                preset.localizedCaseInsensitiveCompare(hidden) == .orderedSame
            }
        }
    }

    private var jellyfinPresets: [String] {
        [
            "1080p 20 Mbps", "1080p 12 Mbps", "1080p 10 Mbps",
            "1080p 8 Mbps", "720p 4 Mbps", "720p 3 Mbps",
            "720p 2 Mbps", "480p 1.5 Mbps"
        ]
    }

    // Emby has no server-side optimize-target list (Plex-only), so the picker uses the same
    // hard-coded bitrate ladder as Jellyfin; the manager maps each preset to a transcode profile.
    private var embyPresets: [String] {
        [
            "1080p 20 Mbps", "1080p 12 Mbps", "1080p 10 Mbps",
            "1080p 8 Mbps", "720p 4 Mbps", "720p 3 Mbps",
            "720p 2 Mbps", "480p 1.5 Mbps"
        ]
    }


    private func plexOriginalOptimizePreset(in presets: [String]) -> String? {
        guard appModel.activeBackend == .plex else { return nil }
        return presets.first { $0.localizedCaseInsensitiveCompare("Original video quality") == .orderedSame }
    }

    private func optimizePresetsExcludingPlexOriginal(_ presets: [String]) -> [String] {
        guard plexOriginalOptimizePreset(in: presets) != nil else { return presets }
        return presets.filter { $0.localizedCaseInsensitiveCompare("Original video quality") != .orderedSame }
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
            Text("Downloads the raw source file without server conversion. This is shown only when the original container is locally playable.")
        }
    }

    @ViewBuilder
    private func compatibleRemuxSection(option: CompatibleRemuxOption) -> some View {
        SwiftUI.Section {
            Button {
                selectedChoice = .optimizeCompatible
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Original quality (compatible)").foregroundStyle(.primary)
                        Text(option.codecSummary ?? "Keeps original video, converts to a compatible MP4")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selectedChoice == .optimizeCompatible {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } header: {
            Text("Original quality")
        } footer: {
            Text("Keeps the original video quality by copying the video stream into a compatible MP4 (audio is converted only if needed). Can't pause and resume like the original-file download, so it restarts if interrupted.")
        }
    }

    private var originalUnsupportedSection: some View {
        SwiftUI.Section {
            Label {
                Text("The original can stream, but its file container may not play as a raw offline local file here. Original quality is not available for this item/server response, so pick a bitrate preset to create a compatible offline copy.")
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
    private func plexOriginalQualitySection(preset: String) -> some View {
        SwiftUI.Section {
            Button {
                selectedChoice = .optimize(preset)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Original video quality").foregroundStyle(.primary)
                        Text("Plex original-quality offline copy")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selectedChoice == .optimize(preset) {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } header: {
            Text("Original quality")
        } footer: {
            Text("Creates a compatible offline copy at Plex's original video quality. Plex may prepare the file on the server before downloading.")
        }
    }

    @ViewBuilder
    private func optimizeSection(presets: [String], allPresets: [String], probeFailed: Bool,
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
            if selectedChoice == .original, originalAvailable {
                return
            }
            // A compatible-remux selection is self-contained (not in `presets`); leave it intact.
            if selectedChoice == .optimizeCompatible {
                return
            }
            if case .optimize(let selected)? = selectedChoice, allPresets.contains(selected) {
                return
            }
            selectedChoice = preferredSelection(originalAvailable: originalAvailable,
                                                compatibleRemuxAvailable: false, presets: allPresets)
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


    @ViewBuilder
    private var storageLimitSection: some View {
        if let message = selectedStorageLimitMessage {
            SwiftUI.Section {
                Label {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "internaldrive.fill.badge.exclamationmark")
                }
            }
        }
    }

    private var selectedStorageLimitMessage: String? {
        guard let selectedChoice else { return nil }
        return downloadManager.storageLimitMessage(adding: downloadManager.estimatedBytes(
            for: item, choice: managerChoice(for: selectedChoice),
            mediaIndex: mediaIndex, partIndex: partIndex))
    }

    private func preferredSelection(originalAvailable: Bool,
                                    compatibleRemuxAvailable: Bool,
                                    presets: [String]) -> DownloadSelection? {
        if defaultDownloadQuality == "Original" {
            if originalAvailable { return .original }
            // No raw original, but the compatible remux preserves original quality → prefer it.
            if compatibleRemuxAvailable { return .optimizeCompatible }
        }
        if presets.contains(defaultDownloadQuality) { return .optimize(defaultDownloadQuality) }
        if let match = presets.first(where: { $0.localizedCaseInsensitiveContains(defaultDownloadQuality) }) {
            return .optimize(match)
        }
        // When nothing else matched, prefer the quality-preserving remux over a downscale preset.
        if compatibleRemuxAvailable, !originalAvailable { return .optimizeCompatible }
        return presets.first.map { .optimize($0) }
    }

    private func managerChoice(for selection: DownloadSelection) -> DownloadManager.DownloadChoice {
        switch selection {
        case .original: return .original
        case .optimizeCompatible: return .optimizeCompatible
        case .optimize(let preset): return .optimize(targetName: preset)
        }
    }

    private func selectedMediaSourceID(media: Media?, part: Part?) -> String? {
        let keys = [part?.key] + (media?.part.map(\.key) ?? [])
        for key in keys.compactMap({ $0 }) {
            guard let marker = key.range(of: "/media/") else { continue }
            let source = String(key[marker.upperBound...])
            if !source.isEmpty { return source }
        }
        return nil
    }

    // MARK: - Already-downloaded state

    @ViewBuilder
    private func existingSection(_ record: DownloadRecord) -> some View {
        let isComplete = record.isComplete
        let isFailed = record.status == .failed
        let isPaused = record.status == .paused
        SwiftUI.Section {
            if isComplete {
                if record.isUnverified {
                    Label("Downloaded; playback not verified", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.yellow)
                } else {
                    Label("Downloaded for offline viewing", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Text(ByteCountFormatter.string(fromByteCount: Int64(record.bytes), countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            } else if isFailed {
                Label("Download failed", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                Button {
                    retryDownload()
                    dismiss()
                } label: { Label("Retry Download", systemImage: "arrow.clockwise") }
            } else if isPaused {
                Label("Download paused", systemImage: "pause.circle")
                    .foregroundStyle(.secondary)
                if record.bytes > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(record.bytes), countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    retryDownload()
                    dismiss()
                } label: { Label("Resume Download", systemImage: "play.circle") }
            } else {
                Label("Downloading…", systemImage: "arrow.down.circle")
                ProgressView(value: record.progress)
                Text("\(Int(record.progress * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                downloadManager.delete(ratingKey: downloadManager.recordKey(for: item, backend: appModel.activeBackend.downloadBackendKind))
                dismiss()
            } label: {
                Label(isComplete ? "Remove Download" : "Cancel Download", systemImage: "trash")
            }
        }
    }

    // MARK: - Action

    private func retryDownload() {
        // Exhaustive over the backend so a new lane is a compile error here, not a silent
        // fall-through into the Plex retry path (which would mis-key and no-op for Emby).
        switch appModel.activeBackend {
        case .plex:
            downloadManager.retry(ratingKey: item.ratingKey)
        case .jellyfin:
            downloadManager.retry(ratingKey: downloadManager.recordKey(for: item, backend: appModel.activeBackend.downloadBackendKind))
        case .emby:
            // Re-run the full Emby lane, which re-probes PlaybackInfo and re-decides original vs
            // transcode (a now-compatible file goes original). `.original` is intent-only here.
            downloadManager.retry(ratingKey: downloadManager.recordKey(for: item, backend: appModel.activeBackend.downloadBackendKind))
        }
    }

    private func startDownload() {
        guard let selectedChoice else { return }
        let choice = managerChoice(for: selectedChoice)
        // Exhaustive over the backend so a new lane is a compile error here, not a silent
        // fall-through into the Plex download path (which fails quietly on nil Plex creds).
        switch appModel.activeBackend {
        case .plex:
            Task { await downloadManager.download(item, choice: choice,
                                                  mediaIndex: mediaIndex, partIndex: partIndex) }
        case .jellyfin:
            Task { await downloadManager.downloadJellyfin(item, choice: choice,
                                                          mediaIndex: mediaIndex,
                                                          partIndex: partIndex) }
        case .emby:
            Task { await downloadManager.downloadEmby(item, choice: choice,
                                                      mediaIndex: mediaIndex,
                                                      partIndex: partIndex) }
        }
        dismiss()
    }
}
