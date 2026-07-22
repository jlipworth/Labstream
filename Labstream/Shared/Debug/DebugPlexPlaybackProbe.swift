#if DEBUG
import Foundation
import os
import PMSKit

/// Launch-argument driven simulator probe for Plex playback/seek.
///
/// Mirrors `DebugEmbyPlaybackProbe`: runs inside the signed-in app process on the booted
/// simulator, reuses the app's restored Plex server context, and drives the SAME
/// `PlaybackController`/AVPlayer path as the UI — so "never loads" reproductions (#196)
/// can be run and log-inspected hands-free instead of tapping through the sim.
///
/// Inert unless launched with `--vp-probe-plex-playback`. Requires the app to already be
/// signed in to Plex with a server selected.
@MainActor
enum DebugPlexPlaybackProbe {
    private static let log = Logger(subsystem: "com.jlipworth.Labstream", category: "PlexProbe")

    static func runIfRequested(appModel: AppModel) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--vp-probe-plex-playback") else { return }

        await DebugPlaybackProbeSupport.withTemporaryDiagnosticsEnabled {
            await run(arguments: arguments, appModel: appModel)
        }
    }

    private static func run(arguments: [String], appModel: AppModel) async {
        guard let options = DebugPlaybackProbeSupport.launchOptions(from: arguments,
                                                                    defaultBitrateKbps: appModel.activeStreamingQualityKbps) else {
            log.error("probe.fail reason=missing_probe_query")
            DebugPlaybackProbeSupport.recordMissingQuery(eventName: "probe.plex.fail")
            return
        }
        let query = options.query
        let bitrateKbps = options.bitrateKbps
        let seekMs = options.seekMs
        let postSeekHoldSeconds = options.postSeekHoldSeconds

        let querySummary = DebugPlaybackProbeSupport.querySummary(query)
        log.notice("probe.start backend=\(appModel.activeBackend.rawValue, privacy: .public) query=\(querySummary, privacy: .public) bitrate_kbps=\(bitrateKbps, privacy: .public) seek_ms=\(seekMs, privacy: .public)")
        AppDiagnostics.record(.playback, "probe.plex.start", fields: DebugPlaybackProbeSupport.startFields(
            backend: appModel.activeBackend.rawValue,
            query: query,
            bitrateKbps: bitrateKbps,
            seekMs: seekMs
        ))

        guard appModel.activeBackend == .plex,
              appModel.isBrowseReady,
              let restoredServer = appModel.serverBaseURL,
              let token = appModel.serverToken else {
            log.error("probe.fail reason=not_plex_or_not_ready")
            return
        }
        // `--vp-probe-server-url` swaps the transport endpoint (e.g. a kubectl port-forward
        // on localhost) while keeping the restored token/session — for testing playback over
        // an unproxied path without re-authenticating.
        let server: URL
        if let overrideURL = DebugPlaybackProbeSupport.value(after: "--vp-probe-server-url", in: arguments).flatMap(URL.init(string:)) {
            server = overrideURL
            log.notice("probe.server_override active=true")
        } else {
            server = restoredServer
        }

        var controller: PlaybackController?
        do {
            let item = try await resolveItem(query: query, appModel: appModel, server: server, token: token)
            log.notice("probe.item_resolved type=\(item.type, privacy: .public) duration_ms=\(item.duration ?? 0, privacy: .public)")

            let playback = PlaybackController(item: item,
                                              sessionSource: .plex(PlexPlaybackSession(
                                                server: server,
                                                token: token,
                                                machineIdentifier: appModel.selectedServer?.clientIdentifier)),
                                              identity: appModel.identity,
                                              client: appModel.client,
                                              maxVideoBitrateKbps: bitrateKbps,
                                              qualityDefaultsKey: appModel.activeStreamingQualityDefaultsKey,
                                              mediaIndex: 0)
            controller = playback
            playback.start()

            try await DebugPlaybackProbeSupport.waitUntilPlayable(playback, phase: "initial", timeoutSeconds: options.playableTimeoutSeconds)
            log.notice("probe.initial_playing position_ms=\(playback.currentResumeMs, privacy: .public)")
            await DebugPlaybackProbeSupport.logActiveVideoFormat(playback, phase: "initial", log: log)
            await DebugPlaybackFrameCapture.captureIfRequested(from: playback.player, label: "plex-initial", log: log)

            playback.performUserSeek(toMs: seekMs)
            try await DebugPlaybackProbeSupport.waitUntilPlayable(playback, phase: "post_seek", timeoutSeconds: options.playableTimeoutSeconds)
            try await DebugPlaybackProbeSupport.holdWithPlaybackProgress(playback, seconds: postSeekHoldSeconds, stallToleranceSeconds: options.stallToleranceSeconds, log: log)
            await DebugPlaybackProbeSupport.logActiveVideoFormat(playback, phase: "post_seek", log: log)
            await DebugPlaybackFrameCapture.captureIfRequested(from: playback.player, label: "plex-postseek", log: log)

            log.notice("probe.pass position_ms=\(playback.currentResumeMs, privacy: .public) failed=\(playback.playbackError.isFailed, privacy: .public)")
            AppDiagnostics.record(.playback, "probe.plex.pass", fields: [
                "resume": .millisecondsBucket(playback.currentResumeMs),
                "target": .millisecondsBucket(seekMs),
            ])
            playback.stop()
            controller = nil
        } catch {
            log.error("probe.fail error=\(DiagnosticRedactor.safeErrorSummary(error), privacy: .public)")
            AppDiagnostics.record(.playback, "probe.plex.fail", fields: [
                "error": .error(error),
            ])
            controller?.stop()
        }
    }

    private static func resolveItem(query: String, appModel: AppModel,
                                    server: URL, token: String) async throws -> MediaItem {
        let searchReq = BrowseAPI.search(server: server, token: token,
                                         identity: appModel.identity, query: query)
        let response = try await appModel.client.send(searchReq, as: HubsResponse.self)
        let matches = response.mediaContainer.hub.flatMap(\.metadata).filter { !$0.isContainer && !$0.isMusic }
        let skinny = matches.first { $0.title.localizedCaseInsensitiveCompare(query) == .orderedSame }
            ?? matches.first { $0.title.localizedCaseInsensitiveContains(query) }
            ?? matches.first
        guard let skinny else { throw DebugPlaybackProbeSupport.ProbeError.itemNotFound(query) }

        // Search hits are skinny; the player needs full metadata (Media/Part/chapters).
        let metadataReq = BrowseAPI.metadata(server: server, token: token,
                                             identity: appModel.identity, ratingKey: skinny.ratingKey)
        let metadata = try await appModel.client.send(metadataReq, as: MetadataResponse.self)
        guard let item = metadata.mediaContainer.metadata.first else {
            throw DebugPlaybackProbeSupport.ProbeError.itemNotFound(query)
        }
        return item
    }
}
#endif
