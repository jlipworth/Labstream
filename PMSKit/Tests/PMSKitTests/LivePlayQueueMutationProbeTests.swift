import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PMSKit

/// Opt-in live Plex play-queue mutation probe (#121).
///
/// Creates an ephemeral server play queue, adds a second fixture as "play next", then creates a
/// shuffled queue. This is a wire-level probe for the real PMS endpoints; it does not start
/// playback or transcode media.
struct LivePlayQueueMutationProbeTests {

    private struct Config {
        let base: LiveProbeConfig
        let metadataKey: String
        let ratingKey: String
        let nextRatingKey: String
        let machineIdentifier: String?

        var server: URL { base.server }
        var token: String { base.token }
        var identity: ClientIdentity { base.identity }

        init?() {
            guard let base = LiveProbeConfig() else { return nil }
            let env = ProcessInfo.processInfo.environment
            guard let key = env["PLEX_LIVE_PLAYQUEUE_METADATA_KEY"] ?? env["PLEX_LIVE_METADATA_KEY"],
                  !key.isEmpty,
                  let next = env["PLEX_LIVE_PLAYQUEUE_NEXT_METADATA_KEY"], !next.isEmpty
            else { return nil }
            self.base = base
            self.metadataKey = Self.metadataPath(key)
            self.ratingKey = Self.ratingKey(key)
            self.nextRatingKey = Self.ratingKey(next)
            self.machineIdentifier = env["PLEX_LIVE_MACHINE_IDENTIFIER"]?.nilIfEmpty
        }

        private static func metadataPath(_ raw: String) -> String {
            raw.hasPrefix("/") ? raw : "/library/metadata/\(raw)"
        }

        private static func ratingKey(_ raw: String) -> String {
            raw.split(separator: "/").last.map(String.init) ?? raw
        }
    }

    private struct ServerRootResponse: Decodable {
        let mediaContainer: Container
        enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
        struct Container: Decodable {
            let machineIdentifier: String?
        }
    }

