import Foundation
import AVFoundation
import PMSKit

/// Reports playback state for one playback session: Plex `/:/timeline` heartbeats,
/// Jellyfin/Emby `Sessions/Playing*` progress, play/pause/stop transitions, and
/// the watched-state scrobble where the backend has a separate marker endpoint.
///
/// Extracted from `PlaybackController` so the reporting state machine (dedup of
/// unchanged heartbeats, the one-shot scrobble, the readiness gate) lives in one
/// place. One reporter per controller, spanning Quality reloads: `didScrobble` is
/// deliberately NOT reset when the stream rebuilds, because the same content
/// shouldn't re-scrobble mid-watch.
///
/// Local-file playback constructs this with no server/progress session; every send
/// then no-ops (there is no server session to report against).
@MainActor
final class TimelineReporter {

    private let item: MediaItem
    private let server: URL?
    private let token: String?
    private let identity: ClientIdentity
    private var client: PlexClient
    private let player: AVPlayer
    private let mediaBrowserProgressSession: (@MainActor () -> MediaBrowserPlaybackProgressSession?)?
    private let mediaBrowserProgressExecutor: MediaBrowserRequestExecutor

    /// True once the current item has reached `.readyToPlay` with a real duration.
    /// Set by the controller's status observer; reset on each item (re)load. Gates
    /// timeline/scrobble heartbeats during readyToPlay churn (P8 #11): a
    /// `duration=0` / `time≈0` heartbeat confuses PMS Continue Watching.
    var isReadyForReporting = false

    private var lastTimelineState: TimelineRequest.State?
    private var lastReportedSecond: Int = -1
    private var didScrobble = false
    private var isSendInFlight = false
    private var sendCoalescer = TimelineSendCoalescer<PendingSend>()
    private var mediaBrowserStartAuthority = MediaBrowserPlaybackStartAuthority()

    private struct PendingSend: Sendable {
        enum Destination: Sendable {
            case plex(PlexRequest, PlexClient)
            case mediaBrowser(URLRequest,
                              MediaBrowserRequestExecutor,
                              sessionKey: String,
                              event: MediaBrowserPlaybackProgressEvent)
        }

        enum Kind: Sendable {
            case timeline(state: TimelineRequest.State, positionMs: Int, durationMs: Int)
            case scrobble

            var coalescerKind: TimelineSendCoalescer<PendingSend>.Kind {
                switch self {
                case .timeline(let state, _, _): .timeline(state)
                case .scrobble: .scrobble
                }
            }
        }

        let destination: Destination
        let kind: Kind
    }

    init(item: MediaItem,
         server: URL?,
         token: String?,
         identity: ClientIdentity,
         client: PlexClient,
         player: AVPlayer,
         mediaBrowserProgressSession: (@MainActor () -> MediaBrowserPlaybackProgressSession?)? = nil,
         mediaBrowserProgressExecutor: MediaBrowserRequestExecutor = MediaBrowserRequestExecutor(session: .shared)) {
        self.item = item
        self.server = server
        self.token = token
        self.identity = identity
        self.client = client
        self.player = player
        self.mediaBrowserProgressSession = mediaBrowserProgressSession
        self.mediaBrowserProgressExecutor = mediaBrowserProgressExecutor
    }

    /// Swap future timeline/scrobble sends to a fresh control-plane client after player
    /// recovery (#33). Existing in-flight sends may still finish/fail on the old client, but
    /// new heartbeats won't reuse a connection pool suspected to be poisoned.
    func useClient(_ client: PlexClient) {
        self.client = client
    }

    /// Send a timeline heartbeat. Skips when nothing meaningful changed (same state
    /// within the same second bucket) unless `force` is set.
    func report(state: TimelineRequest.State,
                force: Bool,
                positionMs positionOverrideMs: Int? = nil) {
        let remoteProgressSession = mediaBrowserProgressSession?()
        // Local-file playback has no server session to report to.
        guard server != nil && token != nil || remoteProgressSession != nil else { return }

        // Don't post heartbeats until the item is genuinely ready with a real duration
        // (P8 #11). The final `.stopped` is exempt so we always flush a true offset when
        // the user leaves (even if we never reached the readiness gate).
        if !isReadyForReporting && state != .stopped { return }

        let durationMs = item.duration
            ?? Int((player.currentItem?.duration.seconds ?? 0).isFinite ? (player.currentItem?.duration.seconds ?? 0) * 1000 : 0)
        // Guard against duration=0 heartbeats slipping through (e.g. a .stopped before
        // the gate opened with no known item duration).
        guard durationMs > 0 || state == .stopped else { return }

        let currentMs = max(0, positionOverrideMs
            ?? Int(player.currentTime().seconds.isFinite ? player.currentTime().seconds * 1000 : 0))
        let currentSecond = currentMs / 1000
        let mediaBrowserSessionChanged = remoteProgressSession.map {
            !mediaBrowserStartAuthority.isCurrentSession($0.sessionKey)
        } ?? false

        if !force,
           !mediaBrowserSessionChanged,
           state == lastTimelineState,
           currentSecond == lastReportedSecond {
            return
        }
        lastTimelineState = state
        lastReportedSecond = currentSecond

        let metadataKey = item.key ?? "/library/metadata/\(item.ratingKey)"

        if let server, let token {
            let req = TimelineRequest.timeline(server: server,
                                               token: token,
                                               identity: identity,
                                               ratingKey: item.ratingKey,
                                               key: metadataKey,
                                               state: state,
                                               timeMs: currentMs,
                                               durationMs: durationMs)
            enqueue(PendingSend(destination: .plex(req, client),
                                kind: .timeline(state: state,
                                                positionMs: currentMs,
                                                durationMs: durationMs)))
        }

        if let remoteProgressSession,
           let pending = mediaBrowserProgressRequest(session: remoteProgressSession,
                                                     state: state,
                                                     positionMs: currentMs) {
            enqueue(PendingSend(destination: .mediaBrowser(pending.request,
                                                           mediaBrowserProgressExecutor,
                                                           sessionKey: remoteProgressSession.sessionKey,
                                                           event: pending.event),
                                kind: .timeline(state: state,
                                                positionMs: currentMs,
                                                durationMs: durationMs)))
        }
    }

