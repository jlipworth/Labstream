import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PMSKit

/// Secret-gated Phase 3D/4A proof against a real Jellyfin server.
///
/// The browse legs execute the public Jellyfin wrappers that delegate to the shared
/// `MediaBrowserLibraryRequestFactory`. The timeline legs execute the public wrappers that
/// delegate to `MediaBrowserPlaybackProgressRequestPlan`. Missing credentials are reported as an
/// explicit SKIP verdict and never touch the network.
///
/// Set `JELLYFIN_LIVE_TIMELINE_OFFSET_SECONDS` only for a test account when a distinct resume
/// write/readback is desired. The probe restores the original offset before returning. Without
/// that opt-in it still proves all four timeline requests receive 2xx, but does not claim a resume
/// mutation round trip.
struct LiveJellyfinBrowseTimelineProbeTests {
    private struct Config {
        let server: URL
        let token: String
        let userID: String
        let itemID: String
        let timelineOffsetTicks: Int?
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
            self.identity = JellyfinClientIdentity(
                client: "Labstream",
                device: "Apple Vision Pro",
                deviceId: env["JELLYFIN_LIVE_DEVICE_ID"] ?? "labstream-jellyfin-live-probe",
                version: "0.1.0"
            )
        }
    }

    private let transport = LiveProbeTransport()

    @Test func liveJellyfinBrowseAndTimeline() async throws {
        guard let cfg = Config() else {
            print(">>> JELLYFIN VERDICT: SKIP — set JELLYFIN_SERVER_URL / JELLYFIN_ACCESS_TOKEN / JELLYFIN_USER_ID / JELLYFIN_LIVE_ITEM_ID to run.")
            return
        }

        let viewsRequest = try JellyfinLibrary.userViewsRequest(
            server: cfg.server,
            token: cfg.token,
            identity: cfg.identity,
            userId: cfg.userID
        )
        let (viewsData, viewsStatus) = try await transport.send(viewsRequest)
        print(">>> JELLYFIN [views] HTTP \(viewsStatus), \(viewsData.count) bytes")
        #expect((200..<300).contains(viewsStatus), "Jellyfin views expected 2xx, got \(viewsStatus)")
        guard (200..<300).contains(viewsStatus) else { throw URLError(.badServerResponse) }
        let views = try JSONDecoder().decode(JellyfinUserViewsResponse.self, from: viewsData)
        #expect(!views.items.isEmpty, "Jellyfin account should expose at least one user view")
        guard !views.items.isEmpty else { throw URLError(.resourceUnavailable) }

        let itemsRequest = try JellyfinLibrary.itemsRequest(
            server: cfg.server,
            token: cfg.token,
            identity: cfg.identity,
            userId: cfg.userID,
            recursive: true,
            limit: 5,
            includeItemTypes: "Movie,Episode,Video"
        )
        let (itemsData, itemsStatus) = try await transport.send(itemsRequest)
        print(">>> JELLYFIN [items] HTTP \(itemsStatus), \(itemsData.count) bytes")
        #expect((200..<300).contains(itemsStatus), "Jellyfin items expected 2xx, got \(itemsStatus)")
        guard (200..<300).contains(itemsStatus) else { throw URLError(.badServerResponse) }
        let page = try JellyfinItemsResponse.decode(from: itemsData)
        #expect(!page.items.isEmpty, "Jellyfin browse page should contain an item")
        guard !page.items.isEmpty else { throw URLError(.resourceUnavailable) }
        #expect(page.items.compactMap { $0.toMediaItem() }.count == page.items.count,
                "Every requested video row should map to MediaItem")
        guard page.items.compactMap({ $0.toMediaItem() }).count == page.items.count else {
            throw URLError(.cannotDecodeContentData)
        }

        let originalItem = try await fetchItem(cfg)
        guard let mediaSourceID = originalItem.mediaSources.first?.id, !mediaSourceID.isEmpty else {
            Issue.record("Configured Jellyfin item has no media-source id; timeline proof cannot run")
            return
        }
        let originalTicks = originalItem.userData?.playbackPositionTicks ?? 0
        let targetTicks = cfg.timelineOffsetTicks ?? originalTicks
        let playSessionID = UUID().uuidString

        do {
            try await reportTimeline(positionTicks: targetTicks,
                                     mediaSourceID: mediaSourceID,
                                     playSessionID: playSessionID,
                                     cfg: cfg)
            if cfg.timelineOffsetTicks != nil {
                let observed = try await waitForPosition(targetTicks, cfg: cfg)
                #expect(observed == targetTicks,
                        "Jellyfin resume readback did not observe the explicitly requested offset")
                guard observed == targetTicks else { throw URLError(.cannotParseResponse) }
            } else {
                print(">>> JELLYFIN [timeline] READBACK SKIP — set JELLYFIN_LIVE_TIMELINE_OFFSET_SECONDS on a test account for mutation proof.")
            }
        } catch {
            if targetTicks != originalTicks {
                try? await reportTimeline(positionTicks: originalTicks,
                                          mediaSourceID: mediaSourceID,
                                          playSessionID: UUID().uuidString,
                                          cfg: cfg)
            }
            throw error
        }

        if targetTicks != originalTicks {
            try await reportTimeline(positionTicks: originalTicks,
                                     mediaSourceID: mediaSourceID,
                                     playSessionID: UUID().uuidString,
                                     cfg: cfg,
                                     label: "restore")
            let restored = try await waitForPosition(originalTicks, cfg: cfg)
            #expect(restored == originalTicks, "Jellyfin probe did not restore the original resume offset")
            guard restored == originalTicks else { throw URLError(.cannotParseResponse) }
        }

        print(">>> JELLYFIN VERDICT: PASS — shared browse wrappers decoded live responses and timeline wrappers returned 2xx\(cfg.timelineOffsetTicks == nil ? "; resume readback not requested" : "; resume readback + restore passed").")
    }

    private func fetchItem(_ cfg: Config) async throws -> JellyfinBaseItemDto {
        let request = try JellyfinLibrary.itemRequest(server: cfg.server,
                                                      token: cfg.token,
                                                      identity: cfg.identity,
                                                      userId: cfg.userID,
                                                      itemId: cfg.itemID)
        let (data, status) = try await transport.send(request)
        print(">>> JELLYFIN [metadata] HTTP \(status), \(data.count) bytes")
        #expect((200..<300).contains(status), "Jellyfin metadata expected 2xx, got \(status)")
        guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(JellyfinBaseItemDto.self, from: data)
    }

    private func reportTimeline(positionTicks: Int,
                                mediaSourceID: String,
                                playSessionID: String,
                                cfg: Config,
                                label: String = "timeline") async throws {
        let requests = try [
            ("playing", JellyfinPlayback.playingRequest(
                server: cfg.server, token: cfg.token, identity: cfg.identity,
                userId: cfg.userID, itemId: cfg.itemID, mediaSourceId: mediaSourceID,
                playSessionId: playSessionID, playMethod: .directPlay, positionTicks: positionTicks)),
            ("progress", JellyfinPlayback.progressRequest(
                server: cfg.server, token: cfg.token, identity: cfg.identity,
                userId: cfg.userID, itemId: cfg.itemID, mediaSourceId: mediaSourceID,
                playSessionId: playSessionID, playMethod: .directPlay,
                positionTicks: positionTicks, isPaused: false)),
            ("paused", JellyfinPlayback.progressRequest(
                server: cfg.server, token: cfg.token, identity: cfg.identity,
                userId: cfg.userID, itemId: cfg.itemID, mediaSourceId: mediaSourceID,
                playSessionId: playSessionID, playMethod: .directPlay,
                positionTicks: positionTicks, isPaused: true)),
            ("stopped", JellyfinPlayback.stoppedRequest(
                server: cfg.server, token: cfg.token, identity: cfg.identity,
                userId: cfg.userID, itemId: cfg.itemID, mediaSourceId: mediaSourceID,
                playSessionId: playSessionID, playMethod: .directPlay, positionTicks: positionTicks)),
        ]

        for (event, request) in requests {
            let (_, status) = try await transport.send(request)
            print(">>> JELLYFIN [\(label).\(event)] HTTP \(status)")
            #expect((200..<300).contains(status),
                    "Jellyfin \(event) expected 2xx, got \(status)")
            guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
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
