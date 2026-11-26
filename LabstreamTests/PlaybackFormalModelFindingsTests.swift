import CoreFoundation
import Foundation
import PMSKit
import Testing
@testable import Labstream

/// Orderings the TLA+ model of the playback controller found on the current design
/// (`specs/playback/{restart,plex,jellyfin,emby}/Finding-*.cfg`,
/// `docs/plans/2026-11-25-playback-tla-model.md`).
///
/// Each test states the behaviour the design wants. A test for an open finding is wrapped in
/// `withKnownIssue`, so the suite stays green while the finding is open. When a fix lands the
/// expectations hold, no issue is recorded, and `withKnownIssue` fails the test: delete the
/// wrapper then, and turn the matching `Finding-*.cfg` into a `Faithful-*-off.cfg`.
///
/// The Plex pins drive a real `PlaybackController` against a per-test `URLProtocol` that records
/// every control-plane request and can hold a response, so the orderings the model found are
/// forced deterministically. The server is the TEST-NET placeholder, so AVPlayer's media-plane
/// connection simply never completes and no player callback interferes within a test. The
/// Jellyfin pins drive the controller through the session's reopener and stop callbacks.
/// Preconditions are `#require`d outside `withKnownIssue`, so a pin that no longer reaches its
/// ordering fails instead of passing vacuously.
///
/// #524 (proxy installed after cleanup) has no hermetic route: the stand-ups that write the slot
/// are the Emby remote-HLS proxy and the DV-injection proxy, both behind live prewarm or a DV
/// source. It pins the shape of the source until the stand-up is extracted into a policy that
/// decides "install or stop" from the generation re-checked after `await oldProxy.stop`.
/// #525 (Close does not join the cancelled Plex start) is not pinned: cancelling the task
/// cancels the start's URLSession task at once, so the task unwinds and Close's stop is sent
/// after the start resolves on the client already today. The defect is only visible on the
/// server (the start reaching PMS after the stop), which no client-visible event can anchor.
/// A pin keyed to that would be vacuous on current code or unpassable under the issue's fix.
/// #529's conditional half and #536 are server behaviours and are not pinned here.
/// The proxy findings (#533, #534) are pinned in PMSKit's `PlaybackFormalModelFindingsTests`.
@Suite("Playback formal-model findings (controller)", .serialized)
@MainActor
struct PlaybackFormalModelFindingsTests {

    // MARK: - Restart / proxy

