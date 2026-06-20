#if DEBUG
import AVFoundation
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
    private static let log = Logger(subsystem: "com.jlipworth.VisionPlay", category: "EmbyProbe")

    static func runIfRequested(appModel: AppModel) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--vp-probe-emby-playback") else { return }

        // Enable diagnostics for the duration of the probe so its events land in the ring buffer,
        // then restore the user-facing flag — the probe must not silently flip a persisted setting.
        let priorDiagnosticsEnabled = AppDiagnostics.isEnabled
        AppDiagnostics.setEnabled(true)
        defer { AppDiagnostics.setEnabled(priorDiagnosticsEnabled) }

        let query = value(after: "--vp-probe-query", in: arguments) ?? "12 Years a Slave"
        let bitrateKbps = intValue(after: "--vp-probe-bitrate-kbps", in: arguments) ?? appModel.activeStreamingQualityKbps
        let seekMs = intValue(after: "--vp-probe-seek-ms", in: arguments) ?? 16 * 60 * 1000
        let postSeekHoldSeconds = intValue(after: "--vp-probe-post-seek-hold-seconds", in: arguments) ?? 20

        log.notice("probe.start backend=\(appModel.activeBackend.rawValue, privacy: .public) query=\(query, privacy: .public) bitrate_kbps=\(bitrateKbps, privacy: .public) seek_ms=\(seekMs, privacy: .public)")
        AppDiagnostics.record(.playback, "probe.emby.start", fields: [
            "backend": .label(appModel.activeBackend.rawValue),
            "query": .text(query),
            "quality_kbps": .int(bitrateKbps),
            "target": .millisecondsBucket(seekMs),
        ])

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

            let initial = try await service.playbackOpen(item: detailed, maxVideoBitrateKbps: bitrateKbps)
            let playback = PlaybackController(remoteStreamURL: initial.url,
                                              item: detailed,
                                              identity: appModel.identity,
                                              client: appModel.client,
                                              httpHeaders: initial.requiredHTTPHeaders,
                                              remotePlaySessionId: initial.playSessionId,
                                              sourceMetadata: initial.sourceMetadata.asRemoteCarrier(),
                                              playMethod: initial.playMethod.asRemoteCarrier(),
                                              onStopRemoteSession: {
                                                  Task {
                                                      if initial.usesServerEncoding {
                                                          await EmbyBrowseService(appModel: appModel)
                                                              .stopActiveEncoding(playSessionId: initial.playSessionId)
                                                      }
                                                  }
                                              },
                                              remoteStreamReopener: { request in
                                                  let reopened = try await EmbyBrowseService(appModel: appModel)
                                                      .playbackOpen(item: detailed,
                                                                    maxVideoBitrateKbps: request.bitrateKbps,
                                                                    resumeOffsetMs: request.offsetMs,
                                                                    audioStreamIndex: request.audioStreamIndex,
                                                                    subtitleStreamIndex: request.subtitleStreamIndex)
                                                  return RemoteStreamOpenResult(
                                                      url: reopened.url,
                                                      headers: reopened.requiredHTTPHeaders,
                                                      playSessionId: reopened.playSessionId,
                                                      sourceMetadata: reopened.sourceMetadata.asRemoteCarrier(),
                                                      playMethod: reopened.playMethod.asRemoteCarrier(),
                                                      onStop: {
                                                          Task {
                                                              if reopened.usesServerEncoding {
                                                                  await EmbyBrowseService(appModel: appModel)
                                                                      .stopActiveEncoding(playSessionId: reopened.playSessionId)
                                                              }
                                                          }
                                                      })
                                              },
                                              maxVideoBitrateKbps: bitrateKbps,
                                              qualityDefaultsKey: appModel.activeStreamingQualityDefaultsKey)
            controller = playback
            playback.start()

            try await waitUntilPlayable(playback, phase: "initial", timeoutSeconds: 45)
            log.notice("probe.initial_playing position_ms=\(playback.currentResumeMs, privacy: .public)")

            playback.performUserSeek(toMs: seekMs)
            try await waitUntilPlayable(playback, phase: "post_seek", timeoutSeconds: 45)
            try await holdWithPlaybackProgress(playback, seconds: postSeekHoldSeconds)

            log.notice("probe.pass position_ms=\(playback.currentResumeMs, privacy: .public) failed=\(playback.playbackError.isFailed, privacy: .public)")
            AppDiagnostics.record(.playback, "probe.emby.pass", fields: [
                "resume": .millisecondsBucket(playback.currentResumeMs),
                "target": .millisecondsBucket(seekMs),
            ])
            playback.stop()
            controller = nil
        } catch {
            log.error("probe.fail error=\(String(describing: error), privacy: .public)")
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
        throw ProbeError.itemNotFound(query)
    }

    private static func waitUntilPlayable(_ controller: PlaybackController,
                                          phase: String,
                                          timeoutSeconds: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
        while ContinuousClock.now < deadline {
            if controller.playbackError.isFailed {
                throw ProbeError.playbackFailed(phase, controller.playbackError.message)
            }
            if controller.player.currentItem?.status == .readyToPlay,
               controller.player.rate > 0 {
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw ProbeError.timeout(phase)
    }

    private static func holdWithPlaybackProgress(_ controller: PlaybackController, seconds: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        var initialPositionMs: Int?
        var lastPositionMs = rawPlayerPositionMs(controller)
        var bestPositionMs = lastPositionMs
        var consecutiveWaitingSamples = 0
        var movingSamples = 0
        while ContinuousClock.now < deadline {
            if controller.playbackError.isFailed {
                throw ProbeError.playbackFailed("hold", controller.playbackError.message)
            }
            let currentPositionMs = rawPlayerPositionMs(controller)
            if initialPositionMs == nil, currentPositionMs > 1_000 {
                initialPositionMs = currentPositionMs
                lastPositionMs = currentPositionMs
                bestPositionMs = currentPositionMs
            }
            bestPositionMs = max(bestPositionMs, currentPositionMs)
            if currentPositionMs >= lastPositionMs + 500 {
                movingSamples += 1
                log.notice("probe.progress position_ms=\(currentPositionMs, privacy: .public) status=\(String(describing: controller.player.timeControlStatus), privacy: .public) rate=\(controller.player.rate, privacy: .public)")
                lastPositionMs = currentPositionMs
            }
            if controller.player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                consecutiveWaitingSamples += 1
            } else {
                consecutiveWaitingSamples = 0
            }
            if consecutiveWaitingSamples >= 20 {
                throw ProbeError.playbackStalled(bestPositionMs - (initialPositionMs ?? lastPositionMs),
                                                 "player remained waiting during hold")
            }
            try await Task.sleep(for: .seconds(1))
        }
        let baselineMs = initialPositionMs ?? lastPositionMs
        let advancedMs = bestPositionMs - baselineMs
        guard advancedMs >= min(3_000, max(1_000, seconds * 500)), movingSamples >= 3 else {
            throw ProbeError.playbackStalled(advancedMs, "playhead did not advance enough")
        }
    }

    private static func rawPlayerPositionMs(_ controller: PlaybackController) -> Int {
        let seconds = controller.player.currentTime().seconds
        guard seconds.isFinite, seconds >= 0 else { return 0 }
        return Int(seconds * 1000)
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
        case timeout(String)
        case playbackFailed(String, String?)
        case playbackStalled(Int, String)

        var description: String {
            switch self {
            case .itemNotFound(let query): return "item not found for query \(query)"
            case .timeout(let phase): return "timed out waiting for \(phase) playback"
            case .playbackFailed(let phase, let message): return "playback failed during \(phase): \(message ?? "no message")"
            case .playbackStalled(let advancedMs, let reason): return "playback stalled during hold: \(reason), advanced \(advancedMs)ms"
            }
        }
    }
}
#endif
