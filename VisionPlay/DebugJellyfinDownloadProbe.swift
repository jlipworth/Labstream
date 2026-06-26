#if DEBUG
import Foundation
import os
import PMSKit

/// Launch-argument driven simulator probe for the Jellyfin OFFLINE DOWNLOAD path (GH #135).
///
/// Mirrors `DebugEmbyDownloadProbe`: runs inside the signed-in app process on the booted simulator,
/// so it exercises the real `DownloadManager.downloadJellyfin` glue (route negotiation → record
/// lifecycle) against the live server using the restored Keychain Jellyfin session — no tokens
/// exposed. Unlike Emby, Jellyfin has no server-side "Convert Media" prep: `.original` is a static,
/// range-resumable file download; `.optimize`/`.optimizeCompatible` stream a server-rendered MP4
/// (forward-only). The clean `.complete` check is therefore a small direct-play `.original` item.
///
/// Inert unless launched with `--vp-probe-jellyfin-download`. Requires the app to already be signed
/// in to Jellyfin (the probe does not authenticate; sign in once via the UI first).
///
/// Modes:
///   • default — DRY RUN: resolve the item and log its container/local-playability without transfer.
///   • `--vp-probe-start-download` — start `downloadJellyfin(.original)`, observe the record for
///     `--vp-probe-observe-seconds` (default 60), then DELETE it (unless `--vp-probe-keep-record`).
///   • `--vp-probe-start-optimize [--vp-probe-download-preset "1080p 8 Mbps"]` — start the
///     live-transcode `.optimize` lane instead (forward-only; won't complete for a large item).
@MainActor
enum DebugJellyfinDownloadProbe {
    private static let log = Logger(subsystem: "com.jlipworth.VisionPlay", category: "JellyfinDownloadProbe")

    static func runIfRequested(appModel: AppModel, downloadManager: DownloadManager) async {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--vp-probe-jellyfin-download") else { return }

        let prior = AppDiagnostics.isEnabled
        AppDiagnostics.setEnabled(true)
        defer { AppDiagnostics.setEnabled(prior) }

        let query = DebugDownloadProbeSupport.value(after: "--vp-probe-query", in: args) ?? ""
        let ratingKey = DebugDownloadProbeSupport.value(after: "--vp-probe-rating-key", in: args)
        let startDownload = args.contains("--vp-probe-start-download")
        let optimize = args.contains("--vp-probe-start-optimize")
        let preset = DebugDownloadProbeSupport.value(after: "--vp-probe-download-preset", in: args) ?? "1080p 8 Mbps"
        let keepRecord = args.contains("--vp-probe-keep-record")
        let observeSeconds = DebugDownloadProbeSupport.intValue(after: "--vp-probe-observe-seconds", in: args) ?? 60

        log.notice("probe.start backend=\(appModel.activeBackend.rawValue, privacy: .public) query=\(query, privacy: .private) start=\(startDownload, privacy: .public) optimize=\(optimize, privacy: .public)")

        guard appModel.backendSession(for: .jellyfin) != nil else {
            log.error("probe.fail reason=not_jellyfin_configured")
            AppDiagnostics.record(.downloads, "probe.jellyfin_download.fail", fields: [
                "reason": .label("not_jellyfin_configured"),
            ])
            return
        }

        let service = JellyfinBrowseService(appModel: appModel)
        do {
            // Prefer an explicit item id (unambiguous) over a query search.
            let item: MediaItem
            if let ratingKey, !ratingKey.isEmpty {
                item = try await service.metadata(itemId: ratingKey)
            } else {
                item = try await resolveItem(query: query, service: service)
            }
            let recordKey = "jellyfin:\(item.ratingKey)"
            let media = item.media?.first
            let part = media?.part.first
            let container = (part?.container ?? media?.container ?? "").lowercased()
            let localPlayable = OfflineDownloadDecision.isLocallyPlayableOriginal(part: part)
            log.notice("probe.route title=\(item.title, privacy: .private) container=\(container, privacy: .public) localPlayable=\(localPlayable, privacy: .public) optimize=\(optimize, privacy: .public)")
            AppDiagnostics.record(.downloads, "probe.jellyfin_download.route", fields: [
                "container": .label(container.isEmpty ? "unknown" : container),
                "local_playable": .bool(localPlayable),
                "optimize": .bool(optimize),
            ])

            guard startDownload || optimize else {
                log.notice("probe.pass dry_run=true container=\(container, privacy: .public) localPlayable=\(localPlayable, privacy: .public)")
                return
            }

            let choice: DownloadManager.DownloadChoice = optimize ? .optimize(targetName: preset) : .original
            await downloadManager.downloadJellyfin(item, choice: choice)
            let progressed = await observe(recordKey: recordKey, manager: downloadManager, seconds: observeSeconds)
            if !keepRecord { downloadManager.delete(ratingKey: recordKey) }
            log.notice("probe.pass dry_run=false optimize=\(optimize, privacy: .public) progressed=\(progressed, privacy: .public)")
            AppDiagnostics.record(.downloads, "probe.jellyfin_download.pass", fields: [
                "dry_run": .bool(false),
                "optimize": .bool(optimize),
                "progressed": .bool(progressed),
            ])
        } catch {
            log.error("probe.fail error=\(String(describing: error), privacy: .public)")
            AppDiagnostics.record(.downloads, "probe.jellyfin_download.fail", fields: [
                "error": .error(error),
            ])
        }
    }

    private static func resolveItem(query: String, service: JellyfinBrowseService) async throws -> MediaItem {
        let items = try await service.items(parentId: nil,
                                            recursive: true,
                                            limit: 20,
                                            searchTerm: query.isEmpty ? nil : query,
                                            sortBy: "SortName",
                                            includeItemTypes: "Movie,Episode")
        if let exact = items.first(where: { $0.title.localizedCaseInsensitiveCompare(query) == .orderedSame && !$0.isContainer }) {
            return exact
        }
        if let playable = items.first(where: { !$0.isContainer && !$0.isMusic }) {
            return playable
        }
        throw ProbeError.itemNotFound(query)
    }

    private static func observe(recordKey: String, manager: DownloadManager, seconds: Int) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        var latest = DebugDownloadProbeSupport.observation(forRecordKey: recordKey, in: manager)
        while ContinuousClock.now < deadline {
            latest = DebugDownloadProbeSupport.observation(forRecordKey: recordKey, in: manager)
            log.notice("probe.observe status=\(latest.status, privacy: .public) progress=\(latest.progress, privacy: .public) bytes=\(latest.bytes, privacy: .public)")
            AppDiagnostics.record(.downloads, "probe.jellyfin_download.observe", fields: [
                "status": .label(latest.status),
                "progress_pct": .int(Int((latest.progress * 100).rounded())),
                "bytes": .int(latest.bytes),
            ])
            let record = manager.records.first { $0.ratingKey == recordKey }
            if record?.isComplete == true || record?.status == .failed { break }
            try? await Task.sleep(for: .seconds(5))
        }
        return latest.status == "downloading" || latest.bytes > 0 || latest.progress > 0
    }

    private enum ProbeError: Error { case itemNotFound(String) }
}
#endif
