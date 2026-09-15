#if DEBUG
import AVFoundation
import Foundation
import os
import Testing
@testable import Labstream
import PMSKit

@MainActor
struct PlaybackAgentEvidenceTests {
    @Test(arguments: [MediaBackendKind.jellyfin, .emby])
    func directPlayEvidenceDoesNotInventCopyForOtherMethods(backend: MediaBackendKind) throws {
        let identity = ClientIdentity(clientIdentifier: "fixture-only", product: "Labstream", version: "1", deviceName: "Fixture")
        let methods: [MediaBrowserPlayMethod?] = [.directPlay, .directStream, .transcode, nil]
        for method in methods {
            let session = MediaBrowserPlaybackSession(
                streamURL: try #require(URL(string: "https://fixture.invalid/video.mp4")),
                backend: backend, backendLabel: backend.displayName, httpHeaders: [:],
                playSessionID: "fixture-session", sourceMetadata: .init(videoCodec: "h264"),
                playMethod: method ?? .directPlay, transcodeReasons: [],
                progressSession: nil, onStop: {}, reopener: { _ in throw URLError(.cancelled) })
            session.playMethod = method
            let controller = PlaybackController(
                item: MediaItem(ratingKey: "fixture", title: "Fixture", type: "movie"),
                sessionSource: .mediaBrowser(session), identity: identity,
                client: PlexClient(identity: identity), maxVideoBitrateKbps: 0)
            let snapshot = controller.debugEvidenceSnapshot()
            #expect(snapshot.videoDecision == (method == .directPlay ? .copy : .unknown))
            #expect(snapshot.audioDecision == (method == .directPlay ? .copy : .unknown))
            #expect(snapshot.videoProvenance == (method == .directPlay ? .serverDecision : .unknown))
            #expect(snapshot.renderedFormat == "unknown")
            #expect(snapshot.serverCleanup == "unknown")
            #expect(snapshot.visibleAttachment == .detached)
            session.playMethod = nil
            #expect(controller.debugEvidenceSnapshot().videoDecision == .unknown)
            controller.stop()
        }
    }

