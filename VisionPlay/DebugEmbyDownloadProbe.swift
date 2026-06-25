#if DEBUG
import Foundation
import os
import PMSKit

/// Launch-argument driven simulator probe for the Emby OFFLINE DOWNLOAD path.
///
/// Mirrors `DebugPlexDownloadProbe`/`DebugEmbyPlaybackProbe`: it runs inside the signed-in app
/// process on the booted simulator, so it exercises the app's real `DownloadManager.downloadEmby`
/// path (and the authoritative download-profile negotiation) against the live server, using the
/// restored Keychain Emby session — no tokens exposed. The headless PMSKit `LiveEmbyDownloadProbe`
/// validates the server WIRE (negotiation, single-file transcode URL, resumable original, encoder
/// teardown); this validates the APP GLUE (negotiation → route decision → DownloadManager record
/// lifecycle) end-to-end on device.
///
/// Inert unless launched with `--vp-probe-emby-download`. Requires the app to already be signed in
/// to Emby (the probe does not authenticate; sign in once via the UI first).
///
/// Modes:
///   • default — DRY RUN: negotiate the download profile and log the route (original vs transcode)
///     without transferring anything. Safe and fast.
///   • `--vp-probe-refresh-existing` — safe #133 probe: request an item refresh and poll
///     unfiltered PlaybackInfo for API-visible MP4/File alternate sources without starting a
///     download or conversion.
///   • `--vp-probe-start-optimize [--vp-probe-download-preset "1080p 8 Mbps"]` — start the
///     server-prep lane briefly. If a reusable converted source is API-visible, this should hand off
///     to the static `.existingVersion` path rather than creating a duplicate convert job.
///   • `--vp-probe-start-download` — actually start `downloadEmby`, observe the record for
///     `--vp-probe-observe-seconds` (default 30), then DELETE it (the item-1200 transcode is ~GBs
///     and non-resumable, so the probe never lets it run to completion). Deleting also exercises
///     the encoder-teardown path.
@MainActor
enum DebugEmbyDownloadProbe {
    private static let log = Logger(subsystem: "com.jlipworth.VisionPlay", category: "EmbyDownloadProbe")

    static func runIfRequested(appModel: AppModel, downloadManager: DownloadManager) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--vp-probe-emby-download") else { return }

        let priorDiagnosticsEnabled = AppDiagnostics.isEnabled
        AppDiagnostics.setEnabled(true)
        defer { AppDiagnostics.setEnabled(priorDiagnosticsEnabled) }

        let query = value(after: "--vp-probe-query", in: arguments) ?? "12 Years a Slave"
        let startDownload = arguments.contains("--vp-probe-start-download")
        let startOptimize = arguments.contains("--vp-probe-start-optimize")
        let refreshExisting = arguments.contains("--vp-probe-refresh-existing")
        let preset = value(after: "--vp-probe-download-preset", in: arguments) ?? "1080p 8 Mbps"
        let observeSeconds = intValue(after: "--vp-probe-observe-seconds", in: arguments) ?? 30

        log.notice("probe.start backend=\(appModel.activeBackend.rawValue, privacy: .public) query=\(query, privacy: .private) start=\(startDownload, privacy: .public) startOptimize=\(startOptimize, privacy: .public) refreshExisting=\(refreshExisting, privacy: .public)")
        AppDiagnostics.record(.downloads, "probe.emby_download.start", fields: [
            "start": .bool(startDownload),
            "start_optimize": .bool(startOptimize),
            "refresh_existing": .bool(refreshExisting),
        ])

        guard appModel.activeBackend == .emby,
              appModel.isBrowseReady,
              let server = appModel.embyServerBaseURL,
              let token = appModel.embyAccessToken,
              let userId = appModel.embyUserID else {
            log.error("probe.fail reason=not_emby_or_not_ready")
            AppDiagnostics.record(.downloads, "probe.emby_download.fail", fields: [
                "reason": .label("not_emby_or_not_ready"),
            ])
            return
        }

