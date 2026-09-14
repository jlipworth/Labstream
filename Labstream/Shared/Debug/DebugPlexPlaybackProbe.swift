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
    private static let log = Logger(subsystem: "org.labstream.Labstream", category: "PlexProbe")

    static func runIfRequested(appModel: AppModel) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--vp-probe-plex-playback") else { return }

        await DebugPlaybackProbeSupport.withTemporaryDiagnosticsEnabled {
            await run(arguments: arguments, appModel: appModel)
        }
    }

    private static func run(arguments: [String], appModel: AppModel) async {
        guard let options = DebugPlaybackProbeSupport.launchOptions(from: arguments,
                                                                    defaultBitrateKbps: 0) else {
            log.error("probe.fail reason=missing_probe_query")
            DebugPlaybackScenario.blocked(arguments, reason: .invalidOptions)
            DebugPlaybackProbeSupport.recordMissingQuery(eventName: "probe.plex.fail")
            return
        }
        guard DebugPlaybackScenario.admitted(arguments, bitrateKbps: options.bitrateKbps) else { return }
        let query = options.query
        let bitrateKbps = options.bitrateKbps
        let seekMs = options.seekMs

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
            DebugPlaybackScenario.blocked(arguments, reason: .missingAuth)
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

        if arguments.contains("--vp-probe-plex-discover") {
            do {
                try await discover(query: query, appModel: appModel, server: server, token: token)
                log.notice("probe.discovery_written playback_started=false")
            } catch {
                log.error("probe.discovery_failed")
            }
            return
        }
        guard let ratingKey = DebugPlaybackProbeSupport.value(after: "--vp-probe-rating-key", in: arguments),
              !ratingKey.isEmpty, !ratingKey.hasPrefix("--"),
              let mediaID = DebugPlaybackProbeSupport.intValue(after: "--vp-probe-media-id", in: arguments),
              let partID = DebugPlaybackProbeSupport.intValue(after: "--vp-probe-part-id", in: arguments) else {
            log.error("probe.fail reason=missing_exact_source_binding")
            DebugPlaybackScenario.blocked(arguments, reason: .invalidOptions)
            return
        }
        var controller: PlaybackController?
        var scenarioOwnsCleanup = false
        do {
            let item = try await resolveItem(ratingKey: ratingKey, appModel: appModel, server: server, token: token)
            guard let mediaIndex = PlaybackProbeSelection.plexMediaIndex(item: item, query: query,
                ratingKey: ratingKey, mediaID: mediaID, partID: partID) else {
                throw DebugPlaybackProbeSupport.ProbeError.playbackFailed("source_binding_mismatch", nil)
            }
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
                                              mediaIndex: mediaIndex)
            controller = playback
            scenarioOwnsCleanup = true
            controller = nil // The named scenario owns cleanup from this point, including errors.
            try await DebugPlaybackScenario.run(playback, options: options, arguments: arguments,
                backendIsCurrent: { appModel.activeBackend == .plex && appModel.isBrowseReady }, log: log)
            log.notice("probe.pass scenario_completed=true")
            controller = nil
        } catch {
            if !scenarioOwnsCleanup { DebugPlaybackScenario.blocked(arguments, reason: .playbackFailed) }
            log.error("probe.fail error=\(DiagnosticRedactor.safeErrorSummary(error), privacy: .public)")
            AppDiagnostics.record(.playback, "probe.plex.fail", fields: [
                "error": .error(error),
            ])
            controller?.stop()
        }
    }

    /// Explicit read-only discovery. Private source references stay in the app container,
    /// never diagnostics. A search is bounded and never starts playback or selects a source.
    private static func discover(query: String, appModel: AppModel, server: URL, token: String) async throws {
        let directory = URL.documentsDirectory.appendingPathComponent("ProbeDiscovery", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("plex.json")
        try? FileManager.default.removeItem(at: output) // stale results cannot masquerade as this run
        let request = BrowseAPI.search(server: server, token: token, identity: appModel.identity, query: query)
        let response = try await appModel.client.send(request, as: HubsResponse.self)
        let hits = response.mediaContainer.hub.flatMap(\.metadata).filter {
            ($0.type == "movie" || $0.type == "episode") &&
                $0.title.localizedCaseInsensitiveCompare(query) == .orderedSame
        }
        var seen = Set<String>()
        let keys = hits.map(\.ratingKey).filter { seen.insert($0).inserted }
        guard keys.count <= 5 else {
            throw DebugPlaybackProbeSupport.ProbeError.playbackFailed("discovery_limit", nil)
        }
        var rows: [[String: Any]] = []
        for key in keys {
            let item = try await resolveItem(ratingKey: key, appModel: appModel, server: server, token: token)
            for media in item.media ?? [] {
                rows.append([
                    "ratingKey": item.ratingKey, "title": item.title, "type": item.type,
                    "mediaID": media.id, "durationMs": media.duration ?? item.duration ?? 0,
                    "videoCodec": media.videoCodec ?? "unknown",
                    "audioCodec": media.audioCodec ?? "unknown",
                    "width": media.width ?? 0, "height": media.height ?? 0,
                    "sourceHDR": media.part.flatMap { $0.streams ?? [] }.compactMap(\.hdrMetadata)
                        .map(\.displayLabel),
                    "parts": media.part.map { ["partID": $0.id, "file": $0.file ?? "",
                                                "size": $0.size ?? 0] as [String: Any] }
                ])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: ["sources": rows], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output, options: .atomic)
    }

    private static func resolveItem(ratingKey: String, appModel: AppModel,
                                    server: URL, token: String) async throws -> MediaItem {
        // Fetch the manifest's exact item; never guess from a search result.
        let metadataReq = BrowseAPI.metadata(server: server, token: token,
                                             identity: appModel.identity, ratingKey: ratingKey)
        let metadata = try await appModel.client.send(metadataReq, as: MetadataResponse.self)
        guard metadata.mediaContainer.metadata.count == 1,
              let item = metadata.mediaContainer.metadata.first else {
            throw DebugPlaybackProbeSupport.ProbeError.playbackFailed("ambiguous_metadata", nil)
        }
        return item
    }
}
#endif
