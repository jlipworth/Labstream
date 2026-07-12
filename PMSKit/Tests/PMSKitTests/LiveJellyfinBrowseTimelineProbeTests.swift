import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PMSKit

/// Secret-gated Phase 3D/4A proof against a real Jellyfin server.
///
/// Timeline acceptance MUTATES a TEST ACCOUNT resume point. A PASS requires explicit write opt-in,
/// a distinct safe offset, successful readback, and verified restoration of the original offset.
/// The timeline uses the source id, session id, and play method negotiated by real PlaybackInfo;
/// it never fabricates playback identity merely to make the progress endpoints accept a request.
struct LiveJellyfinBrowseTimelineProbeTests {
    private struct Config {
        let server: URL
        let token: String
        let userID: String
        let itemID: String
        let timelineOffsetTicks: Int?
        let allowsTimelineWrite: Bool
        let identity: JellyfinClientIdentity

        init?(_ env: [String: String] = ProcessInfo.processInfo.environment) {
            guard let serverString = env["JELLYFIN_SERVER_URL"],
                  let server = try? JellyfinServerURL.normalized(serverString),
                  let token = env["JELLYFIN_ACCESS_TOKEN"], !token.isEmpty,
                  let userID = env["JELLYFIN_USER_ID"], !userID.isEmpty,
                  let itemID = env["JELLYFIN_LIVE_ITEM_ID"], !itemID.isEmpty
            else { return nil }

            self.server = server
            self.token = token
            self.userID = userID
            self.itemID = itemID
            self.timelineOffsetTicks = env["JELLYFIN_LIVE_TIMELINE_OFFSET_SECONDS"]
                .flatMap(Int.init)
                .map { max(0, $0) * 10_000_000 }
            self.allowsTimelineWrite = env["JELLYFIN_LIVE_ALLOW_TIMELINE_WRITE"] == "1"
            self.identity = JellyfinClientIdentity(
                client: "Labstream",
                device: "Apple Vision Pro",
                deviceId: env["JELLYFIN_LIVE_DEVICE_ID"] ?? "labstream-jellyfin-live-probe",
                version: "0.1.0"
            )
        }
    }

    private enum ProbeFailure: Error {
        case badHTTP
        case invalidFixture
        case resumeReadback
        case restoration
    }

    private let transport = LiveProbeTransport()

    @Test func liveJellyfinBrowseAndTimeline() async throws {
        guard let cfg = Config() else {
            print(">>> JELLYFIN VERDICT: SKIP — set JELLYFIN_SERVER_URL / JELLYFIN_ACCESS_TOKEN / JELLYFIN_USER_ID / JELLYFIN_LIVE_ITEM_ID to run.")
            return
        }

        try await proveBrowse(cfg)
        print(">>> JELLYFIN [browse] VERDICT: PASS — shared views/items/metadata wrappers decoded live responses.")

        let originalItem = try await fetchItem(cfg)
        let originalTicks = originalItem.userData?.playbackPositionTicks ?? 0
        guard cfg.allowsTimelineWrite, let targetTicks = cfg.timelineOffsetTicks else {
            print(">>> JELLYFIN VERDICT: SKIP — timeline acceptance mutates a TEST ACCOUNT; set JELLYFIN_LIVE_ALLOW_TIMELINE_WRITE=1 and JELLYFIN_LIVE_TIMELINE_OFFSET_SECONDS.")
            return
        }
        guard targetTicks != originalTicks,
              let duration = originalItem.runTimeTicks,
              targetTicks >= 30 * 10_000_000,
              targetTicks < duration * 8 / 10 else {
            Issue.record("Jellyfin timeline offset must be distinct, at least 30 seconds, and below 80% of the configured test item")
            throw ProbeFailure.invalidFixture
        }

        let targetPlayback = try await negotiatePlayback(cfg, startTimeTicks: targetTicks)
        var primaryError: (any Error)?
        do {
            try await reportTimeline(positionTicks: targetTicks, playback: targetPlayback, cfg: cfg)
            let observed = try await waitForPosition(targetTicks, cfg: cfg)
            let readbackMatched = observed == targetTicks
            #expect(readbackMatched, "Jellyfin resume readback did not observe the requested test offset")
            if !readbackMatched { throw ProbeFailure.resumeReadback }
        } catch {
            primaryError = error
        }

        // Restoration is mandatory even when the target request or readback failed. Never suppress
        // a restoration error: the operator must know the TEST ACCOUNT may retain the probe offset.
        do {
            let restorePlayback = try await negotiatePlayback(cfg, startTimeTicks: originalTicks)
            try await reportTimeline(positionTicks: originalTicks,
                                     playback: restorePlayback,
                                     cfg: cfg,
                                     label: "restore")
            let restored = try await waitForPosition(originalTicks, cfg: cfg)
            let restoreMatched = restored == originalTicks
            #expect(restoreMatched, "Jellyfin probe did not restore the original resume offset")
            if !restoreMatched { throw ProbeFailure.restoration }
        } catch {
            Issue.record("Jellyfin TEST ACCOUNT resume restoration failed; manual verification is required")
            throw ProbeFailure.restoration
        }

        if let primaryError { throw primaryError }
        print(">>> JELLYFIN VERDICT: PASS — shared browse and real-PlaybackInfo timeline requests passed 2xx, resume readback, and verified restoration.")
    }