        let service = EmbyBrowseService(appModel: appModel)
        do {
            let resolved = try await resolveItem(query: query, service: service)
            let item = (try? await service.metadata(itemId: resolved.ratingKey)) ?? resolved
            // partIndex 0 / mediaIndex 0 is the probe's scope — Emby items carry a single source.
            let part = item.media?.first?.part.first

            // On-device authoritative negotiation: POST the DOWNLOAD device profile (Static MP4),
            // exactly as `downloadEmby` does. ~200 Mbps ceiling so a high-bitrate-but-compatible
            // file still qualifies for an original download.
            let infoReq = try EmbyPlayback.downloadPlaybackInfoRequest(
                server: server, token: token, identity: appModel.identity.emby,
                userId: userId, itemId: item.ratingKey,
                mediaSourceId: nil,
                maxStaticBitrate: 200_000_000)
            let (data, response) = try await URLSession.shared.data(for: infoReq)
            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(httpStatus) else {
                throw ProbeError.negotiationFailed(httpStatus)
            }
            let info = try EmbyPlaybackInfoResponse.decode(from: data)
            let decision = try EmbyPlayback.downloadDecision(response: info)

            // Two-gate rule, mirrored from `downloadEmby`: original ⇔ negotiated DirectPlay AND a
            // locally-playable container. Everything else routes to the single-file transcode.
            let originalEligible = decision.supportsDirectPlay
                && OfflineDownloadDecision.isLocallyPlayableOriginal(part: part)
            let route = originalEligible ? "original" : "transcode"
            let sizeMB = (decision.size ?? 0) / 1_000_000

            log.notice("probe.route http=\(httpStatus, privacy: .public) route=\(route, privacy: .public) directPlay=\(decision.supportsDirectPlay, privacy: .public) container=\(decision.container ?? "nil", privacy: .public) sizeMB=\(sizeMB, privacy: .public) hasTranscodeUrl=\(decision.transcodingURL != nil, privacy: .public) reasons=\(decision.transcodeReasons.joined(separator: ","), privacy: .public)")
            AppDiagnostics.record(.downloads, "probe.emby_download.route", fields: [
                "route": .label(route),
                "direct_play": .bool(decision.supportsDirectPlay),
                "container": .label(decision.container ?? "nil"),
                "has_transcode_url": .bool(decision.transcodingURL != nil),
            ])

            if refreshExisting {
                let sawConvertedFile = try await refreshAndPollExistingVersions(
                    server: server, token: token, identity: appModel.identity.emby,
                    userId: userId, itemId: item.ratingKey)
                log.notice("probe.pass dry_run=true route=\(route, privacy: .public) refreshed_existing=\(sawConvertedFile, privacy: .public)")
                AppDiagnostics.record(.downloads, "probe.emby_download.pass", fields: [
                    "dry_run": .bool(true),
                    "route": .label(route),
                    "refreshed_existing": .bool(sawConvertedFile),
                ])
                return
            }

            guard startDownload || startOptimize else {
                log.notice("probe.pass dry_run=true route=\(route, privacy: .public)")
                AppDiagnostics.record(.downloads, "probe.emby_download.pass", fields: [
                    "dry_run": .bool(true),
                    "route": .label(route),
                ])
                return
            }

            // The record key is the documented Emby lane format.
            let recordKey = "emby:\(item.ratingKey)"
            await downloadManager.downloadEmby(item, choice: startOptimize ? .optimize(targetName: preset) : .original)
            let progressed = await observe(recordKey: recordKey, manager: downloadManager, seconds: observeSeconds)
            // Never let the (large, non-resumable) transcode run to completion on the sim. Deleting
            // also exercises encoder teardown for a transcode-sourced download.
            downloadManager.delete(ratingKey: recordKey)

            log.notice("probe.pass dry_run=false route=\(route, privacy: .public) optimize=\(startOptimize, privacy: .public) progressed=\(progressed, privacy: .public)")
            AppDiagnostics.record(.downloads, "probe.emby_download.pass", fields: [
                "dry_run": .bool(false),
                "route": .label(route),
                "optimize": .bool(startOptimize),
                "progressed": .bool(progressed),
            ])
        } catch {
            log.error("probe.fail error=\(String(describing: error), privacy: .public)")
            AppDiagnostics.record(.downloads, "probe.emby_download.fail", fields: [
                "error": .error(error),
            ])
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
        throw ProbeError.itemNotFound(query)
    }