    /// Restart-ProxyAfterCleanup (#524). A stand-up awaits `oldProxy.stop(...)` and then writes
    /// `remoteHLSProxy = proxy` with no generation check; Close or `surfaceFailure` in that
    /// window clears the slot, and the resumed task installs a proxy nothing will stop
    /// (`restart/Finding-ProxyAfterCleanup.cfg`, `ProxyOwnership`). Source-text pin: every
    /// such stand-up must re-check the generation between the await and the install. The three
    /// sites are the macOS P7 candidate and DV-injection proxies in `startStreaming` and the Emby
    /// remote-HLS proxy in `prepareRemoteStreamURL`; none is reachable hermetically (DV source
    /// and settings, or live prewarm). Replace this with a behavioural pin once the stand-up's
    /// "install or stop" step is extracted into a policy that takes the generation re-checked
    /// after `await oldProxy.stop`.
    @Test("#524: a proxy stand-up re-checks the generation after awaiting the old proxy's stop")
    func proxyStandUpRechecksGenerationAfterAwaitingOldProxyStop() throws {
        let path = "Labstream/Shared/Player/PlaybackController.swift"
        var windows: [String] = []
        for function in ["startStreaming", "prepareRemoteStreamURL"] {
            let body = try #require(Self.appFunctionSource(named: function, in: path), "\(function) not found")
            var searchStart = body.startIndex
            while let stop = body.range(of: "await oldProxy.stop(generation: oldGeneration)",
                                        range: searchStart..<body.endIndex) {
                let install = try #require(body.range(of: "remoteHLSProxy = proxy",
                                                      range: stop.upperBound..<body.endIndex),
                                           "\(function): stop without a following install")
                windows.append(String(body[stop.upperBound..<install.lowerBound]))
                searchStart = install.upperBound
            }
        }
        try #require(windows.count == 3, "expected the P7, DV-injection and Emby remote-HLS stand-ups, found \(windows.count)")
        withKnownIssue("TLA+ finding Restart-ProxyAfterCleanup (#524): a stand-up installs its proxy after cleanup without re-checking the generation") {
            for window in windows {
                #expect(window.contains("playbackGeneration") || window.contains("isCurrentPlaybackLifecycle"),
                        "no generation re-check between awaiting the old proxy's stop and installing the new one")
            }
        }
    }

    // MARK: - Plex

    /// Restart-RetryWedgedByAttach (#526). From the error overlay the user changes quality and
    /// taps Retry; the retry task waits on the failure's pending stop while the quality
    /// restart's `load()` supersedes its generation, and it returns without clearing
    /// `failureRetryTask`. On the next failure Retry does nothing
    /// (`restart/Finding-RetryWedgedByAttach.cfg`, `RetryRuns`).
    @Test("#526: Retry still runs after a quality change superseded an earlier retry")
    func retryStillRunsAfterAQualityChangeSupersededAnEarlierRetry() async throws {
        let route = PlexFixtureRoute(videoDecision: "transcode")
        let controller = makePlexController(route: route, maxVideoBitrateKbps: 4000)
        defer { route.hold([]); route.releaseHeld(); controller.stop() }
        controller.start()
        try #require(await eventually { route.count(.decision, .began) == 1 })
        route.hold([.stop])
        controller.surfaceReconnectTimeout()
        try #require(controller.playbackError.isFailed)
        try #require(await eventually { route.count(.stop, .began) == 1 }, "failure sent no stop")
        controller.reload(bitrateKbps: 2000)   // quality change from the overlay keeps the error
        try #require(controller.playbackError.isFailed)
        controller.retry()                     // waits on the failure's (held) stop
        // The quality restart's stop-previous gives up after 2 s, then its load clears the error.
        try #require(await eventually(within: 8) {
            route.count(.decision, .began) >= 2 && !controller.playbackError.isFailed
        }, "quality restart never loaded")
        controller.surfaceReconnectTimeout()   // the next failure
        try #require(controller.playbackError.isFailed)
        route.hold([])
        route.releaseHeld()                    // the first retry task resumes and exits
        try #require(await eventually {
            route.count(.stop, .answered) + route.count(.stop, .cancelled) == route.count(.stop, .began)
        }, "held stops never resolved")
        // Retry inside the poll: once a fixed retry task has unwound, one of these calls starts a
        // retry; on current code every call is a no-op because failureRetryTask stays set.
        let retried = await eventually(within: 3) {
            controller.retry()
            return !controller.playbackError.isFailed
        }
        withKnownIssue("TLA+ finding Restart-RetryWedgedByAttach (#526): a superseded retry task leaves failureRetryTask set, so Retry stops responding") {
            #expect(retried, "Retry after the second failure did not start a retry")
        }
    }

    /// RestartAfterFailureSkipsFinalStop (#527). `surfaceFailure` sends the transcode stop and
    /// sets `sentTranscodeStop`; only `retry()` clears it. A quality change from the error
    /// overlay starts a new transcode under the same session, and Close then sends no stop for
    /// it (`restart/Finding-RestartAfterFailureSkipsFinalStop.cfg`).
    @Test("#527: Close stops a transcode started by a quality change after a failure")
    func closeStopsATranscodeStartedByAQualityChangeAfterFailure() async throws {
        let route = PlexFixtureRoute(videoDecision: "transcode")
        let controller = makePlexController(route: route, maxVideoBitrateKbps: 4000)
        controller.start()
        try #require(await eventually { route.count(.decision, .began) == 1 })
        controller.surfaceReconnectTimeout()
        try #require(controller.playbackError.isFailed)
        try #require(await eventually { route.count(.stop, .began) == 1 }, "failure sent no stop")
        controller.reload(bitrateKbps: 2000)
        try #require(await eventually { route.count(.decision, .began) == 2 }, "quality restart never started")
        let replacementStarted = try #require(route.lastIndex(.decision, .began))
        controller.stop()
        await controller.waitForPendingStopRequests()
        withKnownIssue("TLA+ finding RestartAfterFailureSkipsFinalStop (#527): the stop latch set by the failure suppresses Close's stop for the replacement transcode") {
            #expect(route.events.value[replacementStarted...].contains { $0.kind == .stop && $0.phase == .began },
                    "Close sent no transcode stop for the transcode the quality change started")
        }
    }

    /// Restart-SeekDroppedByAttach (#528). A scrub while no item is loaded arms the 500 ms
    /// final-target rebuild and holds the scrubber; the start's `load()` bumps the generation
    /// before the timer fires, the timer returns at its generation guard, and the seek is
    /// dropped with the scrubber held (`restart/Finding-SeekDroppedByAttach.cfg`).
    @Test("#528: a seek made before the item loads is not dropped")
    func aSeekMadeBeforeTheItemLoadsIsNotDropped() async throws {
        let route = PlexFixtureRoute(videoDecision: "transcode")
        let controller = makePlexController(route: route, maxVideoBitrateKbps: 4000)
        defer { controller.stop() }
        controller.start()
        controller.performUserSeek(toMs: 600_000)   // before the first item exists
        try #require(controller.isSeeking)
        try #require(await eventually { route.count(.decision, .answered) == 1 })
        func rebuiltToTarget() -> Bool {
            route.events.value.contains { $0.kind == .decision && $0.phase == .began && $0.offset == "600" }
        }
        // Well past the 500 ms settle timer.
        let survived = await eventually(within: 3) { !controller.isSeeking || rebuiltToTarget() }
        withKnownIssue("TLA+ finding Restart-SeekDroppedByAttach (#528): the load supersedes the settle timer, which drops the seek and keeps the scrubber held") {
            #expect(survived, "the seek was neither carried into a rebuild nor released (isSeeking=\(controller.isSeeking))")
        }
    }

    /// Plex-LateStopPilesUp, pile-up half (#529). The restart's stop of the old transcode is
    /// unresolved after 2 s; `stopPreviousTranscode` gives up and the replacement goes out under
    /// the same session id beside the unstopped job (`plex/Finding-LateStopPilesUp.cfg`,
    /// `OneEncoder`). The conditional "late stop kills the replacement" half is not pinned.
    @Test("#529: the replacement does not start under the session while its own stop is unresolved")
    func replacementIsNotStartedUnderTheSessionWhileItsOwnStopIsUnresolved() async throws {
        let route = PlexFixtureRoute(videoDecision: "transcode")
        let controller = makePlexController(route: route, maxVideoBitrateKbps: 4000)
        defer { route.hold([]); route.releaseHeld(); controller.stop() }
        controller.start()
        try #require(await eventually { route.count(.decision, .began) == 1 })
        route.hold([.stop])
        controller.reload(bitrateKbps: 2000)
        try #require(await eventually { route.count(.stop, .began) == 1 }, "restart sent no stop-previous")
        let heldStopSession = try #require(route.events.value.last { $0.kind == .stop }?.session)
        let replacementSent = await eventually(within: 4) { route.count(.decision, .began) >= 2 }
        let stopResolved = route.count(.stop, .answered) > 0
        let replacementSession = route.events.value.last { $0.kind == .decision }?.session
        withKnownIssue("TLA+ finding Plex-LateStopPilesUp (#529): the replacement starts under the same session while its stop of the old job is unresolved") {
            #expect(!(replacementSent && !stopResolved && replacementSession == heldStopSession),
                    "replacement decision went out under the old session id before its stop resolved")
        }
    }

    /// FinalStopKillsReplacement (#530). `retry()` joins the pending stops before minting a
    /// replacement; a quality change from the error overlay goes through
    /// `restartAtCurrentPosition` and skips that join, so the replacement starts while the
    /// failure's stop (same session id) is still in flight and can end it
    /// (`plex/Finding-FinalStopKillsReplacement.cfg`, `StopNeverKillsSuccessor`).
    @Test("#530: a restart from the error overlay joins the failure's stop first")
    func restartFromTheErrorOverlayJoinsTheFailuresStopFirst() async throws {
        let route = PlexFixtureRoute(videoDecision: "transcode")
        let controller = makePlexController(route: route, maxVideoBitrateKbps: 4000)
        defer { route.hold([]); route.releaseHeld(); controller.stop() }
        controller.start()
        try #require(await eventually { route.count(.decision, .began) == 1 })
        route.hold([.stop])
        controller.surfaceReconnectTimeout()
        try #require(await eventually { route.count(.stop, .began) == 1 }, "failure sent no stop")
        route.hold([])   // only the failure's stop stays in flight
        controller.reload(bitrateKbps: 2000)
        let replacementSent = await eventually(within: 1.5) { route.count(.decision, .began) >= 2 }
        // The failure's stop is still held (nothing releases it in this window).
        withKnownIssue("TLA+ finding FinalStopKillsReplacement (#530): a restart from the error overlay skips Retry's pending-stop join") {
            #expect(!replacementSent, "the replacement started while the failure's stop was still in flight")
        }
    }

    /// Plex-RetryAfterTimedOutStop (#539, conditional on PMS applying a stop after the client
    /// stopped waiting). `retry()` joins `pendingStopTasks`, and the failure's detached stop
    /// used to end its entry when its URLSession request timed out, so Retry restarted under the
    /// same session id while that stop could still land and end the replacement
    /// (`plex/Faithful-RetryAfterTimedOutStop-off.cfg`, `LiveStopNeverKillsSuccessor`). The
    /// failure's stop is tracked up to `failedAttemptStopTimeout`; unanswered, each Retry tap
    /// re-sends it once (bounded by `failedAttemptRestopTimeout`) and restarts only once PMS
    /// answers; otherwise it fails with `priorSessionStopUnconfirmed`.
    /// Retry's restart moves control requests to the recovery client, which the route does not
    /// see, so a restart is observed as Retry clearing the failure.
    @Test("#539: Retry does not restart a Plex transcode whose failure stop timed out")
    func retryDoesNotRestartAPlexTranscodeWhoseFailureStopTimedOut() async throws {
        let route = PlexFixtureRoute(videoDecision: "transcode")
        let controller = makePlexController(route: route, maxVideoBitrateKbps: 4000)
        controller.failedAttemptStopTimeout = 0.5
        controller.failedAttemptRestopTimeout = 0.5
        defer { route.hold([]); route.releaseHeld(); controller.stop() }
        controller.start()
        try #require(await eventually { route.count(.decision, .began) == 1 })
        route.hold([.stop])                    // PMS answers no stop
        controller.surfaceReconnectTimeout()
        try #require(controller.playbackError.isFailed)
        try #require(await eventually { route.count(.stop, .began) == 1 }, "failure sent no stop")
        controller.retry()                     // joins the failure's stop, then re-sends it once
        try #require(await eventually(within: 3) {
            controller.playbackError.failure?.code == .priorSessionStopUnconfirmed
        }, "Retry did not surface the unconfirmed stop (\(String(describing: controller.playbackError.failure?.code)))")
        #expect(controller.playbackError.isFailed, "Retry restarted while the failure's stop was unconfirmed")
        #expect(route.count(.stop, .began) == 2, "the tap did not re-send the stop exactly once")
        // The next tap tries again: one more re-send, and still no restart.
        controller.retry()
        #expect(await eventually(within: 2) { route.count(.stop, .began) == 3 }, "the second tap did not re-send the stop")
        try? await Task.sleep(for: .milliseconds(800))
        #expect(controller.playbackError.isFailed && controller.playbackError.failure?.code == .priorSessionStopUnconfirmed)
        #expect(route.count(.stop, .began) == 3)
    }

    /// #539: a failure stop that never connected (a Wi-Fi blip: `serverUnreachable` at once)
    /// does not leave Retry dead. The tap re-sends the stop, PMS answers it, and Retry restarts.
    @Test("#539: Retry re-sends a Plex failure stop that never connected and restarts once it is answered")
    func retryResendsAPlexFailureStopThatNeverConnected() async throws {
        let route = PlexFixtureRoute(videoDecision: "transcode")
        let controller = makePlexController(route: route, maxVideoBitrateKbps: 4000)
        defer { route.fail([]); controller.stop() }
        controller.start()
        try #require(await eventually { route.count(.decision, .began) == 1 })
        route.fail([.stop])
        controller.surfaceReconnectTimeout()
        try #require(await eventually { route.count(.stop, .failed) == 1 }, "failure stop did not fail")
        route.fail([])                         // the network is back
        controller.retry()
        #expect(await eventually { !controller.playbackError.isFailed }, "Retry did not restart after the re-sent stop was answered")
        #expect(route.count(.stop, .answered) == 1, "the tap did not re-send the stop")
    }

    /// #539: a restart from the error overlay that fails before it builds an item (the network
    /// is still down) must not leave Retry refusing for good. Its task ends; the next tap re-sends
    /// the failure's stop and restarts once PMS answers.
    @Test("#539: Retry re-sends and restarts after an overlay reload failed before its item")
    func retryResendsAfterAnOverlayReloadFailedBeforeItsItem() async throws {
        let route = PlexFixtureRoute(videoDecision: "transcode")
        let controller = makePlexController(route: route, maxVideoBitrateKbps: 4000)
        defer { route.fail([]); controller.stop() }
        controller.start()
        try #require(await eventually { route.count(.decision, .began) == 1 })
        route.fail([.stop, .decision])         // the network drops
        controller.surfaceReconnectTimeout()
        try #require(await eventually { route.count(.stop, .failed) == 1 }, "failure stop did not fail")
        controller.reload(bitrateKbps: 2000)   // from the overlay; the error stays
        try #require(await eventually { route.count(.decision, .failed) == 1 }, "overlay reload never asked for a decision")
        try? await Task.sleep(for: .milliseconds(200))   // let the reload's task finish
        try #require(controller.playbackError.isFailed)
        route.fail([])                         // the network is back
        let stopsBefore = route.count(.stop, .began)
        controller.retry()
        #expect(await eventually { !controller.playbackError.isFailed },
                "Retry did not restart (\(String(describing: controller.playbackError.failure?.code)))")
        #expect(route.count(.stop, .began) == stopsBefore + 1, "the tap did not re-send the failure's stop")
    }

    /// The other side of #539: a failure stop PMS answers within the bound lets Retry restart
    /// without re-sending it.
    @Test("#539: Retry restarts a Plex transcode once the failure stop is answered")
    func retryRestartsAPlexTranscodeOnceTheFailureStopIsAnswered() async throws {
        let route = PlexFixtureRoute(videoDecision: "transcode")
        let controller = makePlexController(route: route, maxVideoBitrateKbps: 4000)
        defer { controller.stop() }
        controller.start()
        try #require(await eventually { route.count(.decision, .began) == 1 })
        controller.surfaceReconnectTimeout()
        try #require(await eventually { route.count(.stop, .answered) == 1 }, "failure stop never answered")
        controller.retry()
        #expect(await eventually { !controller.playbackError.isFailed }, "Retry did not restart")
        #expect(route.count(.stop, .began) == 1, "Retry re-sent a stop that was already answered")
    }

    // MARK: - Jellyfin

    /// Jellyfin-RetryAfterTimedOutStop (#539). The failed session's exact-session stop is not
    /// acknowledged (`onStopAcknowledged` returns false); `retry()` used to join the Void stop
    /// and negotiate a replacement beside the failed session's still-running encoder
    /// (`jellyfin/Faithful-RetryAfterTimedOutStop-off.cfg`, `OneEncoder`). Now each tap
    /// re-sends the stop once and negotiates only if it is acknowledged; otherwise it fails
    /// with `priorSessionStopUnconfirmed`, as Emby's reopen does, and the next tap tries again.
    @Test("#539: Retry does not negotiate a Jellyfin replacement while the failed session's stop is unconfirmed")
    func retryDoesNotNegotiateAJellyfinReplacementWhileTheFailedStopIsUnconfirmed() async throws {
        let log = EventLog()
        let streamURL = try #require(URL(string: "https://192.0.2.10/videos/fixture/master.m3u8"))
        let session = jellyfinSession(streamURL: streamURL, log: log) {
            log.append("stop-0")
            return log.items.contains("server-back")
        }
        let controller = makeMediaBrowserController(session: session, maxVideoBitrateKbps: 4000)
        defer { controller.stop() }
        controller.start()
        try #require(await eventually { controller.player.currentItem != nil }, "the initial stream never attached")
        controller.surfaceReconnectTimeout()
        try #require(controller.playbackError.isFailed)
        try #require(await eventually { log.count("stop-0") == 1 }, "failure did not stop the session")
        controller.retry()
        try #require(await eventually {
            controller.playbackError.failure?.code == .priorSessionStopUnconfirmed
        }, "Retry did not surface the unconfirmed stop (\(String(describing: controller.playbackError.failure?.code)))")
        #expect(log.count("stop-0") == 2, "the tap did not re-send the stop once: \(log.items)")
        #expect(!log.items.contains { $0.hasPrefix("negotiate-") }, "Retry negotiated while the stop was unconfirmed: \(log.items)")
        // The next tap re-sends again; acknowledged this time, so Retry negotiates.
        log.append("server-back")
        controller.retry()
        #expect(await eventually { log.items.contains { $0.hasPrefix("negotiate-") } }, "the next tap did not negotiate: \(log.items)")
        #expect(log.count("stop-0") == 3)
    }

    /// #539: a stop DELETE that fails at once (transport error) is re-sent by the tap, and an
    /// acknowledged re-send lets Retry negotiate in the same tap.
    @Test("#539: Retry re-sends a Jellyfin stop that failed at once and negotiates once it is acknowledged")
    func retryResendsAJellyfinStopThatFailedAtOnce() async throws {
        let log = EventLog()
        let streamURL = try #require(URL(string: "https://192.0.2.10/videos/fixture/master.m3u8"))
        let session = jellyfinSession(streamURL: streamURL, log: log) {
            log.append("stop-0")
            return log.count("stop-0") > 1      // only the re-send is acknowledged
        }
        let controller = makeMediaBrowserController(session: session, maxVideoBitrateKbps: 4000)
        defer { controller.stop() }
        controller.start()
        try #require(await eventually { controller.player.currentItem != nil }, "the initial stream never attached")
        controller.surfaceReconnectTimeout()
        try #require(await eventually { log.count("stop-0") == 1 }, "failure did not stop the session")
        controller.retry()
        #expect(await eventually { log.items.contains { $0.hasPrefix("negotiate-") } }, "Retry did not negotiate: \(log.items)")
        #expect(log.count("stop-0") == 2)
    }

    /// #539: Close while a Retry tap waits on its re-sent stop wins; the acknowledgement that
    /// arrives afterwards does not negotiate a replacement.
    @Test("#539: Close during Retry's re-sent stop wins")
    func closeDuringRetrysResentStopWins() async throws {
        let log = EventLog()
        let gate = TestGate()
        let streamURL = try #require(URL(string: "https://192.0.2.10/videos/fixture/master.m3u8"))
        let session = jellyfinSession(streamURL: streamURL, log: log) {
            log.append("stop-0")
            guard log.count("stop-0") > 1 else { return false }
            await gate.wait()                   // the re-send is slow, then acknowledged
            return true
        }
        let controller = makeMediaBrowserController(session: session, maxVideoBitrateKbps: 4000)
        controller.start()
        try #require(await eventually { controller.player.currentItem != nil }, "the initial stream never attached")
        controller.surfaceReconnectTimeout()
        try #require(await eventually { log.count("stop-0") == 1 })
        controller.retry()
        try #require(await eventually { log.count("stop-0") == 2 }, "the tap did not re-send the stop")
        controller.stop()
        await gate.open()
        await controller.waitForPendingStopRequests()
        let negotiated = await eventually(within: 1) { log.items.contains { $0.hasPrefix("negotiate-") } }
        #expect(!negotiated, "Retry negotiated after Close: \(log.items)")
    }

    /// The other side of #539: an acknowledged failure stop lets Retry negotiate as before.
    @Test("#539: Retry negotiates a Jellyfin replacement once the failed session's stop is acknowledged")
    func retryNegotiatesAJellyfinReplacementOnceTheFailedStopIsAcknowledged() async throws {
        let log = EventLog()
        let streamURL = try #require(URL(string: "https://192.0.2.10/videos/fixture/master.m3u8"))
        let session = jellyfinSession(streamURL: streamURL, log: log) {
            log.append("stop-0")
            return true
        }
        let controller = makeMediaBrowserController(session: session, maxVideoBitrateKbps: 4000)
        defer { controller.stop() }
        controller.start()
        try #require(await eventually { controller.player.currentItem != nil }, "the initial stream never attached")
        controller.surfaceReconnectTimeout()
        try #require(await eventually { log.count("stop-0") == 1 }, "failure did not stop the session")
        controller.retry()
        #expect(await eventually { log.items.contains { $0.hasPrefix("negotiate-") } }, "Retry did not negotiate: \(log.items)")
        #expect(log.count("stop-0") == 1, "Retry re-sent an acknowledged stop")
    }

    /// A Jellyfin session wired as DetailPlaybackLauncher wires it: both stop callbacks send the
    /// same DELETE, and `acknowledged` decides what `onStopAcknowledged` reports.
    private func jellyfinSession(streamURL: URL, log: EventLog,
                                 acknowledged: @escaping @MainActor () async -> Bool) -> MediaBrowserPlaybackSession {
        MediaBrowserPlaybackSession(
            streamURL: streamURL, backend: .jellyfin, backendLabel: "Jellyfin", httpHeaders: [:],
            playSessionID: "session-0", sourceMetadata: .init(videoCodec: "hevc"),
            playMethod: .transcode, transcodeReasons: [], progressSession: nil,
            onStop: { log.append("legacy-stop-0") },
            reopener: { request in
                log.append("negotiate-\(request.bitrateKbps)")
                return RemoteStreamOpenResult(url: streamURL, headers: [:], playSessionId: "session-1",
                                              onStop: {}, onStopAcknowledged: { true })
            },
            onStopAndWait: { _ = await acknowledged() },
            onStopAcknowledged: { await acknowledged() })
    }

    /// Jellyfin-ConsentClobbersDidStop (#531). The consent request awaits the old session's
    /// stop; a quality change reopens and attaches a new session on the same shared session
    /// object; the consent continuation then sets `didStop = true` before its generation guard,
    /// and Close skips the new session's stop
    /// (`jellyfin/Finding-ConsentClobbersDidStop.cfg`, `NoOrphans`).
    @Test("#531: Close stops the session attached while consent awaited the old stop")
    func closeStopsTheSessionAttachedWhileConsentAwaitedTheOldStop() async throws {
        let log = EventLog()
        let gate = TestGate()
        let streamURL = try #require(URL(string: "https://192.0.2.10/videos/fixture/master.m3u8"))
        let session = MediaBrowserPlaybackSession(
            streamURL: streamURL, backend: .jellyfin, backendLabel: "Jellyfin", httpHeaders: [:],
            playSessionID: "session-0", sourceMetadata: .init(videoCodec: "unsupported"),
            playMethod: .transcode, transcodeReasons: ["VideoCodecNotSupported"],
            progressSession: nil, onStop: { log.append("legacy-stop-0") },
            reopener: { request in
                log.append("negotiate-\(request.bitrateKbps)")
                return RemoteStreamOpenResult(url: streamURL, headers: [:], playSessionId: "session-1",
                                              onStop: { log.append("legacy-stop-1") },
                                              onStopAndWait: { log.append("stop-1") })
            },
            onStopAndWait: {
                log.append("stop-0-begin")
                await gate.wait()
                log.append("stop-0-end")
            })
        let controller = makeMediaBrowserController(session: session, maxVideoBitrateKbps: 0)
        controller.start()
        try #require(await eventually { log.items.contains("stop-0-begin") }, "consent never stopped the old session")
        controller.reload(bitrateKbps: 4000)
        try #require(await eventually { session.playSessionID == "session-1" && !session.didStop },
                     "the reopened session never attached")
        await gate.open()
        try #require(await eventually { log.items.contains("stop-0-end") })
        // The consent continuation resumes on the main actor; today it marks the session
        // stopped. Bounded so a fixed controller (which never writes it) is not held long.
        _ = await eventually(within: 1) { session.didStop }
        controller.stop()
        await controller.waitForPendingStopRequests()
        withKnownIssue("TLA+ finding Jellyfin-ConsentClobbersDidStop (#531): the consent request marks the newer session stopped, so Close never stops it") {
            #expect(log.items.contains("stop-1"), "Close did not stop the attached session: \(log.items)")
        }
    }

    /// Jellyfin-ThirdEncoder (#532). Jellyfin replaces first and defers the prior session's
    /// stop by 2 s; two reopens that both attach within 2 s leave three encoders live
    /// (`jellyfin/Finding-ThirdEncoder-Attached.cfg`, `OneEncoderWhilePlaying`).
    @Test("#532: two quick reopens leave at most one extra encoder")
    func twoQuickReopensLeaveAtMostOneExtraEncoder() async throws {
        let log = EventLog()
        var live: Set<String> = ["session-0"]
        var opened = 0
        let streamURL = try #require(URL(string: "https://192.0.2.10/videos/fixture/master.m3u8"))
        let session = MediaBrowserPlaybackSession(
            streamURL: streamURL, backend: .jellyfin, backendLabel: "Jellyfin", httpHeaders: [:],
            playSessionID: "session-0", sourceMetadata: .init(videoCodec: "hevc"),
            playMethod: .transcode, transcodeReasons: [], progressSession: nil,
            onStop: { live.remove("session-0") },
            reopener: { request in
                opened += 1
                let id = "session-\(opened)"
                live.insert(id)
                log.append("negotiate-\(request.bitrateKbps)")
                return RemoteStreamOpenResult(url: streamURL, headers: [:], playSessionId: id,
                                              onStop: { live.remove(id) })
            })
        let controller = makeMediaBrowserController(session: session, maxVideoBitrateKbps: 4000)
        defer { controller.stop() }
        controller.start()
        try #require(await eventually { controller.player.currentItem != nil }, "the initial stream never attached")
        let firstReload = ContinuousClock.now
        controller.reload(bitrateKbps: 3000)
        try #require(await eventually { session.playSessionID == "session-1" }, "first replacement never attached")
        controller.reload(bitrateKbps: 2000)
        try #require(await eventually { session.playSessionID == "session-2" }, "second replacement never attached")
        // Both attached inside the 2 s deferred-stop delay, so the model's ordering was reached.
        try #require(firstReload.duration(to: .now) < .milliseconds(1_500))
        withKnownIssue("TLA+ finding Jellyfin-ThirdEncoder (#532): two quick reopens leave three encoders running") {
            #expect(live.count <= 2, "live encoders after two quick reopens: \(live.sorted())")
        }
    }

    /// Consent overlay left undismissable by a reopen (#535). `reload` and `beginStreaming`
    /// clear `videoTranscodeConsent.generation`, `reopenRemoteStream` does not. A reopen while
    /// the "Allow video transcoding?" choice shows bumps the generation and leaves the overlay
    /// up with both buttons inert. Driven here by a scrub, which reaches `reopenRemoteStream`
    /// through the final-target rebuild just as a track change does.
    @Test("#535: a reopen while the consent choice shows leaves it dismissable")
    func aReopenWhileTheConsentChoiceShowsLeavesItDismissable() async throws {
        let log = EventLog()
        let gate = TestGate()
        let streamURL = try #require(URL(string: "https://192.0.2.10/videos/fixture/master.m3u8"))
        let session = MediaBrowserPlaybackSession(
            streamURL: streamURL, backend: .jellyfin, backendLabel: "Jellyfin", httpHeaders: [:],
            playSessionID: "session-0", sourceMetadata: .init(videoCodec: "unsupported"),
            playMethod: .transcode, transcodeReasons: ["VideoCodecNotSupported"],
            progressSession: nil, onStop: {},
            reopener: { request in
                log.append("negotiate-\(request.bitrateKbps)")
                await gate.wait()
                throw CancellationError()
            },
            onStopAndWait: { log.append("stop-0") })
        let controller = makeMediaBrowserController(session: session, maxVideoBitrateKbps: 0)
        controller.start()
        try #require(await eventually { controller.videoTranscodeConsent.isPending })
        controller.performUserSeek(toMs: 600_000)
        try #require(await eventually(within: 3) { log.items.contains { $0.hasPrefix("negotiate-") } },
                     "the scrub never reopened the stream")
        if let generation = controller.videoTranscodeConsent.generation {
            controller.approveVideoTranscoding(generation: generation)
        }
        let dismissable = !controller.videoTranscodeConsent.isPending
        controller.stop()
        await gate.open()
        withKnownIssue("TLA+ finding (#535): a reopen while the consent choice shows leaves a choice neither button can dismiss") {
            #expect(dismissable, "the consent overlay stayed up and its button was inert after the reopen")
        }
    }

    // MARK: - Fixtures

    private func makePlexController(route: PlexFixtureRoute, maxVideoBitrateKbps: Int) -> PlaybackController {
        let identity = ClientIdentity(clientIdentifier: "formal-model-fixture", product: "Labstream",
                                      version: "1", deviceName: "Test")
        return PlaybackController(
            item: MediaItem(ratingKey: "fixture", title: "Fixture", type: "movie", viewOffset: 120_000),
            sessionSource: .plex(PlexPlaybackSession(server: URL(string: "https://192.0.2.10:32400")!,
                                                     token: "fixture-token")),
            identity: identity, client: PlexClient(session: route.session, identity: identity),
            maxVideoBitrateKbps: maxVideoBitrateKbps)
    }

    private func makeMediaBrowserController(session: MediaBrowserPlaybackSession,
                                            maxVideoBitrateKbps: Int) -> PlaybackController {
        let identity = ClientIdentity(clientIdentifier: "formal-model-fixture", product: "Labstream",
                                      version: "1", deviceName: "Test")
        return PlaybackController(
            item: MediaItem(ratingKey: "fixture", title: "Fixture", type: "movie", viewOffset: 120_000),
            sessionSource: .mediaBrowser(session), identity: identity,
            client: PlexClient(identity: identity), maxVideoBitrateKbps: maxVideoBitrateKbps)
    }

    /// Poll on the main actor; the bound only limits a broken test.
    private func eventually(within seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// The text of an app source file. Nil when it is missing.
    private static func appSource(_ relativePath: String) -> String? {
        // LabstreamTests/<this file> -> repository root.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The text of one function in an app source file, from its declaration to the next
    /// declaration at the same indentation. Nil when the file or the function is missing.
    private static func appFunctionSource(named name: String, in relativePath: String) -> String? {
        guard let source = appSource(relativePath),
              let start = source.range(of: "    private func \(name)(") else { return nil }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private func ")?.lowerBound ?? rest.endIndex
        return String(source[start.lowerBound..<end])
    }
}

@MainActor
private final class EventLog {
    private(set) var items: [String] = []
    func append(_ item: String) { items.append(item) }
    func count(_ item: String) -> Int { items.filter { $0 == item }.count }
}

/// Records every Plex control-plane request a controller sends and can hold the responses of
/// chosen kinds until released, so a test can put a start or stop "on the wire".
private final class PlexFixtureRoute: @unchecked Sendable {
    enum Kind: Hashable, Sendable { case decision, start, stop, other }
    enum Phase: Sendable { case began, answered, cancelled, failed }
    struct Event: Sendable {
        let kind: Kind
        let phase: Phase
        let session: String?
        let offset: String?
    }

    let events = TestLockedBox<[Event]>([])
    let session: URLSession
    private let identifier = UUID().uuidString
    private let videoDecision: String
    private let holding = TestLockedBox<Set<Kind>>([])
    private let failing = TestLockedBox<Set<Kind>>([])
    private let held = TestLockedBox<[@Sendable () -> Void]>([])

    init(videoDecision: String) {
        self.videoDecision = videoDecision
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FormalModelURLProtocol.self]
        configuration.httpAdditionalHeaders = [FormalModelURLProtocol.routeHeader: identifier]
        session = URLSession(configuration: configuration)
        FormalModelURLProtocol.routes.withValue { $0[identifier] = self }
    }

    deinit {
        let identifier = identifier
        FormalModelURLProtocol.routes.withValue { $0.removeValue(forKey: identifier) }
    }

    func hold(_ kinds: Set<Kind>) { holding.withValue { $0 = kinds } }
    /// Requests of these kinds fail at once with a transport error, as with no network.
    func fail(_ kinds: Set<Kind>) { failing.withValue { $0 = kinds } }
    func failsNow(_ request: URLRequest) -> Bool { failing.value.contains(Self.kind(of: request)) }

    func releaseHeld() {
        let pending = held.withValue { list -> [@Sendable () -> Void] in
            defer { list.removeAll() }
            return list
        }
        pending.forEach { $0() }
    }

    func count(_ kind: Kind, _ phase: Phase) -> Int {
        events.value.filter { $0.kind == kind && $0.phase == phase }.count
    }

    func firstIndex(_ kind: Kind, _ phase: Phase) -> Int? {
        events.value.firstIndex { $0.kind == kind && $0.phase == phase }
    }

    func lastIndex(_ kind: Kind, _ phase: Phase) -> Int? {
        events.value.lastIndex { $0.kind == kind && $0.phase == phase }
    }

    static func kind(of request: URLRequest) -> Kind {
        let path = request.url?.path ?? ""
        if path.hasSuffix("/decision") { return .decision }
        if path.hasSuffix("start.m3u8") { return .start }
        if path.hasSuffix("/transcode/universal/stop") { return .stop }
        return .other
    }

    func record(_ request: URLRequest, _ phase: Phase) {
        let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems
        events.withValue {
            $0.append(Event(kind: Self.kind(of: request), phase: phase,
                            session: query?.first { $0.name == "session" }?.value,
                            offset: query?.first { $0.name == "offset" }?.value))
        }
    }

    func response(for request: URLRequest) -> (HTTPURLResponse, Data) {
        let body: String = switch Self.kind(of: request) {
        case .decision:
            #"{"MediaContainer":{"generalDecisionCode":1001,"Metadata":[{"Media":[{"Part":[{"Stream":[{"streamType":1,"decision":"\#(videoDecision)"}]}]}]}]}}"#
        case .start: "#EXTM3U\n"
        case .stop, .other: "{}"
        }
        return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                headerFields: nil)!, Data(body.utf8))
    }

    /// Answer now, or park `deliver` until `releaseHeld()`.
    func receive(_ request: URLRequest, deliver: @escaping @Sendable () -> Void) {
        record(request, .began)
        if holding.value.contains(Self.kind(of: request)) {
            held.withValue { $0.append(deliver) }
        } else {
            deliver()
        }
    }
}

