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
    private static let log = Logger(subsystem: "org.labstream.Labstream", category: "EmbyDownloadProbe")

    static func runIfRequested(appModel: AppModel, downloadManager: DownloadManager) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--vp-probe-emby-download") else { return }

        let priorDiagnosticsEnabled = AppDiagnostics.isEnabled
        AppDiagnostics.setEnabled(true)
        defer { AppDiagnostics.setEnabled(priorDiagnosticsEnabled) }

        let rawQuery = DebugDownloadProbeSupport.value(after: "--vp-probe-query", in: arguments)
        let trimmedQuery = rawQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let query = trimmedQuery, !query.isEmpty else {
            log.error("probe.fail reason=missing_probe_query")
            AppDiagnostics.record(.downloads, "probe.emby_download.fail", fields: [
                "reason": .label("missing_probe_query"),
                "query_present": .bool(false),
            ])
            return
        }
        let startDownload = arguments.contains("--vp-probe-start-download")
        let startOptimize = arguments.contains("--vp-probe-start-optimize")
        let refreshExisting = arguments.contains("--vp-probe-refresh-existing")
        let observeOnly = arguments.contains("--vp-probe-observe-record")
        let resumeObserved = arguments.contains("--vp-probe-resume-observed")
        let keepRecord = arguments.contains("--vp-probe-keep-record")
        let deleteExisting = arguments.contains("--vp-probe-delete-existing")
        let preset = DebugDownloadProbeSupport.value(after: "--vp-probe-download-preset", in: arguments) ?? "1080p 8 Mbps"
        let observeSeconds = DebugDownloadProbeSupport.intValue(after: "--vp-probe-observe-seconds", in: arguments) ?? 30

        let querySummary = DiagnosticRedactor.probeQuerySummary(query)
        log.notice("probe.start backend=\(appModel.activeBackend.rawValue, privacy: .public) query=\(querySummary, privacy: .public) start=\(startDownload, privacy: .public) startOptimize=\(startOptimize, privacy: .public) refreshExisting=\(refreshExisting, privacy: .public)")
        var startFields: [String: DiagnosticFieldValue] = [
            "start": .bool(startDownload),
            "start_optimize": .bool(startOptimize),
            "refresh_existing": .bool(refreshExisting),
            "observe_only": .bool(observeOnly),
        ]
        startFields.merge(DiagnosticRedactor.probeQueryFields(query)) { _, new in new }
        AppDiagnostics.record(.downloads, "probe.emby_download.start", fields: startFields)

        guard let backendSession = appModel.backendSession(for: .emby),
              let userId = backendSession.userID else {
            log.error("probe.fail reason=not_emby_configured")
            AppDiagnostics.record(.downloads, "probe.emby_download.fail", fields: [
                "reason": .label("not_emby_configured"),
            ])
            return
        }
        let server = backendSession.baseURL
        let token = backendSession.token

        let service = EmbyBrowseService(appModel: appModel)
        do {
            let resolved = try await resolveItem(query: query, service: service)
            let item = (try? await service.metadata(itemId: resolved.ratingKey)) ?? resolved
            // The record key is the documented Emby lane format.
            let recordKey = "emby:\(item.ratingKey)"
            if deleteExisting {
                downloadManager.delete(ratingKey: recordKey)
                log.notice("probe.deleted record=\(recordKey, privacy: .public)")
                AppDiagnostics.record(.downloads, "probe.emby_download.deleted", fields: [
                    "download_id": .identifier(recordKey),
                ])
                return
            }
            if observeOnly {
                let before = await observeDetailed(recordKey: recordKey, manager: downloadManager,
                                                   seconds: resumeObserved ? 1 : observeSeconds)
                if resumeObserved {
                    downloadManager.retry(ratingKey: recordKey)
                    try? await Task.sleep(for: .milliseconds(500))
                    let resumeStart = DebugDownloadProbeSupport.observation(forRecordKey: recordKey, in: downloadManager)
                    let after = await observeDetailed(recordKey: recordKey, manager: downloadManager,
                                                      seconds: observeSeconds)
                    let resumedAtCheckpoint = before.bytes > 0 && resumeStart.bytes >= before.bytes
                    let keptProgress = resumedAtCheckpoint
                        && after.bytes >= before.bytes
                        && after.progress >= max(0, before.progress * 0.95)
                    log.notice("probe.resume_check keptProgress=\(keptProgress, privacy: .public) resumedAtCheckpoint=\(resumedAtCheckpoint, privacy: .public) paused=\(before.progress, privacy: .public) after=\(after.progress, privacy: .public) bytes=\(after.bytes, privacy: .public)")
                    AppDiagnostics.record(.downloads, "probe.emby_download.resume_check", fields: [
                        "download_id": .identifier(recordKey),
                        "kept_progress": .bool(keptProgress),
                        "resumed_at_checkpoint": .bool(resumedAtCheckpoint),
                        "paused_bytes": .int(before.bytes),
                        "resume_start_bytes": .int(resumeStart.bytes),
                        "bytes": .int(after.bytes),
                    ])
                }
                return
            }

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

            await downloadManager.downloadEmby(item, choice: startOptimize ? .optimize(targetName: preset) : .original)
            let progressed = await observe(recordKey: recordKey, manager: downloadManager, seconds: observeSeconds)
            // Never let the (large, non-resumable) transcode run to completion on the sim unless an
            // interruption/resume probe explicitly asks to keep the paused checkpoint for relaunch.
            if !keepRecord { downloadManager.delete(ratingKey: recordKey) }

            log.notice("probe.pass dry_run=false route=\(route, privacy: .public) optimize=\(startOptimize, privacy: .public) progressed=\(progressed, privacy: .public)")
            AppDiagnostics.record(.downloads, "probe.emby_download.pass", fields: [
                "dry_run": .bool(false),
                "route": .label(route),
                "optimize": .bool(startOptimize),
                "progressed": .bool(progressed),
            ])
        } catch {
            log.error("probe.fail error=\(DiagnosticRedactor.safeErrorSummary(error), privacy: .public)")
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
        let result = await observeDetailed(recordKey: recordKey, manager: manager, seconds: seconds)
        return result.status == "downloading" || result.bytes > 0 || result.progress > 0
    }

    private static func observeDetailed(recordKey: String, manager: DownloadManager, seconds: Int) async -> DebugDownloadProbeSupport.Observation {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        var latest = DebugDownloadProbeSupport.observation(forRecordKey: recordKey, in: manager)
        while ContinuousClock.now < deadline {
            latest = DebugDownloadProbeSupport.observation(forRecordKey: recordKey, in: manager)
            log.notice("probe.observe status=\(latest.status, privacy: .public) progress=\(latest.progress, privacy: .public) bytes=\(latest.bytes, privacy: .public)")
            AppDiagnostics.record(.downloads, "probe.emby_download.observe", fields: [
                "status": .label(latest.status),
                "progress_pct": .int(Int((latest.progress * 100).rounded())),
                "bytes": .int(latest.bytes),
            ])
            let record = manager.records.first { $0.ratingKey == recordKey }
            if record?.isComplete == true || record?.status == .failed { break }
            try? await Task.sleep(for: .seconds(5))
        }
        return latest
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
            let fileSources = EmbyConvertedSourcePolicy.fileSources(info.mediaSources)
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