    private func proveBrowse(_ cfg: Config) async throws {
        let viewsRequest = try JellyfinLibrary.userViewsRequest(server: cfg.server,
                                                                token: cfg.token,
                                                                identity: cfg.identity,
                                                                userId: cfg.userID)
        let (viewsData, viewsStatus) = try await transport.send(viewsRequest)
        print(">>> JELLYFIN [views] HTTP \(viewsStatus), \(viewsData.count) bytes")
        let views2xx = (200..<300).contains(viewsStatus)
        #expect(views2xx, "Jellyfin views expected 2xx")
        guard views2xx else { throw ProbeFailure.badHTTP }
        let views = try JSONDecoder().decode(JellyfinUserViewsResponse.self, from: viewsData)
        let hasViews = !views.items.isEmpty
        #expect(hasViews, "Jellyfin test account should expose at least one user view")
        guard hasViews else { throw ProbeFailure.invalidFixture }

        let itemsRequest = try JellyfinLibrary.itemsRequest(server: cfg.server,
                                                            token: cfg.token,
                                                            identity: cfg.identity,
                                                            userId: cfg.userID,
                                                            recursive: true,
                                                            limit: 5,
                                                            includeItemTypes: "Movie,Episode,Video")
        let (itemsData, itemsStatus) = try await transport.send(itemsRequest)
        print(">>> JELLYFIN [items] HTTP \(itemsStatus), \(itemsData.count) bytes")
        let items2xx = (200..<300).contains(itemsStatus)
        #expect(items2xx, "Jellyfin items expected 2xx")
        guard items2xx else { throw ProbeFailure.badHTTP }
        let page = try JellyfinItemsResponse.decode(from: itemsData)
        let mappingComplete = !page.items.isEmpty && page.items.compactMap { $0.toMediaItem() }.count == page.items.count
        #expect(mappingComplete, "Jellyfin requested video rows should all map to MediaItem")
        guard mappingComplete else { throw ProbeFailure.invalidFixture }

        _ = try await fetchItem(cfg)
    }

    private func fetchItem(_ cfg: Config) async throws -> JellyfinBaseItemDto {
        let request = try JellyfinLibrary.itemRequest(server: cfg.server,
                                                      token: cfg.token,
                                                      identity: cfg.identity,
                                                      userId: cfg.userID,
                                                      itemId: cfg.itemID)
        let (data, status) = try await transport.send(request)
        print(">>> JELLYFIN [metadata] HTTP \(status), \(data.count) bytes")
        let succeeded = (200..<300).contains(status)
        #expect(succeeded, "Jellyfin metadata expected 2xx")
        guard succeeded else { throw ProbeFailure.badHTTP }
        return try JSONDecoder().decode(JellyfinBaseItemDto.self, from: data)
    }

