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
    private static let log = Logger(subsystem: "org.labstream.Labstream", category: "JellyfinProbe")

    static func runIfRequested(appModel: AppModel) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--vp-probe-jellyfin-playback") else { return }

        await DebugPlaybackProbeSupport.withTemporaryDiagnosticsEnabled {
            await run(arguments: arguments, appModel: appModel)
        }
    }

    private static func run(arguments: [String], appModel: AppModel) async {
        guard let options = DebugPlaybackProbeSupport.launchOptions(from: arguments,
                                                                    defaultBitrateKbps: 0) else {
            log.error("probe.fail reason=missing_probe_query")
            DebugPlaybackScenario.blocked(arguments, reason: .invalidOptions)
            DebugPlaybackProbeSupport.recordMissingQuery(eventName: "probe.jellyfin.fail")
            return
        }
        guard DebugPlaybackScenario.admitted(arguments, bitrateKbps: options.bitrateKbps) else { return }
        guard DebugPlaybackProbeSupport.prepareSourceBindingDiscovery(backend: "jellyfin", arguments: arguments) else { return }
        let query = options.query
        let bitrateKbps = options.bitrateKbps
        let seekMs = options.seekMs

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
            DebugPlaybackScenario.blocked(arguments, reason: .missingAuth)
            return
        }

        let service = JellyfinBrowseService(appModel: appModel)
        var controller: PlaybackController?
        var scenarioOwnsCleanup = false
        do {
            let item = try await resolveItem(query: query, service: service)
            let detailed = try await service.metadata(itemId: item.ratingKey)
            if arguments.contains("--vp-probe-discover-source") {
                let sourceData = try await service.probeSourceBinding(itemId: detailed.ratingKey)
                if try DebugPlaybackProbeSupport.exportSourceBindingIfRequested(detailed, backend: "jellyfin",
                    arguments: arguments, sourceData: sourceData) { return }
            }
            let mediaIndex = DebugPlaybackProbeSupport.intValue(after: "--vp-probe-media-index", in: arguments) ?? 0
            guard detailed.media?.indices.contains(mediaIndex) == true else {
                throw DebugPlaybackScenario.Blocked(reason: .invalidOptions)
            }
            for (flag, actual) in [
                ("--vp-probe-expected-item-id", Optional(detailed.ratingKey)),
                ("--vp-probe-expected-source-id", MediaBrowserPlaybackPreferencePolicy.mediaSourceID(for: detailed, mediaIndex: mediaIndex))
            ] where arguments.contains(flag) {
                guard PlaybackProbeSelection.matchesExpectedIdentity(
                    DebugPlaybackProbeSupport.value(after: flag, in: arguments), actual: actual) else {
                    throw DebugPlaybackScenario.Blocked(reason: .invalidOptions)
                }
            }
            log.notice("probe.item_resolved type=\(detailed.type, privacy: .public) duration_ms=\(detailed.duration ?? 0, privacy: .public) chapters=\((detailed.chapters?.count ?? 0), privacy: .public)")

            let opened = try await DetailPlaybackLauncher.open(item: detailed,
                                                               backend: .jellyfin,
                                                               appModel: appModel,
                                                               mediaIndex: mediaIndex,
                                                               maxVideoBitrateKbps: bitrateKbps)
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
                backendIsCurrent: { appModel.activeBackend == .jellyfin && appModel.isBrowseReady }, log: log)
            log.notice("probe.pass scenario_completed=true")
            controller = nil
        } catch {
            if !scenarioOwnsCleanup { DebugPlaybackScenario.blocked(arguments, reason: .playbackFailed) }
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
        let playable = items.filter { !$0.isContainer && !$0.isMusic }
        if let index = PlaybackProbeSelection.uniqueExactIndex(titles: playable.map(\.title), query: query) {
            return playable[index]
        }
        throw DebugPlaybackProbeSupport.ProbeError.itemNotFound(query)
    }

}
#endif
