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

        let requestedRatingKey = DebugDownloadProbeSupport.value(after: "--vp-probe-rating-key", in: arguments)
            ?? ProcessInfo.processInfo.environment["VISIONPLAY_PROBE_RATING_KEY"]
        let query = DebugDownloadProbeSupport.value(after: "--vp-probe-query", in: arguments)
            ?? ProcessInfo.processInfo.environment["VISIONPLAY_PROBE_QUERY"]
        let ratingKey = requestedRatingKey ?? "17183"
        let mediaIndex = DebugDownloadProbeSupport.intValue(after: "--vp-probe-media-index", in: arguments) ?? 0
        let partIndex = DebugDownloadProbeSupport.intValue(after: "--vp-probe-part-index", in: arguments) ?? 0
        let startDownload = arguments.contains("--vp-probe-start-download")
        let useExistingVersion = arguments.contains("--vp-probe-existing-version")
        let listVersions = arguments.contains("--vp-probe-list-versions")
        let rangeCheck = arguments.contains("--vp-probe-range-check")
        let dumpSearch = arguments.contains("--vp-probe-dump-search")
        let pauseResume = arguments.contains("--vp-probe-pause-resume")
        let pauseOnly = arguments.contains("--vp-probe-pause-only")
        let observeOnly = arguments.contains("--vp-probe-observe-record")
        let resumeObserved = arguments.contains("--vp-probe-resume-observed")
        let deleteExisting = arguments.contains("--vp-probe-delete-existing")
        let deleteAfterObserve = arguments.contains("--vp-probe-delete-after-observe")
        let preset = DebugDownloadProbeSupport.value(after: "--vp-probe-download-preset", in: arguments)
            ?? PlaybackPreferences.defaultDownloadQuality
        let pauseAfterSeconds = DebugDownloadProbeSupport.intValue(after: "--vp-probe-pause-after-seconds", in: arguments) ?? 8
        let observeSeconds = DebugDownloadProbeSupport.intValue(after: "--vp-probe-observe-seconds", in: arguments) ?? (startDownload ? 90 : 5)

        log.notice("probe.start backend=\(appModel.activeBackend.rawValue, privacy: .public) ratingKey=\(ratingKey, privacy: .public) start=\(startDownload, privacy: .public) existing=\(useExistingVersion, privacy: .public) pauseResume=\(pauseResume, privacy: .public) observeOnly=\(observeOnly, privacy: .public)")
        var startFields: [String: DiagnosticFieldValue] = [
            "download_id": .identifier(ratingKey),
            "start": .bool(startDownload),
            "existing_version": .bool(useExistingVersion),
            "dump_search": .bool(dumpSearch),
            "pause_resume": .bool(pauseResume),
            "observe_only": .bool(observeOnly),
        ]
        startFields.merge(DiagnosticRedactor.probeQueryFields(query)) { _, new in new }
        AppDiagnostics.record(.downloads, "probe.plex_download.start", fields: startFields)

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
            let item = try await resolveItem(ratingKey: requestedRatingKey, query: query, appModel: appModel,
                                             server: server, token: token, dumpSearch: dumpSearch)
            let ratingKey = item.ratingKey
            if deleteExisting {
                downloadManager.delete(ratingKey: ratingKey)
                log.notice("probe.deleted ratingKey=\(ratingKey, privacy: .public)")
                AppDiagnostics.record(.downloads, "probe.plex_download.deleted", fields: [
                    "download_id": .identifier(ratingKey),
                ])
                return
            }

            if listVersions {
                logVersions(item: item)
                if !startDownload && !observeOnly && !rangeCheck { return }
            }

            if observeOnly {
                let before = await observe(ratingKey: ratingKey, manager: downloadManager,
                                           seconds: resumeObserved ? 1 : observeSeconds,
                                           label: "observe_only")
                if resumeObserved {
                    downloadManager.retry(ratingKey: ratingKey)
                    try? await Task.sleep(for: .milliseconds(500))
                    let resumeStart = DebugDownloadProbeSupport.observation(forRecordKey: ratingKey, in: downloadManager)
                    let after = await observe(ratingKey: ratingKey, manager: downloadManager,
                                              seconds: observeSeconds, label: "resume_observed")
                    let resumedAtCheckpoint = before.bytes > 0 && resumeStart.bytes >= before.bytes
                    let keptProgress = resumedAtCheckpoint
                        && after.bytes >= before.bytes
                        && after.progress >= max(0, before.progress * 0.95)
                    log.notice("probe.resume_check keptProgress=\(keptProgress, privacy: .public) resumedAtCheckpoint=\(resumedAtCheckpoint, privacy: .public) paused=\(before.progress, privacy: .public) after=\(after.progress, privacy: .public) bytes=\(after.bytes, privacy: .public)")
                    AppDiagnostics.record(.downloads, "probe.plex_download.resume_check", fields: [
                        "download_id": .identifier(ratingKey),
                        "kept_progress": .bool(keptProgress),
                        "resumed_at_checkpoint": .bool(resumedAtCheckpoint),
                        "paused_pct": .int(Int((before.progress * 100).rounded())),
                        "after_pct": .int(Int((after.progress * 100).rounded())),
                        "paused_bytes": .int(before.bytes),
                        "resume_start_bytes": .int(resumeStart.bytes),
                        "bytes": .int(after.bytes),
                    ])
                }
                if deleteAfterObserve {
                    downloadManager.delete(ratingKey: ratingKey)
                    log.notice("probe.deleted_after_observe ratingKey=\(ratingKey, privacy: .public)")
                    AppDiagnostics.record(.downloads, "probe.plex_download.deleted", fields: [
                        "download_id": .identifier(ratingKey),
                    ])
                }
                return
            }

            let probe = await downloadManager.directPlayProbe(for: item, server: server, token: token,
                                                              mediaIndex: mediaIndex, partIndex: partIndex)
            let selectedMediaIndex = useExistingVersion
                ? (explicitInt(after: "--vp-probe-media-index", in: arguments)
                   ?? firstExistingVersionMediaIndex(item: item)
                   ?? mediaIndex)
                : mediaIndex
            let part = item.media?[safe: selectedMediaIndex]?.part[safe: partIndex]
                ?? probe.part
                ?? item.media?[safe: mediaIndex]?.part[safe: partIndex]
            let originalEligible = probe.direct && OfflineDownloadDecision.isLocallyPlayableOriginal(part: part)
            let choice: DownloadManager.DownloadChoice
            let route: String
            if useExistingVersion {
                choice = .existingVersion
                route = "existing_version"
            } else {
                choice = originalEligible ? .original : .optimize(targetName: preset)
                route = originalEligible ? "original" : "optimize"
            }
            let reason = originalEligible ? "direct_local_playable" : optimizeReason(direct: probe.direct, part: part)

            let targetLabel = useExistingVersion ? "existing_media_\(selectedMediaIndex)" : (originalEligible ? "raw_original" : preset)
            let partSize = part?.size ?? 0
            log.notice("probe.route route=\(route, privacy: .public) reason=\(reason, privacy: .public) mediaIndex=\(selectedMediaIndex, privacy: .public) container=\(OfflineDownloadDecision.containerLabel(part: part), privacy: .public) target=\(targetLabel, privacy: .public) direct=\(probe.direct, privacy: .public) size=\(partSize, privacy: .public)")
            AppDiagnostics.record(.downloads, "probe.plex_download.route", fields: [
                "download_id": .identifier(ratingKey),
                "route": .label(route),
                "reason": .label(reason),
                "media_index": .int(selectedMediaIndex),
                "container": .label(OfflineDownloadDecision.containerLabel(part: part)),
                "target": .label(targetLabel),
                "direct": .bool(probe.direct),
                "size_bytes": .int(partSize),
                "start": .bool(startDownload),
            ])

            if rangeCheck, let partKey = part?.key {
                await probeRange(server: server, token: token, identity: appModel.identity,
                                 partKey: partKey, ratingKey: ratingKey)
                if !startDownload { return }
            }

            guard startDownload else {
                log.notice("probe.pass dry_run=true")
                AppDiagnostics.record(.downloads, "probe.plex_download.pass", fields: [
                    "download_id": .identifier(ratingKey),
                    "dry_run": .bool(true),
                ])
                return
            }

            await downloadManager.download(item, choice: choice, mediaIndex: selectedMediaIndex, partIndex: partIndex)
            if pauseResume || pauseOnly {
                let beforePause = await observe(ratingKey: ratingKey, manager: downloadManager,
                                                seconds: pauseAfterSeconds, label: "pre_pause")
                downloadManager.pause(ratingKey: ratingKey)
                let paused = await waitForStatus(ratingKey: ratingKey, manager: downloadManager,
                                                 statusText: "paused", seconds: 15)
                let pausedProgress = DebugDownloadProbeSupport.observation(forRecordKey: ratingKey, in: downloadManager)
                log.notice("probe.paused reached=\(paused, privacy: .public) before=\(beforePause.progress, privacy: .public) pausedProgress=\(pausedProgress.progress, privacy: .public) bytes=\(pausedProgress.bytes, privacy: .public)")
                AppDiagnostics.record(.downloads, "probe.plex_download.paused", fields: [
                    "download_id": .identifier(ratingKey),
                    "reached": .bool(paused),
                    "progress_pct": .int(Int((pausedProgress.progress * 100).rounded())),
                    "bytes": .int(pausedProgress.bytes),
                ])
                if pauseOnly { return }
                downloadManager.retry(ratingKey: ratingKey)
                try? await Task.sleep(for: .milliseconds(500))
                let resumeStart = DebugDownloadProbeSupport.observation(forRecordKey: ratingKey, in: downloadManager)
                let afterResume = await observe(ratingKey: ratingKey, manager: downloadManager,
                                                seconds: observeSeconds, label: "post_resume")
                let resumedAtCheckpoint = pausedProgress.bytes > 0 && resumeStart.bytes >= pausedProgress.bytes
                let keptProgress = resumedAtCheckpoint
                    && afterResume.bytes >= pausedProgress.bytes
                    && afterResume.progress >= max(0, pausedProgress.progress * 0.95)
                log.notice("probe.resume_check keptProgress=\(keptProgress, privacy: .public) resumedAtCheckpoint=\(resumedAtCheckpoint, privacy: .public) paused=\(pausedProgress.progress, privacy: .public) after=\(afterResume.progress, privacy: .public) bytes=\(afterResume.bytes, privacy: .public)")
                AppDiagnostics.record(.downloads, "probe.plex_download.resume_check", fields: [
                    "download_id": .identifier(ratingKey),
                    "kept_progress": .bool(keptProgress),
                    "resumed_at_checkpoint": .bool(resumedAtCheckpoint),
                    "paused_pct": .int(Int((pausedProgress.progress * 100).rounded())),
                    "after_pct": .int(Int((afterResume.progress * 100).rounded())),
                    "paused_bytes": .int(pausedProgress.bytes),
                    "resume_start_bytes": .int(resumeStart.bytes),
                    "bytes": .int(afterResume.bytes),
                ])
            } else {
                _ = await observe(ratingKey: ratingKey, manager: downloadManager,
                                  seconds: observeSeconds, label: "started")
            }
            if deleteAfterObserve {
                downloadManager.delete(ratingKey: ratingKey)
                log.notice("probe.deleted_after_observe ratingKey=\(ratingKey, privacy: .public)")
                AppDiagnostics.record(.downloads, "probe.plex_download.deleted", fields: [
                    "download_id": .identifier(ratingKey),
                ])
            }
        } catch {
            log.error("probe.fail error=\(DiagnosticRedactor.safeErrorSummary(error), privacy: .public)")
            AppDiagnostics.record(.downloads, "probe.plex_download.fail", fields: [
                "download_id": .identifier(ratingKey),
                "error": .error(error),
            ])
        }
    }

    private static func resolveItem(ratingKey: String?, query: String?, appModel: AppModel,
                                    server: URL, token: String, dumpSearch: Bool = false) async throws -> MediaItem {
        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let episodeTarget = parseEpisodeTarget(query)
            let searchQuery = episodeTarget?.show ?? query
            let req = BrowseAPI.search(server: server, token: token, identity: appModel.identity, query: searchQuery)
            let response = try await appModel.client.send(req, as: HubsResponse.self)
            let matches = response.mediaContainer.hub.flatMap(\.metadata).filter { !$0.isContainer && !$0.isMusic }
            if dumpSearch {
                log.notice("probe.search count=\(matches.count, privacy: .public)")
                for match in matches.prefix(40) {
                    log.notice("probe.search_result ratingKey=\(match.ratingKey, privacy: .public) type=\(match.type, privacy: .public) show=\(match.grandparentTitle ?? "nil", privacy: .private) season=\(match.parentIndex ?? 0, privacy: .public) episode=\(match.index ?? 0, privacy: .public) title=\(match.title, privacy: .private)")
                }
            }
            if let target = episodeTarget,
               let episode = matches.first(where: {
                   $0.type == "episode"
                   && ($0.grandparentTitle ?? "").localizedCaseInsensitiveCompare(target.show) == .orderedSame
                   && $0.parentIndex == target.season
                   && $0.index == target.episode
               }) {
                return try await fetchItem(ratingKey: episode.ratingKey, appModel: appModel, server: server, token: token)
            }
            let skinny = matches.first { $0.title.localizedCaseInsensitiveCompare(query) == .orderedSame }
                ?? matches.first { $0.title.localizedCaseInsensitiveContains(query) }
                ?? matches.first
            if let skinny {
                return try await fetchItem(ratingKey: skinny.ratingKey, appModel: appModel, server: server, token: token)
            }
            throw ProbeError.itemNotFound(query)
        }
        return try await fetchItem(ratingKey: ratingKey ?? "17183", appModel: appModel, server: server, token: token)
    }

    private static func parseEpisodeTarget(_ raw: String) -> (show: String, season: Int, episode: Int)? {
        let pattern = #"(?i)^\s*(.*?)\s+s(\d+)e(\d+)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              match.numberOfRanges == 4,
              let showRange = Range(match.range(at: 1), in: raw),
              let seasonRange = Range(match.range(at: 2), in: raw),
              let episodeRange = Range(match.range(at: 3), in: raw),
              let season = Int(raw[seasonRange]),
              let episode = Int(raw[episodeRange]) else { return nil }
        let show = String(raw[showRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !show.isEmpty else { return nil }
        return (show, season, episode)
    }

    private static func logVersions(item: MediaItem) {
        let media = item.media ?? []
        log.notice("probe.versions count=\(media.count, privacy: .public)")
        AppDiagnostics.record(.downloads, "probe.plex_download.versions", fields: [
            "download_id": .identifier(item.ratingKey),
            "count": .int(media.count),
        ])
        for (idx, media) in media.enumerated() {
            let part = media.part.first
            let playable = OfflineDownloadDecision.existingVersionPlayableOffline(
                container: media.container ?? part?.container,
                videoCodec: media.videoCodec ?? part?.videoStreams.first?.codec)
            log.notice("probe.version index=\(idx, privacy: .public) playable=\(playable, privacy: .public) container=\((media.container ?? part?.container ?? "nil"), privacy: .public) width=\(media.width ?? 0, privacy: .public) height=\(media.height ?? 0, privacy: .public) bitrate=\(media.bitrate ?? 0, privacy: .public) size=\(part?.size ?? 0, privacy: .public)")
            AppDiagnostics.record(.downloads, "probe.plex_download.version", fields: [
                "download_id": .identifier(item.ratingKey),
                "index": .int(idx),
                "playable": .bool(playable),
                "container": .label(media.container ?? part?.container ?? "nil"),
                "width": .int(media.width ?? 0),
                "height": .int(media.height ?? 0),
                "bitrate": .int(media.bitrate ?? 0),
                "size_bytes": .int(part?.size ?? 0),
            ])
        }
    }

    private static func firstExistingVersionMediaIndex(item: MediaItem) -> Int? {
        for (idx, media) in (item.media ?? []).enumerated() where idx != 0 {
            let part = media.part.first
            if OfflineDownloadDecision.existingVersionPlayableOffline(
                container: media.container ?? part?.container,
                videoCodec: media.videoCodec ?? part?.videoStreams.first?.codec) {
                return idx
            }
        }
        return item.media?.indices.dropFirst().first
    }

    private static func probeRange(server: URL, token: String, identity: ClientIdentity,
                                   partKey: String, ratingKey: String) async {
        var req = URLRequest(url: OptimizeRequest.downloadURL(server: server, token: token, partKey: partKey))
        req.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return }
            let acceptRanges = http.value(forHTTPHeaderField: "Accept-Ranges") ?? "nil"
            let contentRange = http.value(forHTTPHeaderField: "Content-Range") ?? "nil"
            let contentLength = http.value(forHTTPHeaderField: "Content-Length") ?? "nil"
            log.notice("probe.range status=\(http.statusCode, privacy: .public) acceptRanges=\(acceptRanges, privacy: .public) contentRange=\(contentRange, privacy: .public) contentLength=\(contentLength, privacy: .public)")
            AppDiagnostics.record(.downloads, "probe.plex_download.range", fields: [
                "download_id": .identifier(ratingKey),
                "status_code": .int(http.statusCode),
                "accept_ranges": .label(acceptRanges),
                "has_content_range": .bool(contentRange != "nil"),
                "content_length": .label(contentLength),
            ])
        } catch {
            log.error("probe.range_fail error=\(DiagnosticRedactor.safeErrorSummary(error), privacy: .public)")
            AppDiagnostics.record(.downloads, "probe.plex_download.range_fail", fields: [
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

    private static func observe(ratingKey: String, manager: DownloadManager,
                                seconds: Int, label: String) async -> DebugDownloadProbeSupport.Observation {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        var latest = DebugDownloadProbeSupport.observation(forRecordKey: ratingKey, in: manager)
        while ContinuousClock.now < deadline {
            let record = manager.records.first { $0.ratingKey == ratingKey }
            let status = record.map { String(describing: $0.status) } ?? "missing"
            let progress = record?.progress ?? 0
            let bytes = record?.bytes ?? 0
            latest = DebugDownloadProbeSupport.Observation(progress: progress, bytes: bytes, status: status)
            log.notice("probe.observe label=\(label, privacy: .public) status=\(status, privacy: .public) progress=\(progress, privacy: .public) bytes=\(bytes, privacy: .public)")
            AppDiagnostics.record(.downloads, "probe.plex_download.observe", fields: [
                "download_id": .identifier(ratingKey),
                "label": .label(label),
                "status": .label(status),
                "progress_pct": .int(Int((progress * 100).rounded())),
                "bytes": .int(bytes),
            ])
            if record?.isComplete == true || record?.status == .failed { break }
            try? await Task.sleep(for: .seconds(5))
        }
        AppDiagnostics.record(.downloads, "probe.plex_download.done", fields: [
            "download_id": .identifier(ratingKey),
            "label": .label(label),
        ])
        return latest
    }

    private static func waitForStatus(ratingKey: String, manager: DownloadManager,
                                      statusText: String, seconds: Int) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            let status = DebugDownloadProbeSupport.observation(forRecordKey: ratingKey, in: manager).status
            if status == statusText { return true }
            try? await Task.sleep(for: .seconds(1))
        }
        return DebugDownloadProbeSupport.observation(forRecordKey: ratingKey, in: manager).status == statusText
    }

    private static func explicitInt(after flag: String, in arguments: [String]) -> Int? {
        guard arguments.contains(flag) else { return nil }
        return DebugDownloadProbeSupport.intValue(after: flag, in: arguments)
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