    @Test(arguments: [MediaBackendKind.jellyfin, .emby])
    func terminalCleanupDetachesAndCanBeJoinedExactlyOnce(backend: MediaBackendKind) async throws {
        var asyncStops = 0
        var legacyStops = 0
        var finished = false
        let identity = ClientIdentity(clientIdentifier: "fixture-only", product: "Labstream",
                                      version: "1", deviceName: "Fixture")
        let session = MediaBrowserPlaybackSession(
            streamURL: URL(fileURLWithPath: "/fixture.invalid"), backend: backend,
            backendLabel: backend.displayName, httpHeaders: [:], playSessionID: "fixture-session",
            sourceMetadata: .init(videoCodec: "hevc"), playMethod: .transcode,
            transcodeReasons: [], progressSession: nil, onStop: { legacyStops += 1 },
            reopener: { _ in throw URLError(.cancelled) }, onStopAndWait: {
                asyncStops += 1
                await Task.yield()
                finished = true
            })
        let controller = PlaybackController(
            item: MediaItem(ratingKey: "fixture", title: "Fixture", type: "movie"),
            sessionSource: .mediaBrowser(session), identity: identity,
            client: PlexClient(identity: identity), maxVideoBitrateKbps: 0)
        controller.player.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: "/fixture.invalid")))
        controller.stop()
        #expect(controller.player.currentItem == nil)
        controller.stop()
        await controller.waitForPendingStopRequests()
        #expect(finished)
        #expect(asyncStops == 1)
        #expect(legacyStops == 0)
    }

    @Test func failedScenarioWaitsForRemoteCleanupBeforeReturning() async throws {
        var finished = false
        let identity = ClientIdentity(clientIdentifier: "fixture-only", product: "Labstream",
                                      version: "1", deviceName: "Fixture")
        let session = MediaBrowserPlaybackSession(
            streamURL: URL(fileURLWithPath: "/fixture.invalid"), backend: .jellyfin,
            backendLabel: "Jellyfin", httpHeaders: [:], playSessionID: "fixture-session",
            sourceMetadata: .init(videoCodec: "hevc"), playMethod: .transcode,
            transcodeReasons: [], progressSession: nil, onStop: {},
            reopener: { _ in throw URLError(.cancelled) }, onStopAndWait: {
                await Task.yield()
                finished = true
            })
        let controller = PlaybackController(
            item: MediaItem(ratingKey: "fixture", title: "Fixture", type: "movie"),
            sessionSource: .mediaBrowser(session), identity: identity,
            client: PlexClient(identity: identity), maxVideoBitrateKbps: 0)
        let arguments = ["--vp-probe-query", "Fixture", "--vp-probe-allow-live", "--vp-probe-scenario", "original"]
        let options = try #require(DebugPlaybackProbeSupport.launchOptions(from: arguments, defaultBitrateKbps: 0))
        do {
            try await DebugPlaybackScenario.run(controller, options: options, arguments: arguments,
                backendIsCurrent: { false }, log: Logger(subsystem: "fixture", category: "fixture"))
            Issue.record("Stale backend must fail")
        } catch let error as DebugPlaybackScenario.Blocked {
            #expect(error.reason == .backendChanged)
        }
        #expect(finished)
    }

    @Test func initializationCaptureExcludesMediaAndMalformedContainers() {
        func box(_ type: String) -> Data { Data([0, 0, 0, 8]) + Data(type.utf8) }
        let valid = box("ftyp") + box("moov")
        #expect(DebugMediaBrowserHDREvidence.isInitialization(valid))
        #expect(DebugMediaBrowserHDREvidence.isInitialization(valid + box("free")))
        for invalid in [Data(), Data(valid.dropLast()), box("moov") + box("ftyp"),
                        valid + box("mdat"), valid + box("moof"), valid + box("moov"),
                        valid + box("ftyp"), Data([0, 0, 0, 0]) + Data("ftyp".utf8)] {
            #expect(!DebugMediaBrowserHDREvidence.isInitialization(invalid))
        }
    }

    @Test func initializationCaptureReferencesStayOnTheirBoundOrigin() throws {
        let base = try #require(URL(string: "https://media.example.internal:8443/video/main.m3u8"))
        #expect(DebugMediaBrowserHDREvidence.resolve("init.mp4", relativeTo: base)?.path == "/video/init.mp4")
        for invalid in ["https://other.example.internal:8443/init.mp4", "http://media.example.internal:8443/init.mp4",
                        "https://media.example.internal/init.mp4", "https://user@media.example.internal:8443/init.mp4",
                        "init.mp4#fragment"] {
            #expect(DebugMediaBrowserHDREvidence.resolve(invalid, relativeTo: base) == nil)
        }
    }

    @Test func detachedSeekClockRemainsPending() {
        for position in [Double.nan, .infinity, -.infinity, 0, 597.9, 602.1] {
            #expect(!DebugPlaybackScenario.seekTargetReached(positionSeconds: position, targetMs: 600_000))
        }
        for position in [598.0, 600.0, 602.0] {
            #expect(DebugPlaybackScenario.seekTargetReached(positionSeconds: position, targetMs: 600_000))
        }
    }

    @Test(arguments: [MediaBackendKind.jellyfin, .emby])
    func fixtureConsentTransitions(backend: MediaBackendKind) async throws {
        var stopped = false
        var reopened = false
        let identity = ClientIdentity(clientIdentifier: "fixture-only", product: "Labstream", version: "1", deviceName: "Fixture")
        let session = MediaBrowserPlaybackSession(
            streamURL: try #require(URL(string: "https://fixture.invalid/master.m3u8")),
            backend: backend, backendLabel: backend.displayName, httpHeaders: [:],
            playSessionID: "private-sentinel", sourceMetadata: .init(videoCodec: "unsupported"),
            playMethod: .transcode, transcodeReasons: ["VideoCodecNotSupported"],
            progressSession: nil, onStop: {}, reopener: { _ in
                reopened = true
                throw URLError(.cancelled)
            }, onStopAndWait: { stopped = true })
        let controller = PlaybackController(
            item: MediaItem(ratingKey: "private-sentinel", title: "private-sentinel", type: "movie"),
            sessionSource: .mediaBrowser(session), identity: identity,
            client: PlexClient(identity: identity), maxVideoBitrateKbps: 0)
        defer { controller.stop() }
        controller.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !controller.videoTranscodeConsent.isPending, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        do {
            try await DebugPlaybackProbeSupport.waitUntilPlayable(controller, phase: "fixture", timeoutSeconds: 1)
            Issue.record("A consent gate must not be reported as playable or time out")
        } catch let error as DebugPlaybackScenario.Blocked {
            #expect(error.reason == .consentRequired)
            #expect(controller.debugEvidenceSnapshot().consent == .pending)
        }
        let generation = try #require(controller.videoTranscodeConsent.generation)
        let pending = controller.debugEvidenceSnapshot()
        #expect(pending.backend.rawValue == backend.rawValue)
        #expect(pending.consent == .pending)
        #expect(pending.phase == .consent)
        #expect(pending.visibleAttachment == .detached)
        #expect(pending.videoDecision == .unknown)
        #expect(pending.serverCleanup == "unknown")
        #expect(stopped && !reopened)
        controller.declineVideoTranscoding(generation: generation)
        #expect(controller.debugEvidenceSnapshot().consent == .notPending)
        controller.stop()
        controller.approveVideoTranscoding(generation: generation)
        #expect(!reopened)
        let terminal = controller.debugEvidenceSnapshot()
        #expect(terminal.cleanupRequested)
        #expect(terminal.phase == .stopped)
        #expect(terminal.generation != pending.generation)
        let data = try JSONEncoder().encode(terminal)
        #expect(!String(decoding: data, as: UTF8.self).contains("private-sentinel"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == Set(["buildNumber", "phase", "bufferBucketSeconds", "renderedFormat", "schemaVersion",
            "generation", "backend", "qualityKbps", "videoDecision", "videoProvenance", "audioDecision", "consent",
            "visibleAttachment", "positionBucketSeconds", "cleanupRequested", "serverCleanup"]))
    }

    @Test func runStartResetRemovesEveryPreviousCaptureLabel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for label in ["plex-initial", "plex-postseek", "emby-initial"] {
            let labelDirectory = directory.appendingPathComponent(label)
            try FileManager.default.createDirectory(at: labelDirectory, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: labelDirectory.appendingPathComponent("frame-00.png"))
        }
        try DebugPlaybackFrameCapture.resetDirectory(at: directory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        try DebugPlaybackFrameCapture.resetDirectory(at: directory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    /// Virtual polling separates the identity/deadline oracle from MainActor load.
    @Test func delayedTrackReplacementDoesNotAcceptThePredecessor() async throws {
        let old = AVPlayerItem(asset: AVMutableComposition())
        let replacement = AVPlayerItem(asset: AVMutableComposition())
        let player = AVPlayer(playerItem: old)
        defer { player.replaceCurrentItem(with: nil) }
        var now = ContinuousClock.now
        var polls = 0
        try await DebugPlaybackScenario.waitForReplacement(of: old, player: player, timeoutSeconds: 2,
            now: { now }, poll: { delay in
                #expect(delay == .milliseconds(250))
                polls += 1
                now = now.advanced(by: delay)
                switch polls {
                case 1:
                    #expect(player.currentItem === old)
                    // Keep the predecessor for another complete observation.
                case 2:
                    #expect(player.currentItem === old)
                    player.replaceCurrentItem(with: nil)
                case 3:
                    #expect(player.currentItem == nil)
                    player.replaceCurrentItem(with: replacement)
                default:
                    Issue.record("Replacement must finish without another poll")
                }
            })
        #expect(polls == 3)
        #expect(player.currentItem === replacement)
    }

    @Test(arguments: [false, true])
    func missingReplacementFailsClosed(detached: Bool) async throws {
        let old = AVPlayerItem(asset: AVMutableComposition())
        let player = AVPlayer(playerItem: detached ? nil : old)
        defer { player.replaceCurrentItem(with: nil) }
        let start = ContinuousClock.now
        var now = start
        var polls = 0
        do {
            try await DebugPlaybackScenario.waitForReplacement(of: old, player: player, timeoutSeconds: 2,
                now: { now }, poll: { delay in
                    #expect(delay == .milliseconds(250))
                    polls += 1
                    now = now.advanced(by: delay)
                })
            Issue.record("Neither predecessor nor detached item may satisfy replacement")
        } catch let error as DebugPlaybackScenario.Blocked {
            #expect(error.reason == .deadline)
        }
        #expect(polls == 8)
        #expect(start.duration(to: now) == .seconds(2))
    }

    @Test func replacementAtExpiredDeadlineIsNotAccepted() async throws {
        let old = AVPlayerItem(asset: AVMutableComposition())
        let replacement = AVPlayerItem(asset: AVMutableComposition())
        let player = AVPlayer(playerItem: old)
        defer { player.replaceCurrentItem(with: nil) }
        var now = ContinuousClock.now
        do {
            try await DebugPlaybackScenario.waitForReplacement(of: old, player: player, timeoutSeconds: 2,
                now: { now }, poll: { _ in
                    now = now.advanced(by: .seconds(2))
                    player.replaceCurrentItem(with: replacement)
                })
            Issue.record("A late replacement must not bypass the deadline")
        } catch let error as DebugPlaybackScenario.Blocked {
            #expect(error.reason == .deadline)
        }
        #expect(player.currentItem === replacement)
    }

    @Test(arguments: [DebugPlaybackScenario.Reason.backendChanged, .playbackFailed, .consentRequired])
    func replacementCannotBypassSafetyGates(reason: DebugPlaybackScenario.Reason) async throws {
        let old = AVPlayerItem(asset: AVMutableComposition())
        let replacement = AVPlayerItem(asset: AVMutableComposition())
        let player = AVPlayer(playerItem: old)
        defer { player.replaceCurrentItem(with: nil) }
        var now = ContinuousClock.now
        var replaced = false
        do {
            try await DebugPlaybackScenario.waitForReplacement(of: old, player: player, timeoutSeconds: 2,
                sessionIsCurrent: { !(replaced && reason == .backendChanged) },
                playbackFailed: { replaced && reason == .playbackFailed },
                consentPending: { replaced && reason == .consentRequired },
                now: { now }, poll: { delay in
                    now = now.advanced(by: delay)
                    player.replaceCurrentItem(with: replacement)
                    replaced = true
                })
            Issue.record("A replacement cannot supersede a safety gate")
        } catch let error as DebugPlaybackScenario.Blocked {
            #expect(error.reason == reason)
        }
        #expect(replaced)
    }

    @Test func cancelledReplacementWaitDoesNotPoll() async throws {
        let old = AVPlayerItem(asset: AVMutableComposition())
        let player = AVPlayer(playerItem: old)
        defer { player.replaceCurrentItem(with: nil) }
        let task = Task { @MainActor in
            do {
                try await DebugPlaybackScenario.waitForReplacement(of: old, player: player, timeoutSeconds: 2,
                    poll: { _ in Issue.record("Cancelled wait must not poll") })
                Issue.record("Cancelled wait must throw")
            } catch is CancellationError {
                // Expected before any item observation or suspension.
            } catch {
                Issue.record("Unexpected cancellation error: \(error)")
            }
        }
        // Both run on MainActor: cancellation occurs before the task can begin.
        task.cancel()
        await task.value
    }

    @Test func onlyMetadataSubtitleMechanismsRequireReplacement() {
        #expect(DebugPlaybackScenario.subtitleRequiresReplacement(.plexOff))
        #expect(DebugPlaybackScenario.subtitleRequiresReplacement(.plexStream(1)))
        #expect(DebugPlaybackScenario.subtitleRequiresReplacement(.mediaBrowserOff))
        #expect(DebugPlaybackScenario.subtitleRequiresReplacement(.mediaBrowserStream(1)))
        #expect(!DebugPlaybackScenario.subtitleRequiresReplacement(.avFoundationOff))
        #expect(!DebugPlaybackScenario.subtitleRequiresReplacement(.offlineOff))
    }

    @Test func changedBackendStopsBeforeStartingPlayback() async throws {
        let identity = ClientIdentity(clientIdentifier: "fixture-only", product: "Labstream",
                                      version: "1", deviceName: "Fixture")
        let controller = PlaybackController(
            item: MediaItem(ratingKey: "fixture", title: "Fixture", type: "movie"),
            sessionSource: .offline(OfflinePlaybackSession(fileURL: URL(fileURLWithPath: "/fixture.invalid"))),
            identity: identity, client: PlexClient(identity: identity), maxVideoBitrateKbps: 0)
        let arguments = ["--vp-probe-query", "Fixture", "--vp-probe-allow-live", "--vp-probe-scenario", "original"]
        let options = try #require(DebugPlaybackProbeSupport.launchOptions(from: arguments, defaultBitrateKbps: 0))
        do {
            try await DebugPlaybackScenario.run(controller, options: options, arguments: arguments,
                backendIsCurrent: { false }, log: Logger(subsystem: "fixture", category: "fixture"))
            Issue.record("A stale backend must not run playback")
        } catch let error as DebugPlaybackScenario.Blocked {
            #expect(error.reason == .backendChanged)
        }
        #expect(controller.debugEvidenceSnapshot().cleanupRequested)
        #expect(controller.player.currentItem == nil)
    }

    @Test func admissionIsSeparateForVideoEncoding() {
        #expect(!DebugPlaybackScenario.admitted([], bitrateKbps: 0))
        #expect(DebugPlaybackScenario.admitted(["--vp-probe-allow-live", "--vp-probe-scenario", "original"], bitrateKbps: 0))
        #expect(!DebugPlaybackScenario.admitted(["--vp-probe-allow-live", "--vp-probe-scenario", "consentApprove"], bitrateKbps: 0))
        #expect(!DebugPlaybackScenario.admitted(["--vp-probe-allow-live"], bitrateKbps: 8_000))
        #expect(DebugPlaybackScenario.admitted(["--vp-probe-allow-live", "--vp-probe-allow-video-encode",
                                               "--vp-probe-scenario", "consentApprove"], bitrateKbps: 0))
        #expect(DebugPlaybackScenario.name(["--vp-probe-scenario", "unknown-command"]) == nil)
    }

    @Test func invalidOptionsFailClosed() {
        for extra in [["--vp-probe-post-seek-hold-seconds", "-1"],
                      ["--vp-probe-stall-tolerance-seconds", "999999999999999999999"],
                      ["--vp-probe-seek-ms", "oops"]] {
            #expect(DebugPlaybackProbeSupport.launchOptions(from: ["--vp-probe-query", "Fixture"] + extra,
                                                             defaultBitrateKbps: 0) == nil)
        }
    }
}
#endif