/// Session-scoped protocol for `PlexFixtureRoute`. Held responses are delivered later on the
/// loading thread's run loop, as URLProtocol requires.
private final class FormalModelURLProtocol: URLProtocol, @unchecked Sendable {
    static let routeHeader = "X-Labstream-Formal-Model-Route"
    static let routes = TestLockedBox<[String: PlexFixtureRoute]>([:])
    private let finished = TestLockedBox(false)
    private var route: PlexFixtureRoute?

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: routeHeader) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let identifier = request.value(forHTTPHeaderField: Self.routeHeader),
              let route = Self.routes.value[identifier] else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        self.route = route
        var routed = request
        routed.setValue(nil, forHTTPHeaderField: Self.routeHeader)
        let request = routed
        if route.failsNow(request) {
            route.record(request, .began)
            route.record(request, .failed)
            _ = finished.withValue { done in defer { done = true }; return done }
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let loading = LoadingContext(runLoop: CFRunLoopGetCurrent(), thread: Thread.current)
        route.receive(request) { [weak self] in
            let deliver = { [weak self] in
                guard let self, !self.finished.withValue({ done in defer { done = true }; return done }) else { return }
                route.record(request, .answered)
                let (response, data) = route.response(for: request)
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            }
            if Thread.current == loading.thread {
                deliver()
            } else {
                CFRunLoopPerformBlock(loading.runLoop, CFRunLoopMode.commonModes.rawValue, deliver)
                CFRunLoopWakeUp(loading.runLoop)
            }
        }
    }

    /// The loading thread and its run loop, which URLProtocol client callbacks must use.
    private struct LoadingContext: @unchecked Sendable {
        let runLoop: CFRunLoop
        let thread: Thread
    }

    override func stopLoading() {
        let wasFinished = finished.withValue { done in defer { done = true }; return done }
        if !wasFinished {
            var routed = request
            routed.setValue(nil, forHTTPHeaderField: Self.routeHeader)
            route?.record(routed, .cancelled)
        }
    }
}
