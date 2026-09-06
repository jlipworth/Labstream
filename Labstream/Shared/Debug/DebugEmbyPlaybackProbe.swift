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
    private static let log = Logger(subsystem: "org.labstream.Labstream", category: "EmbyProbe")

    static func runIfRequested(appModel: AppModel) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--vp-probe-emby-playback") else { return }

        await DebugPlaybackProbeSupport.withTemporaryDiagnosticsEnabled {
            await run(arguments: arguments, appModel: appModel)
        }
    }

    private static func run(arguments: [String], appModel: AppModel) async {
        guard let options = DebugPlaybackProbeSupport.launchOptions(from: arguments,
                                                                    defaultBitrateKbps: 0) else {
            log.error("probe.fail reason=missing_probe_query")
            DebugPlaybackScenario.blocked(arguments, reason: .invalidOptions)
            DebugPlaybackProbeSupport.recordMissingQuery(eventName: "probe.emby.fail")
            return
        }
        guard DebugPlaybackScenario.admitted(arguments, bitrateKbps: options.bitrateKbps) else { return }
        let query = options.query
        let bitrateKbps = options.bitrateKbps
        let seekMs = options.seekMs

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
            DebugPlaybackScenario.blocked(arguments, reason: .missingAuth)
            return
        }

        let service = EmbyBrowseService(appModel: appModel)
        var controller: PlaybackController?
        var scenarioOwnsCleanup = false
        do {
            let item = try await resolveItem(query: query, service: service)
            let detailed = (try? await service.metadata(itemId: item.ratingKey)) ?? item
            log.notice("probe.item_resolved type=\(detailed.type, privacy: .public) duration_ms=\(detailed.duration ?? 0, privacy: .public) chapters=\((detailed.chapters?.count ?? 0), privacy: .public)")

            let opened = try await DetailPlaybackLauncher.open(item: detailed,
                                                               backend: .emby,
                                                               appModel: appModel,
                                                               mediaIndex: DebugPlaybackProbeSupport.intValue(after: "--vp-probe-media-index", in: arguments) ?? 0,
                                                               maxVideoBitrateKbps: bitrateKbps)
            if arguments.contains("--vp-probe-bare-player"), opened.playback.playMethod == .directPlay {
                await DebugRawURLPlaybackProbe.run(url: opened.playback.url,
                    headers: opened.playback.headers, arguments: arguments)
                return
            }
            if arguments.contains("--vp-probe-decision-only") {
                // Bounded control-plane probe: do not hand any media URL to AVPlayer.
                // Never log the URL, auth, source/session IDs, or arbitrary query values.
                let components = URLComponents(url: opened.playback.url, resolvingAgainstBaseURL: false)
                let query = components?.queryItems ?? []
                let container = query.first { $0.name.lowercased() == "segmentcontainer" }?.value ?? ""
                let safeContainer = ["m4s", "mp4", "ts", "m4s,ts"].contains(container) ? container : "unknown"
                let codec = query.first { $0.name.lowercased() == "videocodec" }?.value ?? ""
                let safeCodec = ["copy", "hevc", "h264", "h264,hevc", "hevc,h264"].contains(codec) ? codec : "unknown"
                log.notice("probe.decision_only method=\(opened.playback.playMethod.rawValue, privacy: .public) segment_container=\(safeContainer, privacy: .public) video_codec=\(safeCodec, privacy: .public)")
                try? await Task.sleep(for: .seconds(5))
                _ = await DetailPlaybackLauncher.stopActiveEncodingNow(remote: opened.playback, appModel: appModel)
                log.notice("probe.decision_only_stopped")
                return
            }
            let playback = DetailPlaybackLauncher.playbackController(
                remote: opened.playback,
                item: detailed,
                appModel: appModel,
                maxVideoBitrateKbps: bitrateKbps,
                qualityDefaultsKey: appModel.activeStreamingQualityDefaultsKey)
            controller = playback
            scenarioOwnsCleanup = true
            controller = nil // The named scenario owns cleanup from this point, including errors.
            try await DebugPlaybackScenario.run(playback, options: options, arguments: arguments,
                backendIsCurrent: { appModel.activeBackend == .emby && appModel.isBrowseReady }, log: log)
            log.notice("probe.pass scenario_completed=true")
            controller = nil
        } catch {
            if !scenarioOwnsCleanup { DebugPlaybackScenario.blocked(arguments, reason: .playbackFailed) }
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
