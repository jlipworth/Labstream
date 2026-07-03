#if DEBUG
import Foundation
import os
import PMSKit

/// Launch-argument driven simulator probe for Jellyfin playback/seek bugs.
///
/// This intentionally runs inside the signed-in app process instead of from a host-side
/// CLI so it can reuse the app's Keychain credentials and the same AVPlayer/
/// PlaybackController path as the UI. It is inert unless explicitly launched with
/// `--vp-probe-jellyfin-playback`.
@MainActor
enum DebugJellyfinPlaybackProbe {
    private static let log = Logger(subsystem: "com.jlipworth.VisionPlay", category: "JellyfinProbe")

    static func runIfRequested(appModel: AppModel) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--vp-probe-jellyfin-playback") else { return }

        await DebugPlaybackProbeSupport.withTemporaryDiagnosticsEnabled {
            await run(arguments: arguments, appModel: appModel)
        }
    }

    private static func run(arguments: [String], appModel: AppModel) async {
        guard let options = DebugPlaybackProbeSupport.launchOptions(from: arguments,
                                                                    defaultBitrateKbps: appModel.activeStreamingQualityKbps) else {
            log.error("probe.fail reason=missing_probe_query")
            DebugPlaybackProbeSupport.recordMissingQuery(eventName: "probe.jellyfin.fail")
            return
        }
        let query = options.query
        let bitrateKbps = options.bitrateKbps
        let seekMs = options.seekMs
        let postSeekHoldSeconds = options.postSeekHoldSeconds

        let querySummary = DebugPlaybackProbeSupport.querySummary(query)
        log.notice("probe.start backend=\(appModel.activeBackend.rawValue, privacy: .public) query=\(querySummary, privacy: .public) bitrate_kbps=\(bitrateKbps, privacy: .public) seek_ms=\(seekMs, privacy: .public)")
        AppDiagnostics.record(.playback, "probe.jellyfin.start", fields: DebugPlaybackProbeSupport.startFields(
            backend: appModel.activeBackend.rawValue,
            query: query,
            bitrateKbps: bitrateKbps,
            seekMs: seekMs
        ))

        guard appModel.activeBackend == .jellyfin, appModel.isBrowseReady else {
            log.error("probe.fail reason=not_jellyfin_or_not_ready")
            return
        }

        let service = JellyfinBrowseService(appModel: appModel)
        var controller: PlaybackController?
        do {
            let item = try await resolveItem(query: query, service: service)
            let detailed = (try? await service.metadata(itemId: item.ratingKey)) ?? item
            log.notice("probe.item_resolved type=\(detailed.type, privacy: .public) duration_ms=\(detailed.duration ?? 0, privacy: .public) chapters=\((detailed.chapters?.count ?? 0), privacy: .public)")

            let opened = try await DetailPlaybackLauncher.openJellyfin(item: detailed,
                                                                      appModel: appModel,
                                                                      maxVideoBitrateKbps: bitrateKbps)
            let playback = DetailPlaybackLauncher.jellyfinPlaybackController(
                remote: opened.playback,
                item: detailed,
                appModel: appModel,
                maxVideoBitrateKbps: bitrateKbps,
                qualityDefaultsKey: appModel.activeStreamingQualityDefaultsKey)
            controller = playback
            playback.start()

            try await DebugPlaybackProbeSupport.waitUntilPlayable(playback, phase: "initial", timeoutSeconds: 45)
            log.notice("probe.initial_playing position_ms=\(playback.currentResumeMs, privacy: .public)")
            await DebugPlaybackFrameCapture.captureIfRequested(from: playback.player, label: "jellyfin-initial", log: log)

            playback.performUserSeek(toMs: seekMs)
            try await DebugPlaybackProbeSupport.waitUntilPlayable(playback, phase: "post_seek", timeoutSeconds: 45)
            try await DebugPlaybackProbeSupport.holdWithPlaybackProgress(playback, seconds: postSeekHoldSeconds, log: log)
            await DebugPlaybackFrameCapture.captureIfRequested(from: playback.player, label: "jellyfin-postseek", log: log)

            log.notice("probe.pass position_ms=\(playback.currentResumeMs, privacy: .public) failed=\(playback.playbackError.isFailed, privacy: .public)")
            AppDiagnostics.record(.playback, "probe.jellyfin.pass", fields: [
                "resume": .millisecondsBucket(playback.currentResumeMs),
                "target": .millisecondsBucket(seekMs),
            ])
            playback.stop()
            controller = nil
        } catch {
            log.error("probe.fail error=\(DiagnosticRedactor.safeErrorSummary(error), privacy: .public)")
            AppDiagnostics.record(.playback, "probe.jellyfin.fail", fields: [
                "error": .error(error),
            ])
            controller?.stop()
        }
    }

    private static func resolveItem(query: String, service: JellyfinBrowseService) async throws -> MediaItem {
        let items = try await service.items(parentId: nil,
                                            recursive: true,
                                            limit: 20,
                                            searchTerm: query,
                                            sortBy: "SortName",
                                            sortOrder: "Ascending",
                                            includeItemTypes: "Movie,Episode")
        if let exact = items.first(where: { $0.title.localizedCaseInsensitiveCompare(query) == .orderedSame && !$0.isContainer }) {
            return exact
        }
        if let playable = items.first(where: { !$0.isContainer && !$0.isMusic }) {
            return playable
        }
        throw DebugPlaybackProbeSupport.ProbeError.itemNotFound(query)
    }

}
#endif
