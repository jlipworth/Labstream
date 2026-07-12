#if DEBUG
import Foundation
import os
import PMSKit

/// Launch-argument driven simulator probe for Emby playback/seek.
///
/// Mirrors `DebugJellyfinPlaybackProbe`: it runs inside the signed-in app process on the
/// booted simulator so it reuses the app's Keychain Emby session and drives the SAME
/// AVPlayer/PlaybackController path as the UI. Unlike the headless PMSKit probe (which
/// cannot advance an AVPlayer playhead without a render surface), the simulator IS a render
/// surface, so this validates real playback start, playhead advance, and seek.
///
/// Inert unless launched with `--vp-probe-emby-playback`. Requires the app to already be
/// signed in to Emby (the probe does not authenticate; sign in once via the UI first).
@MainActor
enum DebugEmbyPlaybackProbe {
    private static let log = Logger(subsystem: "com.jlipworth.Labstream", category: "EmbyProbe")

    static func runIfRequested(appModel: AppModel) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--vp-probe-emby-playback") else { return }

        await DebugPlaybackProbeSupport.withTemporaryDiagnosticsEnabled {
            await run(arguments: arguments, appModel: appModel)
        }
    }

    private static func run(arguments: [String], appModel: AppModel) async {
        guard let options = DebugPlaybackProbeSupport.launchOptions(from: arguments,
                                                                    defaultBitrateKbps: appModel.activeStreamingQualityKbps) else {
            log.error("probe.fail reason=missing_probe_query")
            DebugPlaybackProbeSupport.recordMissingQuery(eventName: "probe.emby.fail")
            return
        }
        let query = options.query
        let bitrateKbps = options.bitrateKbps
        let seekMs = options.seekMs
        let postSeekHoldSeconds = options.postSeekHoldSeconds

        let querySummary = DebugPlaybackProbeSupport.querySummary(query)
        log.notice("probe.start backend=\(appModel.activeBackend.rawValue, privacy: .public) query=\(querySummary, privacy: .public) bitrate_kbps=\(bitrateKbps, privacy: .public) seek_ms=\(seekMs, privacy: .public)")
        AppDiagnostics.record(.playback, "probe.emby.start", fields: DebugPlaybackProbeSupport.startFields(
            backend: appModel.activeBackend.rawValue,
            query: query,
            bitrateKbps: bitrateKbps,
            seekMs: seekMs
        ))

        guard appModel.activeBackend == .emby, appModel.isBrowseReady else {
            log.error("probe.fail reason=not_emby_or_not_ready")
            return
        }

        let service = EmbyBrowseService(appModel: appModel)
        var controller: PlaybackController?
        do {
            let item = try await resolveItem(query: query, service: service)
            let detailed = (try? await service.metadata(itemId: item.ratingKey)) ?? item
            log.notice("probe.item_resolved type=\(detailed.type, privacy: .public) duration_ms=\(detailed.duration ?? 0, privacy: .public) chapters=\((detailed.chapters?.count ?? 0), privacy: .public)")

            let opened = try await DetailPlaybackLauncher.open(item: detailed,
                                                               backend: .emby,
                                                               appModel: appModel,
                                                               maxVideoBitrateKbps: bitrateKbps)
            let playback = DetailPlaybackLauncher.playbackController(
                remote: opened.playback,
                item: detailed,
                appModel: appModel,
                maxVideoBitrateKbps: bitrateKbps,
                qualityDefaultsKey: appModel.activeStreamingQualityDefaultsKey)
            controller = playback
            playback.start()

            try await DebugPlaybackProbeSupport.waitUntilPlayable(playback, phase: "initial", timeoutSeconds: options.playableTimeoutSeconds)
            log.notice("probe.initial_playing position_ms=\(playback.currentResumeMs, privacy: .public)")
            await DebugPlaybackProbeSupport.logActiveVideoFormat(playback, phase: "initial", log: log)
            await DebugPlaybackFrameCapture.captureIfRequested(from: playback.player, label: "emby-initial", log: log)

            playback.performUserSeek(toMs: seekMs)
            try await DebugPlaybackProbeSupport.waitUntilPlayable(playback, phase: "post_seek", timeoutSeconds: options.playableTimeoutSeconds)
            try await DebugPlaybackProbeSupport.holdWithPlaybackProgress(playback, seconds: postSeekHoldSeconds, stallToleranceSeconds: options.stallToleranceSeconds, log: log)
            await DebugPlaybackProbeSupport.logActiveVideoFormat(playback, phase: "post_seek", log: log)
            await DebugPlaybackFrameCapture.captureIfRequested(from: playback.player, label: "emby-postseek", log: log)

            log.notice("probe.pass position_ms=\(playback.currentResumeMs, privacy: .public) failed=\(playback.playbackError.isFailed, privacy: .public)")
            AppDiagnostics.record(.playback, "probe.emby.pass", fields: [
                "resume": .millisecondsBucket(playback.currentResumeMs),
                "target": .millisecondsBucket(seekMs),
            ])
            playback.stop()
            controller = nil
        } catch {
            log.error("probe.fail error=\(DiagnosticRedactor.safeErrorSummary(error), privacy: .public)")
            AppDiagnostics.record(.playback, "probe.emby.fail", fields: [
                "error": .error(error),
            ])
            controller?.stop()
        }
    }

    private static func resolveItem(query: String, service: EmbyBrowseService) async throws -> MediaItem {
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