    private func send(_ req: PlexRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: req.urlRequest())
        return (data, (response as? HTTPURLResponse)?.statusCode ?? -1)
    }

    private func resolveMachineIdentifier(_ cfg: Config) async throws -> String? {
        if let machineIdentifier = cfg.machineIdentifier { return machineIdentifier }
        let req = PlexRequest(url: cfg.server,
                              method: "GET",
                              headers: PlexHeaders.standard(identity: cfg.identity, token: cfg.token))
        let (data, status) = try await send(req)
        guard status == 200,
              let decoded = try? JSONDecoder().decode(ServerRootResponse.self, from: data),
              let machineIdentifier = decoded.mediaContainer.machineIdentifier,
              !machineIdentifier.isEmpty else {
            print(">>> PLAYQUEUE root HTTP \(status) — could not resolve machineIdentifier; set PLEX_LIVE_MACHINE_IDENTIFIER.")
            return nil
        }
        return machineIdentifier
    }

    private func decodeQueue(_ label: String, data: Data, status: Int) -> PlayQueueResponse? {
        guard status == 200 else {
            print(">>> PLAYQUEUE [\(label)] HTTP \(status) — expected 200.")
            return nil
        }
        guard let decoded = try? JSONDecoder().decode(PlayQueueResponse.self, from: data) else {
            print(">>> PLAYQUEUE [\(label)] HTTP 200 but body did not decode as PlayQueueResponse (\(data.count) bytes).")
            return nil
        }
        let ids = decoded.mediaContainer.metadata.map(\.ratingKey).joined(separator: ",")
        print(">>> PLAYQUEUE [\(label)] id=\(decoded.mediaContainer.playQueueID.map(String.init) ?? "nil") shuffled=\(decoded.mediaContainer.playQueueShuffled.map(String.init) ?? "nil") items=[\(ids)]")
        return decoded
    }

    @Test func livePlayQueueMutationRoundTrips() async throws {
        guard let cfg = Config() else {
            print(">>> PLAYQUEUE skipped: set PLEX_LIVE_SERVER / PLEX_LIVE_TOKEN / PLEX_LIVE_PLAYQUEUE_METADATA_KEY / PLEX_LIVE_PLAYQUEUE_NEXT_METADATA_KEY to run.")
            return
        }
        guard let machineIdentifier = try await resolveMachineIdentifier(cfg) else {
            print(">>> PLAYQUEUE VERDICT: missing machineIdentifier — skipping.")
            return
        }

        let create = PlayQueue.createRequest(server: cfg.server,
                                             token: cfg.token,
                                             identity: cfg.identity,
                                             machineIdentifier: machineIdentifier,
                                             ratingKey: cfg.ratingKey,
                                             type: "video",
                                             continuous: true)
        let (createData, createStatus) = try await send(create)
        guard let created = decodeQueue("create", data: createData, status: createStatus),
              let queueID = created.mediaContainer.playQueueID else {
            Issue.record("Could not create a live play queue.")
            return
        }

        let add = PlayQueue.playNextRequest(server: cfg.server,
                                            token: cfg.token,
                                            identity: cfg.identity,
                                            playQueueID: queueID,
                                            machineIdentifier: machineIdentifier,
                                            ratingKey: cfg.nextRatingKey)
        let (_, addStatus) = try await send(add)
        print(">>> PLAYQUEUE [play-next] HTTP \(addStatus)")
        #expect((200..<300).contains(addStatus), "play-next mutation expected 2xx, got \(addStatus)")

        let (afterAddData, afterAddStatus) = try await send(PlayQueue.getRequest(server: cfg.server,
                                                                                 token: cfg.token,
                                                                                 identity: cfg.identity,
                                                                                 playQueueID: queueID))
        if let afterAdd = decodeQueue("after-play-next", data: afterAddData, status: afterAddStatus) {
            let queue = afterAdd.mediaContainer.metadata
            let selectedIndex = afterAdd.mediaContainer.playQueueSelectedItemOffset
                .flatMap { queue.indices.contains($0) ? $0 : nil }
                ?? queue.firstIndex { $0.ratingKey == cfg.ratingKey }
            let nextAfterSelected = selectedIndex.flatMap { queue.indices.contains($0 + 1) ? queue[$0 + 1].ratingKey : nil }
            #expect(queue.contains { $0.ratingKey == cfg.nextRatingKey },
                    "play-next item should appear in the refreshed queue")
            #expect(nextAfterSelected == cfg.nextRatingKey,
                    "play-next item should be immediately after the selected item; got \(nextAfterSelected ?? "nil")")
        }

        // PMS accepted `shuffle=1` on POST /playQueues in live testing, while
        // PUT /playQueues/{id}/shuffle returned 404 on this PMS version. Prove the supported
        // wire-level shuffle operation instead of baking in the non-working endpoint.
        let createShuffled = PlayQueue.createRequest(server: cfg.server,
                                                     token: cfg.token,
                                                     identity: cfg.identity,
                                                     machineIdentifier: machineIdentifier,
                                                     ratingKey: cfg.ratingKey,
                                                     type: "video",
                                                     continuous: true,
                                                     shuffled: true)
        let (shuffleData, shuffleStatus) = try await send(createShuffled)
        print(">>> PLAYQUEUE [create-shuffled] HTTP \(shuffleStatus)")
        guard let shuffledQueue = decodeQueue("create-shuffled", data: shuffleData, status: shuffleStatus) else {
            Issue.record("Could not create a shuffled live play queue.")
            return
        }
        #expect(shuffledQueue.mediaContainer.playQueueShuffled == true,
                "shuffled queue creation should report playQueueShuffled=true")

        print(">>> PLAYQUEUE VERDICT: OK — create, play-next, and shuffled queue creation round-tripped on the live server.")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