    /// Observe the download record until it makes progress, completes, or fails. Returns whether the
    /// transfer demonstrably moved (status reached `.downloading` or bytes advanced) — the on-device
    /// signal that the app glue actually kicked off the transfer.
    private static func observe(recordKey: String, manager: DownloadManager, seconds: Int) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        var progressed = false
        while ContinuousClock.now < deadline {
            let record = manager.records.first { $0.ratingKey == recordKey }
            let status = record.map { String(describing: $0.status) } ?? "missing"
            let progress = record?.progress ?? 0
            if record?.status == .downloading || progress > 0 { progressed = true }
            log.notice("probe.observe status=\(status, privacy: .public) progress=\(progress, privacy: .public)")
            AppDiagnostics.record(.downloads, "probe.emby_download.observe", fields: [
                "status": .label(status),
                "progress_pct": .int(Int((progress * 100).rounded())),
            ])
            if record?.isComplete == true || record?.status == .failed { break }
            try? await Task.sleep(for: .seconds(5))
        }
        return progressed
    }

    /// Safe #133 live probe: trigger the same item-refresh request used by the convert reuse path,
    /// then poll unfiltered PlaybackInfo for API-visible converted File sources. Logs only counts
    /// and generic source shape, not tokens or file paths.
    private static func refreshAndPollExistingVersions(server: URL, token: String,
                                                       identity: EmbyClientIdentity,
                                                       userId: String, itemId: String) async throws -> Bool {
        let refresh = try EmbyConvertRequest.itemRefreshRequest(server: server, token: token,
                                                                identity: identity, userId: userId,
                                                                itemId: itemId)
        let (_, response) = try await URLSession.shared.data(for: refresh)
        let refreshStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
        log.notice("probe.refresh status=\(refreshStatus, privacy: .public)")
        AppDiagnostics.record(.downloads, "probe.emby_download.refresh", fields: [
            "status_code": .int(refreshStatus),
        ])

        var sawConvertedFile = false
        for attempt in 1...6 {
            let req = try EmbyPlayback.downloadPlaybackInfoRequest(
                server: server, token: token, identity: identity,
                userId: userId, itemId: itemId, mediaSourceId: nil,
                maxStaticBitrate: 200_000_000)
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let info = try EmbyPlaybackInfoResponse.decode(from: data)
            let fileSources = info.mediaSources.filter { source in
                guard source.id?.isEmpty == false else { return false }
                if let proto = source.mediaProtocol, proto.caseInsensitiveCompare("File") != .orderedSame {
                    return false
                }
                return true
            }
            let converted = fileSources.filter { ($0.container ?? "").lowercased().contains("mp4") }
            sawConvertedFile = sawConvertedFile || !converted.isEmpty
            log.notice("probe.existing_sources attempt=\(attempt, privacy: .public) http=\(status, privacy: .public) sources=\(info.mediaSources.count, privacy: .public) files=\(fileSources.count, privacy: .public) converted=\(converted.count, privacy: .public)")
            AppDiagnostics.record(.downloads, "probe.emby_download.existing_sources", fields: [
                "attempt": .int(attempt),
                "status_code": .int(status),
                "source_count": .int(info.mediaSources.count),
                "file_count": .int(fileSources.count),
                "converted_count": .int(converted.count),
            ])
            if sawConvertedFile { return true }
            if attempt < 6 { try? await Task.sleep(for: .seconds(5)) }
        }
        return false
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
        case negotiationFailed(Int)

        var description: String {
            switch self {
            case .itemNotFound(let query): return "item not found for query \(query)"
            case .negotiationFailed(let status): return "download PlaybackInfo negotiation failed: HTTP \(status)"
            }
        }
    }
}
#endif
