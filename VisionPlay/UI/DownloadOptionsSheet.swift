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
    var backend: DownloadBackendKind? = nil

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
                   originalStreamableButOfflineUnsupported: Bool,
                   existingVersions: [ExistingVersionOption])
    }

    /// #112: an existing server-generated Plex Version offered as an explicit, separate download
    /// choice. Carries the `Media` array index it lives at (so the download addresses that exact
    /// version/part) plus a human label built from its resolution/codec/bitrate/container.
    private struct ExistingVersionOption: Equatable, Identifiable {
        /// Stable row identity within the sheet (Plex: the `Media` array index; Emby: enumeration
        /// order). A sheet is single-backend, so these never collide.
        let id: Int
        let label: String
        let detail: String?
        let sizeBytes: Int?
        /// #125: whether this alternate's container/codec can play back offline as a standalone
        /// local file. Incompatible versions are shown DISABLED rather than hidden so the user
        /// understands why they can't pick them.
        let playableOffline: Bool
        /// What picking this row selects. Plex addresses a `Media` index (#112); Emby addresses a
        /// PlaybackInfo MediaSource id (#126) — different models, same row UI.
        let selection: DownloadSelection
    }

    private enum DownloadSelection: Equatable {
        case original
        case plexOriginalQuality(String)
        case optimizeCompatible
        case optimize(String)
        /// #112: download an existing Plex server version exactly as-is (by `Media` index).
        case existingVersion(Int)
        /// #126: download an existing Emby server version (a "Convert Media" copy) byte-for-byte,
        /// addressed by its PlaybackInfo MediaSource id. `sizeBytes` is the converted source's own
        /// size for the storage-limit pre-check (the source `Media` index can't supply it).
        case embyExistingVersion(mediaSourceId: String, sizeBytes: Int?)
    }

    @State private var probeState: ProbeState = .checking
    @State private var selectedChoice: DownloadSelection?
    @State private var retryingExistingDownload = false

    private var sheetBackend: DownloadBackendKind {
        backend ?? appModel.activeBackend.downloadBackendKind
    }

    private var existingRecord: DownloadRecord? {
        let key = downloadManager.recordKey(for: item, backend: sheetBackend)
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
                    case let .ready(original, compatibleRemux, presets, probeFailed, unsupportedOriginal, existingVersions):
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
                        // #112: existing server versions go BELOW the quality presets as a distinct section.
                        if !existingVersions.isEmpty {
                            existingVersionsSection(existingVersions)
                        }
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
        downloadLog.notice("download-sheet-run-probe item=\(item.ratingKey, privacy: .public) activeBackend=\(String(describing: sheetBackend), privacy: .public) mediaIndex=\(mediaIndex, privacy: .public)")
        if sheetBackend == .jellyfin {
            await runJellyfinProbe()
            return
        }
        if sheetBackend == .emby {
            await runEmbyProbe()
            return
        }
        guard let token = appModel.serverToken, let server = appModel.serverBaseURL else {
            let presets = defaultPresets
            selectedChoice = .optimize(presets[0])
            probeState = .ready(original: nil, compatibleRemux: nil, presets: presets, probeFailed: true,
                                originalStreamableButOfflineUnsupported: false,
                                existingVersions: plexExistingVersions())
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
        // Source-quality defaulting is PRESERVED: existing server versions are an explicit extra,
        // never the default — `preferredSelection` is unchanged and ignores them.
        selectedChoice = preferredSelection(originalAvailable: original != nil,
                                            compatibleRemuxAvailable: false, presets: presets)
        probeState = .ready(original: original, compatibleRemux: nil, presets: presets, probeFailed: false,
                            originalStreamableButOfflineUnsupported: unsupportedOriginal,
                            existingVersions: plexExistingVersions())
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
                                    originalStreamableButOfflineUnsupported: original == nil,
                                    existingVersions: [])
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
                    downloadLog.error("download-sheet-jellyfin-probe-failed item=\(item.ratingKey, privacy: .public) error=\(DiagnosticRedactor.safeErrorSummary(error), privacy: .public)")
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
                            originalStreamableButOfflineUnsupported: original == nil && compatibleRemux == nil,
                            existingVersions: [])
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
                                originalStreamableButOfflineUnsupported: false,
                                existingVersions: [])
            return
        }

        let identity = appModel.identity.emby
        var negotiatedDirectPlay = false
        var negotiatedContainer: String?
        var negotiatedVideoCodec: String?
        var negotiatedAudioCodec: String?
        var probeFailed = false
        // #126: existing server-side converted versions ("Convert Media" copies) surfaced from the
        // SAME PlaybackInfo call that probes the primary source — no extra round trip.
        var existingVersions: [ExistingVersionOption] = []
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

        // #126/#133: enumerate existing converted versions from an UNFILTERED PlaybackInfo. Emby
        // filters the response to a single source when a MediaSourceId is supplied (the primary
        // probe above passes one, so it can NEVER see the alternates), so this dedicated call passes
        // nil to get every source. If nothing is visible, ask Emby to refresh just this item and poll
        // briefly: live testing showed completed Sync/Convert MP4 files can exist on disk while
        // PlaybackInfo remains stale. Best-effort: a failure here just means no existing-version rows,
        // never a failed sheet. The primary (offered above via Original/Remux/Optimize) is
        // `mediaSourceId`.
        do {
            existingVersions = try await embyExistingVersionsWithRefresh(
                server: server, token: token, identity: identity, userId: userId,
                itemId: item.ratingKey, selectedMediaSourceId: mediaSourceId)
        } catch {
            // Leave existingVersions empty; the sheet still offers the normal lanes.
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
                            originalStreamableButOfflineUnsupported: unsupportedOriginal,
                            existingVersions: existingVersions)
    }

    /// #126: map Emby PlaybackInfo alternate sources to existing-version download rows, applying the
    /// same offline-compatibility gate as the Plex lane (#125) so an incompatible alternate is shown
    /// disabled rather than hidden.
    private static func embyExistingVersionOptions(
        response: EmbyPlaybackInfoResponse,
        primaryMediaSourceId: String?) -> [ExistingVersionOption] {
        EmbyPlayback.existingDownloadableVersions(
            response: response, primaryMediaSourceId: primaryMediaSourceId
        ).enumerated().map { index, version in
            let playableOffline = version.supportsDirectPlay
                && OfflineDownloadDecision.existingVersionPlayableOffline(
                    container: version.container, videoCodec: version.videoCodec)
            return ExistingVersionOption(
                id: index,
                label: embyVersionLabel(version),
                detail: embyVersionDetail(version),
                sizeBytes: version.size,
                playableOffline: playableOffline,
                selection: .embyExistingVersion(mediaSourceId: version.mediaSourceId,
                                                sizeBytes: version.size))
        }
    }

    private func embyExistingVersionsWithRefresh(server: URL,
                                                 token: String,
                                                 identity: EmbyClientIdentity,
                                                 userId: String,
                                                 itemId: String,
                                                 selectedMediaSourceId: String?) async throws -> [ExistingVersionOption] {
        func fetch() async throws -> [ExistingVersionOption] {
            let allReq = try EmbyPlayback.downloadPlaybackInfoRequest(
                server: server, token: token, identity: identity,
                userId: userId, itemId: itemId,
                mediaSourceId: nil,
                maxStaticBitrate: 200_000_000)
            let (data, response) = try await URLSession.shared.data(for: allReq)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            let info = try EmbyPlaybackInfoResponse.decode(from: data)
            // Exclude the source the main options already cover. Prefer the selected source id; fall
            // back to the unfiltered decision's chosen primary when none was resolved.
            let primaryId = selectedMediaSourceId
                ?? (try? EmbyPlayback.downloadDecision(response: info))?.mediaSourceId
            return Self.embyExistingVersionOptions(response: info, primaryMediaSourceId: primaryId)
        }

        let initial = try await fetch()
        if !initial.isEmpty { return initial }

        let refresh = try EmbyConvertRequest.itemRefreshRequest(server: server, token: token,
                                                                identity: identity, userId: userId,
                                                                itemId: itemId)
        let (_, refreshResponse) = try await URLSession.shared.data(for: refresh)
        if let http = refreshResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return []
        }
        for attempt in 0..<2 {
            let refreshed = try await fetch()
            if !refreshed.isEmpty { return refreshed }
            if attempt < 1 { try? await Task.sleep(for: .seconds(5)) }
        }
        return []
    }

    /// Primary label for an Emby existing-version row: resolution · codec · bitrate (Emby `Bitrate`
    /// is bits/sec). Falls back to the source name, then a generic label.
    private static func embyVersionLabel(_ version: EmbyPlayback.EmbyExistingVersion) -> String {
        var parts: [String] = []
        if let resolution = DownloadResolutionLabel.label(width: version.width, height: version.height) {
            parts.append(resolution)
        }
        if let codec = version.videoCodec?.uppercased(), !codec.isEmpty { parts.append(codec) }
        if let bitrate = version.bitrate, bitrate > 0 {
            parts.append(String(format: "%.1f Mbps", Double(bitrate) / 1_000_000))
        }
        if parts.isEmpty, let name = version.name, !name.isEmpty { return name }
        return parts.isEmpty ? "Server version" : parts.joined(separator: " · ")
    }

    /// Secondary caption for an Emby existing-version row: container + file size where available.
    private static func embyVersionDetail(_ version: EmbyPlayback.EmbyExistingVersion) -> String? {
        var parts: [String] = []
        if let container = version.container?.uppercased(), !container.isEmpty { parts.append(container) }
        if let size = version.size, size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var defaultPresets: [String] {
        filteredOptimizePresets([
            "Original video quality",
            "4K 40 Mbps",
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
            "4K 40 Mbps",
            "1080p 20 Mbps", "1080p 12 Mbps", "1080p 10 Mbps",
            "1080p 8 Mbps", "720p 4 Mbps", "720p 3 Mbps",
            "720p 2 Mbps", "480p 1.5 Mbps"
        ]
    }

    // Emby has no server-side optimize-target list (Plex-only), so the picker uses the same
    // hard-coded bitrate ladder as Jellyfin; the manager maps each preset to a transcode profile.
    private var embyPresets: [String] {
        [
            "4K 40 Mbps",
            "1080p 20 Mbps", "1080p 12 Mbps", "1080p 10 Mbps",
            "1080p 8 Mbps", "720p 4 Mbps", "720p 3 Mbps",
            "720p 2 Mbps", "480p 1.5 Mbps"
        ]
    }


    private func plexOriginalOptimizePreset(in presets: [String]) -> String? {
        guard sheetBackend == .plex else { return nil }
        return presets.first {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare("Original video quality") == .orderedSame
        }
    }

    private func optimizePresetsExcludingPlexOriginal(_ presets: [String]) -> [String] {
        guard plexOriginalOptimizePreset(in: presets) != nil else { return presets }
        return presets.filter {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare("Original video quality") != .orderedSame
        }
    }

    // MARK: - Existing server versions (#112)

    /// Existing server-generated Plex Versions to offer as explicit download choices, derived from
    /// the item's `Media` array SEPARATELY from the source media at `mediaIndex`. Every other
    /// `Media` entry that carries a downloadable part is surfaced — these are the redundant/
    /// pre-rendered versions Plex already keeps on the server. Plex-only (Jellyfin/Emby model the
    /// alternate versions differently and use the compatible-remux lane), and never offered when
    /// the item has a single version.
    private func plexExistingVersions() -> [ExistingVersionOption] {
        guard sheetBackend == .plex, let media = item.media, media.count > 1 else {
            downloadLog.notice("download-sheet-existing-versions item=\(item.ratingKey, privacy: .public) mediaCount=\(item.media?.count ?? 0, privacy: .public) offered=0")
            return []
        }
        let result: [ExistingVersionOption] = media.enumerated().compactMap { index, m -> ExistingVersionOption? in
            // The selected source version is offered through the normal quality options above, not
            // as an "existing version" — skip it.
            guard index != mediaIndex else { return nil }
            // A version is only downloadable if it exposes a part with a streamable key.
            guard let part = m.part.first, !part.key.isEmpty else { return nil }
            // #125: this lane has NO offline-compatibility preflight, so gate here on Media-level
            // container/codec (reliably present for every alternate). Fall back to media.container
            // like versionDetail so an empty part container doesn't fail open. Incompatible
            // versions stay visible but disabled (see existingVersionsSection).
            let playableOffline = OfflineDownloadDecision.existingVersionPlayableOffline(
                container: part.container ?? m.container,
                videoCodec: m.videoCodec)
            return ExistingVersionOption(id: index,
                                         label: Self.versionLabel(m),
                                         detail: Self.versionDetail(media: m, part: part),
                                         sizeBytes: part.size,
                                         playableOffline: playableOffline,
                                         selection: .existingVersion(index))
        }
        let blocked = result.filter { !$0.playableOffline }.count
        downloadLog.notice("download-sheet-existing-versions item=\(item.ratingKey, privacy: .public) mediaCount=\(media.count, privacy: .public) sourceMediaIndex=\(mediaIndex, privacy: .public) offered=\(result.count, privacy: .public) blockedOffline=\(blocked, privacy: .public) labels=\(result.map(\.label).joined(separator: " | "), privacy: .public)")
        return result
    }

    /// Primary label for an existing-version row: resolution · codec · bitrate, e.g. "1080p · H264 · 8.0 Mbps".
    private static func versionLabel(_ media: Media) -> String {
        var parts: [String] = []
        if let res = DownloadManager.resolutionLabel(for: media) { parts.append(res) }
        if let codec = media.videoCodec?.uppercased(), !codec.isEmpty { parts.append(codec) }
        if let bitrate = media.bitrate, bitrate > 0 {
            parts.append(String(format: "%.1f Mbps", Double(bitrate) / 1000))
        }
        return parts.isEmpty ? "Server version" : parts.joined(separator: " · ")
    }

    /// Secondary caption for an existing-version row: container + file size where available.
    private static func versionDetail(media: Media, part: Part) -> String? {
        var parts: [String] = []
        if let container = (part.container ?? media.container)?.uppercased(), !container.isEmpty {
            parts.append(container)
        }
        if let size = part.size, size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
            Text("Downloads the raw source file without server conversion. This is the most resumable route when the server supports byte ranges.")
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
            Label {
                Text("Keeps original video quality by copying/remuxing into a compatible MP4 (audio is converted only if needed). This is not an optimized server version; it can be slower and restarts from the beginning if interrupted.")
            } icon: {
                Image(systemName: "info.circle")
            }
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
                selectedChoice = .plexOriginalQuality(preset)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Original video quality").foregroundStyle(.primary)
                        Text("Keeps the source quality in a compatible Plex-prepared copy")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selectedChoice == .plexOriginalQuality(preset) {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } header: {
            Text("Original quality")
        } footer: {
            Label {
                Text("Creates a compatible offline copy at Plex's original video quality. Plex may prepare the file on the server before downloading.")
            } icon: {
                Image(systemName: "info.circle")
            }
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
            Label {
                Text(probeFailed
                     ? "Couldn't check compatibility, so your server will render a compatible version. This can take a while, uses server CPU/GPU, and may restart instead of resuming if interrupted."
                     : originalAvailable
                        ? "Your server renders a bitrate-capped compatible copy. This can take a while, uses server CPU/GPU, and may restart instead of resuming if interrupted."
                        : "Your server renders a compatible offline version. This can take a while, uses server CPU/GPU, and may restart instead of resuming if interrupted.")
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
        }
        .onAppear {
            if selectedChoice == .original, originalAvailable {
                return
            }
            // Original-quality helper selections are self-contained (not in this preset list); leave
            // them intact.
            if selectedChoice == .optimizeCompatible { return }
            if case .plexOriginalQuality = selectedChoice { return }
            // #112/#126: an explicit existing-version pick is self-contained; never clobber it.
            if case .existingVersion = selectedChoice { return }
            if case .embyExistingVersion = selectedChoice { return }
            if case .optimize(let selected)? = selectedChoice, allPresets.contains(selected) {
                return
            }
            selectedChoice = preferredSelection(originalAvailable: originalAvailable,
                                                compatibleRemuxAvailable: false, presets: allPresets)
        }
    }

    @ViewBuilder
    private func existingVersionsSection(_ versions: [ExistingVersionOption]) -> some View {
        SwiftUI.Section {
            ForEach(versions) { version in
                Button {
                    selectedChoice = version.selection
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "rectangle.stack.badge.play")
                            .foregroundStyle(version.playableOffline ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(version.label)
                                .foregroundStyle(version.playableOffline ? .primary : .secondary)
                            if let detail = version.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if !version.playableOffline {
                                Text("Won't play offline on this device")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if version.playableOffline, selectedChoice == version.selection {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!version.playableOffline)
            }
        } header: {
            Text("Existing server versions")
        } footer: {
            Text("Downloads a version your server already has, exactly as-is — no new conversion is started and the server's existing copy is left in place.")
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
        // #126: an Emby existing version is addressed by MediaSource id, not a `Media` index, so the
        // estimator can't size it — use the converted source's own reported size for the pre-check.
        let addedBytes: Int?
        if case .embyExistingVersion(_, let sizeBytes) = selectedChoice {
            addedBytes = sizeBytes
        } else {
            addedBytes = downloadManager.estimatedBytes(
                for: item, choice: managerChoice(for: selectedChoice),
                mediaIndex: mediaIndex(for: selectedChoice),
                partIndex: partIndex(for: selectedChoice))
        }
        return downloadManager.storageLimitMessage(adding: addedBytes)
    }

    /// The `Media` array index a selection downloads from. An existing-version pick (#112) targets
    /// that version's own index; every other choice uses the sheet's selected source `mediaIndex`.
    private func mediaIndex(for selection: DownloadSelection) -> Int {
        if case .existingVersion(let index) = selection { return index }
        return mediaIndex
    }

    /// The `Part` index a selection downloads from. An existing server version is addressed by its
    /// first (only) rendered part — the version label/size are derived from `part.first` — so it
    /// always uses part 0, independent of the source's selected `partIndex`.
    private func partIndex(for selection: DownloadSelection) -> Int {
        if case .existingVersion = selection { return 0 }
        return partIndex
    }

    private func preferredSelection(originalAvailable: Bool,
                                    compatibleRemuxAvailable: Bool,
                                    presets: [String]) -> DownloadSelection? {
        if originalAvailable { return .original }
        // If the source cannot be stored raw, default to the highest source-quality-preserving
        // option before bitrate caps. Plex's version is an optimized/prepared copy; Jellyfin/Emby
        // use the compatible remux lane.
        if sheetBackend == .plex, let plexOriginal = plexOriginalOptimizePreset(in: presets) {
            return .plexOriginalQuality(plexOriginal)
        }
        if compatibleRemuxAvailable { return .optimizeCompatible }
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
        case .plexOriginalQuality(let preset): return .optimize(targetName: preset)
        case .optimizeCompatible: return .optimizeCompatible
        case .optimize(let preset): return .optimize(targetName: preset)
        case .existingVersion: return .existingVersion
        case .embyExistingVersion: return .existingVersion
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
        let isPreparing = record.status == .preparing
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
                    guard !retryingExistingDownload else { return }
                    retryingExistingDownload = true
                    retryDownload()
                    dismiss()
                } label: { Label("Retry Download", systemImage: "arrow.clockwise") }
                .disabled(retryingExistingDownload)
            } else if isPaused {
                Label("Download paused", systemImage: "pause.circle")
                    .foregroundStyle(.secondary)
                if record.bytes > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(record.bytes), countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    guard !retryingExistingDownload else { return }
                    retryingExistingDownload = true
                    retryDownload()
                    dismiss()
                } label: { Label("Resume Download", systemImage: "play.circle") }
                .disabled(retryingExistingDownload)
            } else if isPreparing {
                // Emby convert-then-download: the server is rendering the file before any byte
                // download begins. Surface it as an indeterminate "Preparing on server…" with the
                // live convert percentage when known (same plumbing as the offline-list row).
                Label("Preparing on server…", systemImage: "gearshape.arrow.triangle.2.circlepath")
                if let p = downloadManager.optimizeProgress[record.ratingKey] {
                    ProgressView(value: p)
                    Text("\(Int(p * 100))%")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            } else {
                Label(existingDownloadPhaseLabel(for: record), systemImage: "arrow.down.circle")
                ProgressView(value: record.progress)
                Text("\(Int(record.progress * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    downloadManager.pause(ratingKey: downloadManager.recordKey(for: item, backend: sheetBackend))
                    dismiss()
                } label: { Label("Pause Download", systemImage: "pause.circle") }
            }
            Button(role: .destructive) {
                downloadManager.delete(ratingKey: downloadManager.recordKey(for: item, backend: sheetBackend))
                dismiss()
            } label: {
                Label(isComplete ? "Remove Download" : "Cancel Download", systemImage: "trash")
            }
        }
    }

    // MARK: - Action

    private func existingDownloadPhaseLabel(for record: DownloadRecord) -> String {
        let lane = record.metadata?.resolvedDownloadLane() ?? .original
        let backend = record.metadata?.resolvedBackendKind(ratingKey: record.ratingKey)
            ?? DownloadBackendKind(ratingKeyPrefix: record.ratingKey)
        switch lane {
        case .original where record.metadata?.isServerPreparedVersion == true:
            return "Downloading transcode…"
        case .original:
            return "Downloading…"
        case .compatibleRemux:
            return "Remuxing + downloading…"
        case .optimize:
            return backend == .plex ? "Downloading transcode…" : "Transcoding + downloading…"
        }
    }

    private func retryDownload() {
        // Exhaustive over the backend so a new lane is a compile error here, not a silent
        // fall-through into the Plex retry path (which would mis-key and no-op for Emby).
        switch sheetBackend {
        case .plex:
            downloadManager.retry(ratingKey: item.ratingKey)
        case .jellyfin:
            downloadManager.retry(ratingKey: downloadManager.recordKey(for: item, backend: sheetBackend))
        case .emby:
            // Re-run the full Emby lane, which re-probes PlaybackInfo and re-decides original vs
            // transcode (a now-compatible file goes original). `.original` is intent-only here.
            downloadManager.retry(ratingKey: downloadManager.recordKey(for: item, backend: sheetBackend))
        }
    }

    private func startDownload() {
        guard let selectedChoice else { return }
        let choice = managerChoice(for: selectedChoice)
        // #112: an existing-version pick downloads from THAT version's `Media` index (part 0), not
        // the selected source index. Every other choice resolves to the sheet's media/part index.
        let downloadMediaIndex = mediaIndex(for: selectedChoice)
        let downloadPartIndex = partIndex(for: selectedChoice)
        // Exhaustive over the backend so a new lane is a compile error here, not a silent
        // fall-through into the Plex download path (which fails quietly on nil Plex creds).
        switch sheetBackend {
        case .plex:
            Task { await downloadManager.download(item, choice: choice,
                                                  mediaIndex: downloadMediaIndex, partIndex: downloadPartIndex) }
        case .jellyfin:
            Task { await downloadManager.downloadJellyfin(item, choice: choice,
                                                          mediaIndex: downloadMediaIndex,
                                                          partIndex: downloadPartIndex) }
        case .emby:
            // #126: an existing-version pick addresses a specific converted MediaSource by id; pass
            // it as the override so the lane downloads THAT copy byte-for-byte (no new conversion).
            if case .embyExistingVersion(let mediaSourceId, _) = selectedChoice {
                Task { await downloadManager.downloadEmby(item, choice: choice,
                                                          mediaIndex: downloadMediaIndex,
                                                          partIndex: downloadPartIndex,
                                                          mediaSourceIDOverride: mediaSourceId) }
            } else {
                Task { await downloadManager.downloadEmby(item, choice: choice,
                                                          mediaIndex: downloadMediaIndex,
                                                          partIndex: downloadPartIndex) }
            }
        }
        dismiss()
    }
}