    /// Mark the item watched on PMS, exactly once per session (`didScrobble`).
    func scrobble() {
        guard !didScrobble else { return }
        didScrobble = true
        guard let server, let token else { return }
        let req = TimelineRequest.scrobble(server: server,
                                           token: token,
                                           identity: identity,
                                           ratingKey: item.ratingKey)
        enqueue(PendingSend(destination: .plex(req, client), kind: .scrobble))
    }

    /// Fire the scrobble once the playhead crosses ~90% of the duration (P9 #11):
    /// capped-HLS viewers often stop short of EOF, so didPlayToEnd never fires and
    /// the item stays "unwatched". `scrobble()` guards re-entry; didPlayToEnd remains
    /// the backstop for the final stretch.
    func scrobbleIfNearEnd() {
        guard !didScrobble, isReadyForReporting else { return }
        let durSecs = player.currentItem?.duration.seconds ?? 0
        guard durSecs.isFinite, durSecs > 0 else { return }
        let curSecs = player.currentTime().seconds
        guard curSecs.isFinite else { return }
        if curSecs / durSecs >= 0.90 {
            scrobble()
        }
    }

    private func enqueue(_ send: PendingSend) {
        guard sendCoalescer.enqueue(send, kind: send.kind.coalescerKind) else { return }
        if !isSendInFlight {
            sendNext()
        }
    }

    private func sendNext() {
        guard let next = sendCoalescer.popFirst() else {
            isSendInFlight = false
            return
        }
        isSendInFlight = true
        let send = next.event
        Task {
            var acceptedMediaBrowserStart: (sessionKey: String, event: MediaBrowserPlaybackProgressEvent)?
            do {
                switch send.destination {
                case .plex(let request, let client):
                    try await client.send(request)
                case .mediaBrowser(let request, let executor, let sessionKey, let event):
                    try await executor.send(request)
                    acceptedMediaBrowserStart = (sessionKey, event)
                }
            } catch {
                await MainActor.run {
                    self.recordSendFailure(send.kind, error: error)
                }
            }
            await MainActor.run {
                if let acceptedMediaBrowserStart {
                    self.mediaBrowserStartAuthority.recordAccepted(
                        event: acceptedMediaBrowserStart.event,
                        sessionKey: acceptedMediaBrowserStart.sessionKey)
                }
                self.sendNext()
            }
        }
    }

    private func mediaBrowserProgressRequest(session: MediaBrowserPlaybackProgressSession,
                                             state: TimelineRequest.State,
                                             positionMs: Int) -> (request: URLRequest,
                                                                  event: MediaBrowserPlaybackProgressEvent)? {
        let sessionKey = session.sessionKey
        let event = mediaBrowserStartAuthority.event(for: state, sessionKey: sessionKey)
        do {
            let request = try session.request(for: event,
                                              positionMs: positionMs,
                                              isPaused: state == .paused)
            return (request, event)
        } catch {
            AppDiagnostics.record(.timeline, "mediabrowser_progress.build_failed", fields: [
                "backend": .label(session.backend.rawValue),
                "event": .label(String(describing: event)),
                "position": .millisecondsBucket(positionMs),
                "error": .error(error),
            ])
            NSLog("TimelineReporter: MediaBrowser progress request build failed (%@)",
                  DiagnosticRedactor.safeErrorSummary(error))
            return nil
        }
    }

    private func recordSendFailure(_ kind: PendingSend.Kind, error: Error) {
        switch kind {
        case .timeline(let state, let positionMs, let durationMs):
            AppDiagnostics.record(.timeline, "timeline.send_failed", fields: [
                "state": .label(state.rawValue),
                "position": .millisecondsBucket(positionMs),
                "duration": .millisecondsBucket(durationMs),
                "error": .error(error),
            ])
            NSLog("TimelineReporter: timeline send failed (%@)",
                  DiagnosticRedactor.safeErrorSummary(error))
        case .scrobble:
            AppDiagnostics.record(.timeline, "timeline.scrobble_failed", fields: [
                "error": .error(error),
            ])
            NSLog("TimelineReporter: scrobble send failed (%@)",
                  DiagnosticRedactor.safeErrorSummary(error))
        }
    }
}
