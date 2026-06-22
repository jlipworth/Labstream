#if DEBUG
import Foundation
import os
import PMSKit

/// Launch-argument driven simulator probe for Plex download routing.
///
/// This runs inside the signed-in app process, so it exercises the app's real
/// `DownloadManager` path and Keychain/restored server context without exposing tokens.
/// It is inert unless explicitly launched with `--vp-probe-plex-download`.
@MainActor
enum DebugPlexDownloadProbe {
    private static let log = Logger(subsystem: "com.jlipworth.VisionPlay", category: "DownloadProbe")

    static func runIfRequested(appModel: AppModel, downloadManager: DownloadManager) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--vp-probe-plex-download") else { return }

        let priorDiagnosticsEnabled = AppDiagnostics.isEnabled
        AppDiagnostics.setEnabled(true)
        defer { AppDiagnostics.setEnabled(priorDiagnosticsEnabled) }

        let ratingKey = value(after: "--vp-probe-rating-key", in: arguments)
            ?? ProcessInfo.processInfo.environment["VISIONPLAY_PROBE_RATING_KEY"]
            ?? "17183"
        let mediaIndex = intValue(after: "--vp-probe-media-index", in: arguments) ?? 0
        let partIndex = intValue(after: "--vp-probe-part-index", in: arguments) ?? 0
        let startDownload = arguments.contains("--vp-probe-start-download")
        let preset = value(after: "--vp-probe-download-preset", in: arguments)
            ?? PlaybackPreferences.defaultDownloadQuality
        let observeSeconds = intValue(after: "--vp-probe-observe-seconds", in: arguments) ?? (startDownload ? 90 : 5)

        log.notice("probe.start backend=\(appModel.activeBackend.rawValue, privacy: .public) ratingKey=\(ratingKey, privacy: .public) start=\(startDownload, privacy: .public)")
        AppDiagnostics.record(.downloads, "probe.plex_download.start", fields: [
            "download_id": .identifier(ratingKey),
            "start": .bool(startDownload),
        ])

        guard appModel.activeBackend == .plex,
              appModel.isBrowseReady,
              let server = appModel.serverBaseURL,
              let token = appModel.serverToken else {
            log.error("probe.fail reason=not_plex_or_not_ready")
            AppDiagnostics.record(.downloads, "probe.plex_download.fail", fields: [
                "download_id": .identifier(ratingKey),
                "reason": .label("not_plex_or_not_ready"),
            ])
            return
        }

        do {
            let item = try await fetchItem(ratingKey: ratingKey, appModel: appModel,
                                           server: server, token: token)
            let probe = await downloadManager.directPlayProbe(for: item, server: server, token: token,
                                                              mediaIndex: mediaIndex, partIndex: partIndex)
            let part = probe.part ?? item.media?[safe: mediaIndex]?.part[safe: partIndex]
            let originalEligible = probe.direct && OfflineDownloadDecision.isLocallyPlayableOriginal(part: part)
            let choice: DownloadManager.DownloadChoice = originalEligible ? .original : .optimize(targetName: preset)
            let route = originalEligible ? "original" : "optimize"
            let reason = originalEligible ? "direct_local_playable" : optimizeReason(direct: probe.direct, part: part)

            let targetLabel = originalEligible ? "raw_original" : preset
            log.notice("probe.route route=\(route, privacy: .public) reason=\(reason, privacy: .public) container=\(OfflineDownloadDecision.containerLabel(part: part), privacy: .public) target=\(targetLabel, privacy: .public) direct=\(probe.direct, privacy: .public)")
            AppDiagnostics.record(.downloads, "probe.plex_download.route", fields: [
                "download_id": .identifier(ratingKey),
                "route": .label(route),
                "reason": .label(reason),
                "container": .label(OfflineDownloadDecision.containerLabel(part: part)),
                "target": .label(targetLabel),
                "direct": .bool(probe.direct),
                "start": .bool(startDownload),
            ])

            guard startDownload else {
                log.notice("probe.pass dry_run=true")
                AppDiagnostics.record(.downloads, "probe.plex_download.pass", fields: [
                    "download_id": .identifier(ratingKey),
                    "dry_run": .bool(true),
                ])
                return
            }

            await downloadManager.download(item, choice: choice, mediaIndex: mediaIndex, partIndex: partIndex)
            await observe(ratingKey: ratingKey, manager: downloadManager, seconds: observeSeconds)
        } catch {
            log.error("probe.fail error=\(String(describing: error), privacy: .public)")
            AppDiagnostics.record(.downloads, "probe.plex_download.fail", fields: [
                "download_id": .identifier(ratingKey),
                "error": .error(error),
            ])
        }
    }

    private static func fetchItem(ratingKey: String, appModel: AppModel,
                                  server: URL, token: String) async throws -> MediaItem {
        let req = BrowseAPI.metadata(server: server, token: token,
                                     identity: appModel.identity, ratingKey: ratingKey)
        let response = try await appModel.client.send(req, as: MetadataResponse.self)
        if let item = response.mediaContainer.metadata.first { return item }
        throw ProbeError.itemNotFound(ratingKey)
    }

    private static func optimizeReason(direct: Bool, part: Part?) -> String {
        if direct && !OfflineDownloadDecision.isLocallyPlayableOriginal(part: part) {
            return "container_not_playable"
        }
        return direct ? "not_original_eligible" : "needs_transcode"
    }

    private static func observe(ratingKey: String, manager: DownloadManager, seconds: Int) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            let record = manager.records.first { $0.ratingKey == ratingKey }
            let status = record.map { String(describing: $0.status) } ?? "missing"
            let progress = record?.progress ?? 0
            log.notice("probe.observe status=\(status, privacy: .public) progress=\(progress, privacy: .public)")
            AppDiagnostics.record(.downloads, "probe.plex_download.observe", fields: [
                "download_id": .identifier(ratingKey),
                "status": .label(status),
                "progress_pct": .int(Int((progress * 100).rounded())),
            ])
            if record?.isComplete == true || record?.status == .failed { break }
            try? await Task.sleep(for: .seconds(5))
        }
        AppDiagnostics.record(.downloads, "probe.plex_download.done", fields: [
            "download_id": .identifier(ratingKey),
        ])
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func intValue(after flag: String, in arguments: [String]) -> Int? {
        value(after: flag, in: arguments).flatMap(Int.init)
    }

    enum ProbeError: Error, CustomStringConvertible {
        case itemNotFound(String)

        var description: String {
            switch self {
            case .itemNotFound(let ratingKey): return "item not found for ratingKey \(ratingKey)"
            }
        }
    }
}
#endif