    private func negotiatePlayback(_ cfg: Config,
                                   startTimeTicks: Int) async throws -> JellyfinPlaybackOpenResult {
        let request = try JellyfinPlayback.playbackInfoRequest(
            server: cfg.server,
            token: cfg.token,
            identity: cfg.identity,
            itemId: cfg.itemID,
            userId: cfg.userID,
            startTimeTicks: startTimeTicks,
            maxStreamingBitrate: 200_000_000
        )
        let (data, status) = try await transport.send(request)
        print(">>> JELLYFIN [playbackInfo] HTTP \(status), \(data.count) bytes")
        let succeeded = (200..<300).contains(status)
        #expect(succeeded, "Jellyfin PlaybackInfo expected 2xx")
        guard succeeded else { throw ProbeFailure.badHTTP }
        let response = try JellyfinPlaybackInfoResponse.decode(from: data)
        return try JellyfinPlayback.resolveStream(response: response,
                                                   server: cfg.server,
                                                   identity: cfg.identity,
                                                   token: cfg.token,
                                                   itemId: cfg.itemID,
                                                   startTimeTicks: startTimeTicks,
                                                   maxVideoBitrate: 200_000_000)
    }

    private func reportTimeline(positionTicks: Int,
                                playback: JellyfinPlaybackOpenResult,
                                cfg: Config,
                                label: String = "timeline") async throws {
        let requests = try [
            ("playing", JellyfinPlayback.playingRequest(
                server: cfg.server, token: cfg.token, identity: cfg.identity,
                userId: cfg.userID, itemId: cfg.itemID, mediaSourceId: playback.mediaSourceId,
                playSessionId: playback.playSessionId, playMethod: playback.playMethod,
                positionTicks: positionTicks)),
            ("progress", JellyfinPlayback.progressRequest(
                server: cfg.server, token: cfg.token, identity: cfg.identity,
                userId: cfg.userID, itemId: cfg.itemID, mediaSourceId: playback.mediaSourceId,
                playSessionId: playback.playSessionId, playMethod: playback.playMethod,
                positionTicks: positionTicks, isPaused: false)),
            ("paused", JellyfinPlayback.progressRequest(
                server: cfg.server, token: cfg.token, identity: cfg.identity,
                userId: cfg.userID, itemId: cfg.itemID, mediaSourceId: playback.mediaSourceId,
                playSessionId: playback.playSessionId, playMethod: playback.playMethod,
                positionTicks: positionTicks, isPaused: true)),
            ("stopped", JellyfinPlayback.stoppedRequest(
                server: cfg.server, token: cfg.token, identity: cfg.identity,
                userId: cfg.userID, itemId: cfg.itemID, mediaSourceId: playback.mediaSourceId,
                playSessionId: playback.playSessionId, playMethod: playback.playMethod,
                positionTicks: positionTicks)),
        ]

        for (event, request) in requests {
            let (_, status) = try await transport.send(request)
            print(">>> JELLYFIN [\(label).\(event)] HTTP \(status)")
            let succeeded = (200..<300).contains(status)
            #expect(succeeded, "Jellyfin timeline event expected 2xx")
            guard succeeded else { throw ProbeFailure.badHTTP }
        }
    }

    private func waitForPosition(_ expected: Int, cfg: Config) async throws -> Int {
        var observed = -1
        for attempt in 0..<8 {
            observed = try await fetchItem(cfg).userData?.playbackPositionTicks ?? 0
            if observed == expected { return observed }
            if attempt < 7 { try await Task.sleep(for: .milliseconds(500)) }
        }
        return observed
    }
}
