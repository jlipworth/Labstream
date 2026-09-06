import Foundation
import PMSKit
import Testing
@testable import Labstream

@Suite(.serialized)
@MainActor
struct PlaybackVideoTranscodeConsentTests {
    @Test func originalWaitsForConsentBeforeAnyMediaStartAndDeclineDoesNotEncode() async throws {
        let fixture = try makeFixture()
        defer { fixture.controller.stop() }
        fixture.controller.start()
        try await waitUntil { fixture.controller.videoTranscodeConsent.isPending }
        #expect(fixture.requests.value.filter { $0.url?.path.hasSuffix("decision") == true }.count == 1)
        #expect(!fixture.requests.value.contains { $0.url?.path.hasSuffix("start.m3u8") == true })
        let generation = try #require(fixture.controller.videoTranscodeConsent.generation)
        fixture.controller.declineVideoTranscoding(generation: generation)
        #expect(!fixture.controller.videoTranscodeConsent.isPending)
        #expect(fixture.controller.playbackError.isFailed)
        fixture.controller.approveVideoTranscoding(generation: generation) // stale button action is inert
        #expect(!fixture.requests.value.contains { $0.url?.path.hasSuffix("start.m3u8") == true })
    }

    @Test func stopInvalidatesPendingApproval() async throws {
        let fixture = try makeFixture()
        fixture.controller.start()
        try await waitUntil { fixture.controller.videoTranscodeConsent.isPending }
        let generation = try #require(fixture.controller.videoTranscodeConsent.generation)
        fixture.controller.stop()
        fixture.controller.approveVideoTranscoding(generation: generation)
        #expect(!fixture.controller.videoTranscodeConsent.isPending)
        #expect(!fixture.requests.value.contains { $0.url?.path.hasSuffix("start.m3u8") == true })
    }

    @Test func approvalForcesVideoEncodingAndPrimesSavedResume() async throws {
        let fixture = try makeFixture()
        defer { fixture.controller.stop() }
        fixture.controller.start()
        try await waitUntil { fixture.controller.videoTranscodeConsent.isPending }
        fixture.controller.approveVideoTranscoding(generation: try #require(fixture.controller.videoTranscodeConsent.generation))
        try await waitUntil {
            fixture.requests.value.filter { $0.url?.path.hasSuffix("decision") == true }.count >= 2
        }
        let decisionRequests = fixture.requests.value.filter { $0.url?.path.hasSuffix("decision") == true }
        let copy = URLComponents(url: try #require(decisionRequests.first?.url), resolvingAgainstBaseURL: false)
        let approved = URLComponents(url: try #require(decisionRequests.last?.url), resolvingAgainstBaseURL: false)
        #expect(copy?.queryItems?.first { $0.name == "directStream" }?.value == "1")
        #expect(approved?.queryItems?.first { $0.name == "directStream" }?.value == "0")
        #expect(approved?.queryItems?.first { $0.name == "offset" }?.value == "120")
        #expect(!fixture.controller.videoTranscodeConsent.isPending)
    }

    @Test func oldButtonCannotApproveANewerPrompt() async throws {
        let fixture = try makeFixture()
        defer { fixture.controller.stop() }
        fixture.controller.start()
        try await waitUntil { fixture.controller.videoTranscodeConsent.isPending }
        let oldGeneration = try #require(fixture.controller.videoTranscodeConsent.generation)
        fixture.controller.reload(bitrateKbps: 0)
        try await waitUntil {
            fixture.controller.videoTranscodeConsent.generation.map { $0 != oldGeneration } == true
        }
        fixture.controller.approveVideoTranscoding(generation: oldGeneration)
        fixture.controller.declineVideoTranscoding(generation: oldGeneration)
        #expect(fixture.controller.videoTranscodeConsent.isPending)
        #expect(!fixture.requests.value.contains { $0.url?.path.hasSuffix("start.m3u8") == true })
    }

    @Test(arguments: [MediaBackendKind.jellyfin, .emby])
    func mediaBrowserStopsBeforePromptAndApprovalReopensWithAuthority(backend: MediaBackendKind) async throws {
        var stopped = false
        var approvedRequest: RemoteStreamReopenRequest?
        let identity = ClientIdentity(clientIdentifier: "jellyfin-consent-test", product: "Labstream",
                                      version: "1", deviceName: "Test")
        let session = MediaBrowserPlaybackSession(
            streamURL: try #require(URL(string: "https://fixture.invalid/master.m3u8")),
            backend: backend, backendLabel: backend.displayName, httpHeaders: [:],
            playSessionID: "fixture-session", sourceMetadata: .init(videoCodec: "unsupported"),
            playMethod: .transcode, transcodeReasons: ["VideoCodecNotSupported"],
            progressSession: nil, onStop: {}, reopener: { request in
                approvedRequest = request
                throw URLError(.cancelled)
            }, onStopAndWait: { stopped = true })
        let controller = PlaybackController(
            item: MediaItem(ratingKey: "fixture", title: "Fixture", type: "movie", viewOffset: 120_000),
            sessionSource: .mediaBrowser(session), identity: identity,
            client: PlexClient(identity: identity), maxVideoBitrateKbps: 0)
        defer { controller.stop() }
        controller.start()
        try await waitUntil { controller.videoTranscodeConsent.isPending }
        #expect(stopped)
        #expect(approvedRequest == nil)
        let generation = try #require(controller.videoTranscodeConsent.generation)
        controller.approveVideoTranscoding(generation: generation)
        try await waitUntil { approvedRequest != nil }
        #expect(approvedRequest?.videoTranscodeApproved == true)
        #expect(approvedRequest?.offsetMs == 120_000)
    }

    @Test func canceledPreparationStillRunsUncancelledExactSessionCleanup() async throws {
        var cleanupWasCancelled: Bool?
        let result = RemoteStreamOpenResult(url: try #require(URL(string: "https://fixture.invalid/master.m3u8")),
            headers: [:], onStopAndWait: { cleanupWasCancelled = Task.isCancelled })
        let task = Task { @MainActor in
            await Task.yield()
            await result.stopAndWaitIgnoringCancellation()
        }
        task.cancel()
        await task.value
        #expect(cleanupWasCancelled == false)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "Controller did not reach the expected state")
    }

    private func makeFixture() throws -> (controller: PlaybackController, session: URLSession,
                                          requests: TestLockedBox<[URLRequest]>, stub: TestURLProtocolStub) {
        let requests = TestLockedBox<[URLRequest]>([])
        let stub = TestURLProtocolStub { request in
            requests.withValue { $0.append(request) }
            let body = request.url?.path.hasSuffix("decision") == true
                ? #"{"MediaContainer":{"generalDecisionCode":1001,"Metadata":[{"Media":[{"Part":[{"Stream":[{"streamType":1,"decision":"transcode"}]}]}]}]}}"#
                : "{}"
            return (HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: "HTTP/1.1", headerFields: nil)!, Data(body.utf8))
        }
        let session = URLSession(configuration: stub.configuration)
        let identity = ClientIdentity(clientIdentifier: "consent-test", product: "Labstream",
                                      version: "1", deviceName: "Test")
        let controller = PlaybackController(
            item: MediaItem(ratingKey: "fixture", title: "Fixture", type: "movie", viewOffset: 120_000),
            sessionSource: .plex(PlexPlaybackSession(server: try #require(URL(string: "https://fixture.invalid")),
                                                     token: "fixture-token")),
            identity: identity, client: PlexClient(session: session, identity: identity),
            maxVideoBitrateKbps: 0)
        return (controller, session, requests, stub)
    }
}
