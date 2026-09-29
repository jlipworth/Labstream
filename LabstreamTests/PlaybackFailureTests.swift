import AVFoundation
import Foundation
import PMSKit
import Testing
@testable import Labstream

@MainActor
struct PlaybackFailureTests {
    @Test func suppliedBackendErrorsHaveStableSafeCodes() throws {
        for error in [PlexError.http(500) as Error, MediaBrowserRequestError.httpStatus(500),
                      JellyfinBrowseService.ServiceError.http(500), EmbyBrowseService.ServiceError.http(500)] {
            let failure = PlaybackFailure.classify(error)
            #expect(failure.code == .serverHTTP)
            #expect(failure.httpStatus == 500)
            #expect(failure.message.contains("LS-PB-002"))
        }
        #expect(PlaybackFailure.classify(PlexError.unauthorized).httpStatus == 401)
        #expect(PlaybackFailure.classify(JellyfinBrowseService.ServiceError.notAuthenticated).httpStatus == nil)
        #expect(PlaybackFailure.classify(JellyfinBrowseService.ServiceError.notAuthenticated).code == .authenticationRequired)
        #expect(PlaybackFailure.classify(URLError(.cannotConnectToHost)).code == .connectionUnavailable)
        let response = try JSONDecoder().decode(DecisionResponse.self, from: Data(
            #"{"MediaContainer":{"generalDecisionCode":2000,"generalDecisionText":"private server implementation detail"}}"#.utf8))
        guard case .unsupported(let code) = response.decision else {
            Issue.record("Explicit unsupported decision was not preserved")
            return
        }
        #expect(code == 2000)
        let decision = PlaybackFailure(code: .backendUnsupported, backendDecision: code)
        #expect(!decision.message.contains("private server implementation detail"))
        #expect(PlaybackFailure.classify(decision) == decision)
        #expect(decision.message.contains("LS-PB-001"))
    }

    @Test func actualAVPlayerShapesDistinguishHTTPFromTimeoutAndUnknown() {
        let privateError = NSError(domain: NSURLErrorDomain, code: -1100, userInfo: [
            NSLocalizedDescriptionKey: "private title https://secret.invalid/token", NSURLErrorFailingURLStringErrorKey: "https://secret.invalid/token"])
        let http = PlaybackFailure.classify(privateError, signals: [
            .init(domain: "CoreMediaErrorDomain", code: -12889),
            .init(domain: "CoreMediaErrorDomain", code: -12938)])
        #expect(http.code == .serverHTTP)
        #expect(http.httpStatus == 404)
        #expect(!http.message.contains("secret"))
        #expect(!http.message.contains("private title"))
        let wrapped = NSError(domain: "AVFoundationErrorDomain", code: -11800,
                              userInfo: [NSUnderlyingErrorKey: URLError(.timedOut)])
        #expect(PlaybackFailure.classify(wrapped).code == .mediaDeliveryTimeout)
        #expect(PlaybackFailure.classify(nil, signals: [.init(domain: "CoreMediaErrorDomain", code: -12889)]).code == .mediaDeliveryTimeout)
        #expect(PlaybackFailure.classify(nil).code == .unknown)
        // A local missing file is not proof of an HTTP 404.
        #expect(PlaybackFailure.classify(privateError).code == .unknown)
        #expect(PlaybackFailure.classify(NSError(domain: "Labstream.Playback", code: -196)).code == .safetyBlocked)
        #expect(PlaybackFailure.classify(NSError(domain: "Labstream.Playback", code: -290)).code == .consentRequired)
    }

    @Test func mediaDeliveryRetryBudgetIsBoundedWithoutInventingServerDetail() {
        let timeout = PlaybackFailure.Signal(domain: "CoreMediaErrorDomain", code: -12889)
        #expect(PlaybackFailure.deliveryFailure(signals: Array(repeating: timeout, count: 3)) == nil)
        #expect(PlaybackFailure.deliveryFailure(signals: Array(repeating: timeout, count: 4)) == nil)
        let start = Date(timeIntervalSince1970: 1_000)
        let transient = [0.0, 3.0, 3.001, 7.0, 7.001].map {
            PlaybackFailure.Signal(domain: "CoreMediaErrorDomain", code: -12889, date: start.addingTimeInterval($0))
        }
        #expect(PlaybackFailure.deliveryFailure(signals: transient) == nil)
        let sustained = [0.0, 7.0, 14.0, 21.0].map {
            PlaybackFailure.Signal(domain: "CoreMediaErrorDomain", code: -12889, date: start.addingTimeInterval($0))
        }
        #expect(PlaybackFailure.deliveryFailure(signals: sustained)?.code == .mediaDeliveryTimeout)
        #expect(PlaybackFailure.deliveryFailure(signals: [.init(domain: "CoreMediaErrorDomain", code: -16847)])?.httpStatus == 500)
        #expect(PlaybackFailure.deliveryFailure(signals: [.init(domain: "CoreMediaErrorDomain", code: -12938)])?.httpStatus == 404)
        #expect(PlaybackFailure.deliveryFailure(signals: Array(repeating: .init(domain: "unknown", code: -1), count: 20)) == nil)
    }

    @Test func surfacedFailureDetachesStopsOnceAndRetryWaitsForCleanup() async throws {
        var release: CheckedContinuation<Void, Never>?
        var stops = 0
        var requests: [RemoteStreamReopenRequest] = []
        let identity = ClientIdentity(clientIdentifier: "fixture-only", product: "Labstream", version: "1", deviceName: "Fixture")
        let session = MediaBrowserPlaybackSession(
            streamURL: URL(fileURLWithPath: "/fixture.invalid"), backend: .jellyfin,
            backendLabel: "Jellyfin", httpHeaders: [:], playSessionID: "fixture-session",
            sourceMetadata: .init(videoCodec: "h264"), playMethod: .transcode,
            transcodeReasons: [], progressSession: nil, onStop: {},
            reopener: { request in requests.append(request); throw MediaBrowserRequestError.httpStatus(503) },
            onStopAndWait: { stops += 1; await withCheckedContinuation { release = $0 } })
        let controller = PlaybackController(
            item: MediaItem(ratingKey: "fixture", title: "Fixture", type: "movie", viewOffset: 600_000),
            sessionSource: .mediaBrowser(session), identity: identity,
            client: PlexClient(identity: identity), maxVideoBitrateKbps: 8_000)
        defer { controller.stop(); release?.resume() }
        controller.player.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: "/fixture.invalid")))
        controller.requestPause()
        controller.surfaceFailure(URLError(.timedOut))
        #expect(controller.player.currentItem == nil)
        #expect(controller.playbackError.failure?.code == .mediaDeliveryTimeout)
        controller.surfaceFailure(MediaBrowserRequestError.httpStatus(500))
        #expect(controller.playbackError.failure?.code == .mediaDeliveryTimeout)
        try await waitUntil { release != nil }
        controller.retry()
        controller.retry()
        for _ in 0..<10 { await Task.yield() }
        #expect(requests.isEmpty)
        #expect(stops == 1)
        release?.resume(); release = nil
        try await waitUntil { requests.count == 1 && controller.playbackError.failure?.httpStatus == 503 }
        #expect(requests[0].offsetMs == 600_000)
        #expect(requests[0].bitrateKbps == 8_000)
        #expect(requests[0].videoTranscodeApproved == false)
        controller.resumeAfterCompletedSeek(finished: true, currentItem: true)
        #expect(controller.player.rate == 0) // User pause intent survives failure and Retry.
        #expect(controller.player.currentItem == nil)
        #expect(stops == 1)
        for _ in 0..<10 { await Task.yield() }
        #expect(requests.count == 1) // No automatic failure→Retry loop.
    }

    @Test func failedReopenRetainsApprovedConsentAcrossExplicitRetry() async throws {
        var requests: [RemoteStreamReopenRequest] = []
        let identity = ClientIdentity(clientIdentifier: "fixture-only", product: "Labstream", version: "1", deviceName: "Fixture")
        let session = MediaBrowserPlaybackSession(
            streamURL: URL(fileURLWithPath: "/fixture.invalid"), backend: .jellyfin,
            backendLabel: "Jellyfin", httpHeaders: [:], playSessionID: "fixture-session",
            sourceMetadata: .init(videoCodec: "unsupported"), playMethod: .transcode,
            transcodeReasons: ["VideoCodecNotSupported"], progressSession: nil, onStop: {},
            reopener: { request in requests.append(request); throw MediaBrowserRequestError.httpStatus(503) },
            onStopAndWait: {})
        let controller = PlaybackController(
            item: MediaItem(ratingKey: "fixture", title: "Fixture", type: "movie", viewOffset: 120_000),
            sessionSource: .mediaBrowser(session), identity: identity,
            client: PlexClient(identity: identity), maxVideoBitrateKbps: 0)
        defer { controller.stop() }
        controller.start()
        try await waitUntil { controller.videoTranscodeConsent.isPending }
        controller.approveVideoTranscoding(generation: try #require(controller.videoTranscodeConsent.generation))
        try await waitUntil { controller.playbackError.isFailed }
        controller.retry()
        try await waitUntil { requests.count == 2 && controller.playbackError.isFailed }
        #expect(requests.allSatisfy { $0.videoTranscodeApproved && $0.offsetMs == 120_000 && $0.bitrateKbps == 0 })
        #expect(!controller.videoTranscodeConsent.isPending)
        #expect(controller.playbackError.failure?.httpStatus == 503)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
        if !condition() { throw URLError(.timedOut) }
    }
}
