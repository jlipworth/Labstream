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
/// #529's conditional half and #536 are server behaviours and are not pinned here.
/// The proxy findings (#533, #534) are pinned in PMSKit's `PlaybackFormalModelFindingsTests`.
@Suite(.serialized)
@MainActor
struct PlaybackFormalModelFindingsTests {

    // MARK: - Restart / proxy

    /// Restart-ProxyAfterCleanup (#524). A stand-up awaits `oldProxy.stop(...)` and then writes
    /// `remoteHLSProxy = proxy` with no generation check; Close or `surfaceFailure` in that
    /// window clears the slot, and the resumed task installs a proxy nothing will stop
    /// (`restart/Finding-ProxyAfterCleanup.cfg`, `ProxyOwnership`). Source-text pin: every
    /// such stand-up must re-check the generation between the await and the install.
    @Test func proxyStandUpRechecksGenerationAfterAwaitingOldProxyStop() throws {
        let source = try #require(Self.appSource("Labstream/Shared/Player/PlaybackController.swift"))
        let oldProxyStop = "await oldProxy.stop(generation: oldGeneration)"
        var searchStart = source.startIndex
        var windows: [Substring] = []
        while let stop = source.range(of: oldProxyStop, range: searchStart..<source.endIndex) {
            let install = try #require(source.range(of: "remoteHLSProxy = proxy",
                                                    range: stop.upperBound..<source.endIndex))
            windows.append(source[stop.upperBound..<install.lowerBound])
            searchStart = install.upperBound
        }
        try #require(windows.count >= 2, "expected the Plex DV and MediaBrowser proxy stand-ups")
        withKnownIssue("TLA+ finding Restart-ProxyAfterCleanup (#524): a stand-up installs its proxy after cleanup without re-checking the generation") {
            for window in windows {
                #expect(window.contains("playbackGeneration") || window.contains("isCurrentPlaybackLifecycle"),
                        "no generation re-check between awaiting the old proxy's stop and installing the new one")
            }
        }
    }

    // MARK: - Plex

    /// StopNoJoin / Plex-LateStartOutlivesStop (#525). A copy-lane start is on the wire when
    /// the user closes. `stop()` cancels the task without joining it and sends the transcode
    /// stop; the start then lands and nothing stops the transcoder it started
    /// (`plex/Finding-LateStartOutlivesStop.cfg`, `restart/Finding-StopNoJoin-LateStart.cfg`).
    @Test func closeStopsATranscodeWhoseStartLandsAfterTheStop() async throws {
        let route = PlexFixtureRoute(videoDecision: "copy")
        route.hold([.start])
        let controller = makePlexController(route: route, maxVideoBitrateKbps: 0)
        controller.start()
        try #require(await eventually { route.count(.start, .began) == 1 }, "copy-lane start never sent")
        controller.stop()
        try #require(await eventually { route.count(.stop, .began) == 1 }, "Close sent no transcode stop")
        // The start reaches the server now, after the stop. Cancelling the task cancels the
        // client's URLSession task, but cannot retract a request already on the wire; the
        // model's start is not retracted either. A fix must order the final stop after the
        // start resolves (for example, by not cancelling it and joining the task in Close).
        let startLanded = route.events.value.count
        route.releaseHeld()
        await controller.waitForPendingStopRequests()
        try await Task.sleep(for: .milliseconds(300))
        withKnownIssue("TLA+ finding StopNoJoin (#525): Close does not join the cancelled start, so a start that lands after the stop is never stopped") {
            #expect(route.events.value[startLanded...].contains { $0.kind == .stop && $0.phase == .began },
                    "no transcode stop was sent after the late start landed: \(route.events.value.map { "\($0.kind)-\($0.phase)" })")
        }
    }

    /// Restart-RetryWedgedByAttach (#526). From the error overlay the user changes quality and
    /// taps Retry; the retry task waits on the failure's pending stop while the quality
    /// restart's `load()` supersedes its generation, and it returns without clearing
    /// `failureRetryTask`. On the next failure Retry does nothing
    /// (`restart/Finding-RetryWedgedByAttach.cfg`, `RetryRuns`).
    @Test func retryStillRunsAfterAQualityChangeSupersededAnEarlierRetry() async throws {
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
        try await Task.sleep(for: .milliseconds(300))
        controller.retry()
        let retried = await eventually(within: 3) { !controller.playbackError.isFailed }
        withKnownIssue("TLA+ finding Restart-RetryWedgedByAttach (#526): a superseded retry task leaves failureRetryTask set, so Retry stops responding") {
            #expect(retried, "Retry after the second failure did not start a retry")
        }
    }

    /// RestartAfterFailureSkipsFinalStop (#527). `surfaceFailure` sends the transcode stop and
    /// sets `sentTranscodeStop`; only `retry()` clears it. A quality change from the error
    /// overlay starts a new transcode under the same session, and Close then sends no stop for
    /// it (`restart/Finding-RestartAfterFailureSkipsFinalStop.cfg`).
    @Test func closeStopsATranscodeStartedByAQualityChangeAfterFailure() async throws {
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
    @Test func aSeekMadeBeforeTheItemLoadsIsNotDropped() async throws {
        let route = PlexFixtureRoute(videoDecision: "transcode")
        let controller = makePlexController(route: route, maxVideoBitrateKbps: 4000)
        defer { controller.stop() }
        controller.start()
        controller.performUserSeek(toMs: 600_000)   // before the first item exists
        try #require(controller.isSeeking)
        try #require(await eventually { route.count(.decision, .answered) == 1 })
        try await Task.sleep(for: .milliseconds(1_200))   // past the 500 ms settle timer
        let rebuiltToTarget = route.events.value.contains {
            $0.kind == .decision && $0.phase == .began && $0.offset == "600"
        }
        withKnownIssue("TLA+ finding Restart-SeekDroppedByAttach (#528): the load supersedes the settle timer, which drops the seek and keeps the scrubber held") {
            #expect(!controller.isSeeking || rebuiltToTarget,
                    "the seek was neither carried into a rebuild nor released")
        }
    }

    /// Plex-LateStopPilesUp, pile-up half (#529). The restart's stop of the old transcode is
    /// unresolved after 2 s; `stopPreviousTranscode` gives up and the replacement goes out under
    /// the same session id beside the unstopped job (`plex/Finding-LateStopPilesUp.cfg`,
    /// `OneEncoder`). The conditional "late stop kills the replacement" half is not pinned.
    @Test func replacementIsNotStartedUnderTheSessionWhileItsOwnStopIsUnresolved() async throws {
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
    @Test func restartFromTheErrorOverlayJoinsTheFailuresStopFirst() async throws {
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

    // MARK: - Jellyfin

    /// Jellyfin-ConsentClobbersDidStop (#531). The consent request awaits the old session's
    /// stop; a quality change reopens and attaches a new session on the same shared session
    /// object; the consent continuation then sets `didStop = true` before its generation guard,
    /// and Close skips the new session's stop
    /// (`jellyfin/Finding-ConsentClobbersDidStop.cfg`, `NoOrphans`).
    @Test func closeStopsTheSessionAttachedWhileConsentAwaitedTheOldStop() async throws {
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
        try #require(await eventually { log.items.contains("negotiate-4000") }, "quality change never reopened")
        try await Task.sleep(for: .milliseconds(200))   // the reopened session attaches
        await gate.open()
        try #require(await eventually { log.items.contains("stop-0-end") })
        try await Task.sleep(for: .milliseconds(100))   // the consent continuation resumes
        controller.stop()
        await controller.waitForPendingStopRequests()
        withKnownIssue("TLA+ finding Jellyfin-ConsentClobbersDidStop (#531): the consent request marks the newer session stopped, so Close never stops it") {
            #expect(log.items.contains("stop-1"), "Close did not stop the attached session: \(log.items)")
        }
    }

    /// Jellyfin-ThirdEncoder (#532). Jellyfin replaces first and defers the prior session's
    /// stop by 2 s; two reopens that both attach within 2 s leave three encoders live
    /// (`jellyfin/Finding-ThirdEncoder-Attached.cfg`, `OneEncoderWhilePlaying`).
    @Test func twoQuickReopensLeaveAtMostOneExtraEncoder() async throws {
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
        controller.reload(bitrateKbps: 3000)
        try #require(await eventually { log.items.contains("negotiate-3000") })
        try await Task.sleep(for: .milliseconds(200))   // first replacement attaches
        controller.reload(bitrateKbps: 2000)
        try #require(await eventually { log.items.contains("negotiate-2000") })
        try await Task.sleep(for: .milliseconds(200))   // second replacement attaches, well inside 2 s
        withKnownIssue("TLA+ finding Jellyfin-ThirdEncoder (#532): two quick reopens leave three encoders running") {
            #expect(live.count <= 2, "live encoders after two quick reopens: \(live.sorted())")
        }
    }

    /// Consent overlay left undismissable by a reopen (#535). `reload` and `beginStreaming`
    /// clear `videoTranscodeConsent.generation`, `reopenRemoteStream` does not. A reopen while
    /// the "Allow video transcoding?" choice shows bumps the generation and leaves the overlay
    /// up with both buttons inert. Driven here by a scrub, which reaches `reopenRemoteStream`
    /// through the final-target rebuild just as a track change does.
    @Test func aReopenWhileTheConsentChoiceShowsLeavesItDismissable() async throws {
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
}

@MainActor
private final class EventLog {
    private(set) var items: [String] = []
    func append(_ item: String) { items.append(item) }
}

/// Records every Plex control-plane request a controller sends and can hold the responses of
/// chosen kinds until released, so a test can put a start or stop "on the wire".
private final class PlexFixtureRoute: @unchecked Sendable {
    enum Kind: Hashable, Sendable { case decision, start, stop, other }
    enum Phase: Sendable { case began, answered, cancelled }
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
