import Foundation
import AVKit
import PMSKit

/// Reports playback state to PMS for one playback session: the ~10s timeline
/// heartbeats, play/pause/stop transitions, and the watched-state scrobble.
///
/// Extracted from `PlaybackController` so the reporting state machine (dedup of
/// unchanged heartbeats, the one-shot scrobble, the readiness gate) lives in one
/// place. One reporter per controller, spanning Quality reloads: `didScrobble` is
/// deliberately NOT reset when the stream rebuilds, because the same content
/// shouldn't re-scrobble mid-watch.
///
/// Local-file playback constructs this with `server`/`token` nil; every send then
/// no-ops (there is no server session to report against).
@MainActor
final class TimelineReporter {

    private let item: MediaItem
    private let server: URL?
    private let token: String?
    private let identity: ClientIdentity
    private var client: PlexClient
    private let player: AVPlayer

    /// True once the current item has reached `.readyToPlay` with a real duration.
    /// Set by the controller's status observer; reset on each item (re)load. Gates
    /// timeline/scrobble heartbeats during readyToPlay churn (P8 #11): a
    /// `duration=0` / `time≈0` heartbeat confuses PMS Continue Watching.
    var isReadyForReporting = false

    private var lastTimelineState: TimelineRequest.State?
    private var lastReportedSecond: Int = -1
    private var didScrobble = false

    init(item: MediaItem,
         server: URL?,
         token: String?,
         identity: ClientIdentity,
         client: PlexClient,
         player: AVPlayer) {
        self.item = item
        self.server = server
        self.token = token
        self.identity = identity
        self.client = client
        self.player = player
    }

    /// Swap future timeline/scrobble sends to a fresh control-plane client after player
    /// recovery (#33). Existing in-flight sends may still finish/fail on the old client, but
    /// new heartbeats won't reuse a connection pool suspected to be poisoned.
    func useClient(_ client: PlexClient) {
        self.client = client
    }

    /// Send a timeline heartbeat. Skips when nothing meaningful changed (same state
    /// within the same second bucket) unless `force` is set.
    func report(state: TimelineRequest.State, force: Bool) {
        // Local-file playback has no server session to report to.
        guard let server, let token else { return }

        // Don't post heartbeats until the item is genuinely ready with a real duration
        // (P8 #11). The final `.stopped` is exempt so we always flush a true offset when
        // the user leaves (even if we never reached the readiness gate).
        if !isReadyForReporting && state != .stopped { return }

        let durationMs = item.duration
            ?? Int((player.currentItem?.duration.seconds ?? 0).isFinite ? (player.currentItem?.duration.seconds ?? 0) * 1000 : 0)
        // Guard against duration=0 heartbeats slipping through (e.g. a .stopped before
        // the gate opened with no known item duration).
        guard durationMs > 0 || state == .stopped else { return }

        let currentMs = Int(player.currentTime().seconds.isFinite ? player.currentTime().seconds * 1000 : 0)
        let currentSecond = currentMs / 1000

        if !force,
           state == lastTimelineState,
           currentSecond == lastReportedSecond {
            return
        }
        lastTimelineState = state
        lastReportedSecond = currentSecond

        let metadataKey = item.key ?? "/library/metadata/\(item.ratingKey)"

        let req = TimelineRequest.timeline(server: server,
                                           token: token,
                                           identity: identity,
                                           ratingKey: item.ratingKey,
                                           key: metadataKey,
                                           state: state,
                                           timeMs: currentMs,
                                           durationMs: durationMs)
        Task {
            do { try await client.send(req) }
            catch {
                NSLog("TimelineReporter: timeline send failed (%@)", String(describing: error))
            }
        }
    }

    /// Mark the item watched on PMS, exactly once per session (`didScrobble`).
    func scrobble() {
        guard !didScrobble, let server, let token else { return }
        didScrobble = true
        let req = TimelineRequest.scrobble(server: server,
                                           token: token,
                                           identity: identity,
                                           ratingKey: item.ratingKey)
        Task {
            do { try await client.send(req) }
            catch {
                NSLog("TimelineReporter: scrobble send failed (%@)", String(describing: error))
            }
        }
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
}
