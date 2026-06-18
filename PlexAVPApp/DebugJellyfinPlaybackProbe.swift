#if DEBUG
import AVFoundation
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
    private static let log = Logger(subsystem: "com.jlipworth.VisionPlex", category: "JellyfinProbe")

    static func runIfRequested(appModel: AppModel) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--vp-probe-jellyfin-playback") else { return }

        UserDefaults.standard.set(true, forKey: AppDiagnostics.enabledDefaultsKey)

        let query = value(after: "--vp-probe-query", in: arguments) ?? "1917"
        let bitrateKbps = intValue(after: "--vp-probe-bitrate-kbps", in: arguments) ?? appModel.activeStreamingQualityKbps
        let seekMs = intValue(after: "--vp-probe-seek-ms", in: arguments) ?? 16 * 60 * 1000
        let postSeekHoldSeconds = intValue(after: "--vp-probe-post-seek-hold-seconds", in: arguments) ?? 20

        log.notice("probe.start backend=\(appModel.activeBackend.rawValue, privacy: .public) query=\(query, privacy: .public) bitrate_kbps=\(bitrateKbps, privacy: .public) seek_ms=\(seekMs, privacy: .public)")
        AppDiagnostics.record(.playback, "probe.jellyfin.start", fields: [
            "backend": .label(appModel.activeBackend.rawValue),
            "query": .text(query),
            "quality_kbps": .int(bitrateKbps),
            "target": .millisecondsBucket(seekMs),
        ])

        guard appModel.activeBackend == .jellyfin, appModel.isBrowseReady else {
            log.error("probe.fail reason=not_jellyfin_or_not_ready")
            return
        }

        let service = JellyfinBrowseService(appModel: appModel)
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
                                              sourceMetadata: initial.sourceMetadata,
                                              playMethod: initial.playMethod,
                                              onStopRemoteSession: {
                                                  Task {
                                                      await JellyfinBrowseService(appModel: appModel)
                                                          .stopActiveEncoding(playSessionId: initial.playSessionId)
                                                  }
                                              },
                                              remoteStreamReopener: { request in
                                                  let reopened = try await JellyfinBrowseService(appModel: appModel)
                                                      .playbackOpen(item: detailed,
                                                                    maxVideoBitrateKbps: request.bitrateKbps,
                                                                    resumeOffsetMs: request.offsetMs,
                                                                    audioStreamIndex: request.audioStreamIndex,
                                                                    subtitleStreamIndex: request.subtitleStreamIndex)
                                                  return RemoteStreamOpenResult(
                                                      url: reopened.url,
                                                      headers: reopened.requiredHTTPHeaders,
                                                      playSessionId: reopened.playSessionId,
                                                      sourceMetadata: reopened.sourceMetadata,
                                                      playMethod: reopened.playMethod,
                                                      onStop: {
                                                          Task {
                                                              await JellyfinBrowseService(appModel: appModel)
                                                                  .stopActiveEncoding(playSessionId: reopened.playSessionId)
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
            try await holdWithoutFailure(playback, seconds: postSeekHoldSeconds)

            log.notice("probe.pass position_ms=\(playback.currentResumeMs, privacy: .public) failed=\(playback.playbackError.isFailed, privacy: .public)")
            AppDiagnostics.record(.playback, "probe.jellyfin.pass", fields: [
                "resume": .millisecondsBucket(playback.currentResumeMs),
                "target": .millisecondsBucket(seekMs),
            ])
            playback.stop()
            controller = nil
        } catch {
            log.error("probe.fail error=\(String(describing: error), privacy: .public)")
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
               controller.player.timeControlStatus == .playing || controller.player.rate > 0 {
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw ProbeError.timeout(phase)
    }

    private static func holdWithoutFailure(_ controller: PlaybackController, seconds: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if controller.playbackError.isFailed {
                throw ProbeError.playbackFailed("hold", controller.playbackError.message)
            }
            try await Task.sleep(for: .milliseconds(500))
        }
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

        var description: String {
            switch self {
            case .itemNotFound(let query): return "item not found for query \(query)"
            case .timeout(let phase): return "timed out waiting for \(phase) playback"
            case .playbackFailed(let phase, let message): return "playback failed during \(phase): \(message ?? "no message")"
            }
        }
    }
}
#endif
