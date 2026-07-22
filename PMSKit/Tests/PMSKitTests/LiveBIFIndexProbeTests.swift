import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PMSKit

/// Headless BIF-availability probe against a REAL Plex Media Server. Answers, for one item:
///   1. does the item's detail metadata advertise `indexes="sd"` on its Part(s)
///      (`Part.hasStandardDefinitionBIFIndex` — the gate `cachePlexBIF` and the online
///      trick-play provider both use), and
///   2. does `GET /library/parts/{id}/indexes/sd` actually return a parseable BIF?
///
/// This separates "server never generated preview thumbnails" from "the item snapshot the
/// app used was missing the `indexes` attribute" when offline downloads end up without a BIF.
///
/// OPT-IN like every Live* probe: no env vars → immediate skip, so plain `swift test` stays
/// hermetic. Logs are shape-only (status/byte counts/frame counts); never the host, token,
/// or media titles.
///
/// Inputs (env):
///   PLEX_LIVE_SERVER / PLEX_LIVE_TOKEN   (required, shared with the other probes)
///   PLEX_LIVE_BIF_METADATA_KEY           (required — bare ratingKey or "/library/metadata/<id>")
struct LiveBIFIndexProbeTests {

    private struct Config {
        let base: LiveProbeConfig
        let ratingKey: String

        init?() {
            guard let base = LiveProbeConfig(deviceName: "Labstream BIF Probe") else { return nil }
            let env = ProcessInfo.processInfo.environment
            guard let key = env["PLEX_LIVE_BIF_METADATA_KEY"], !key.isEmpty else { return nil }
            self.base = base
            self.ratingKey = key.split(separator: "/").last.map(String.init) ?? key
        }
    }

    private func send(_ req: PlexRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: req.urlRequest())
        return (data, (response as? HTTPURLResponse)?.statusCode ?? -1)
    }

    /// `GET /library/metadata/{key}` with the chapter/marker extras the app's detail fetch sends.
    private func detailRequest(_ cfg: Config) -> PlexRequest {
        PlexRequest(url: cfg.base.server.appendingPathComponent("/library/metadata/\(cfg.ratingKey)"),
                    method: "GET",
                    queryItems: [
                        .init(name: "includeChapters", value: "1"),
                        .init(name: "includeMarkers", value: "1"),
                    ],
                    headers: PlexHeaders.standard(identity: cfg.base.identity, token: cfg.base.token))
    }

    @Test func liveBIFIndexProbe() async throws {
        guard let cfg = Config() else {
            print(">>> BIF skipped: set PLEX_LIVE_SERVER / PLEX_LIVE_TOKEN / PLEX_LIVE_BIF_METADATA_KEY to run.")
            return
        }

        // Leg 1: detail metadata — does any Part advertise indexes="sd"?
        let (data, status) = try await send(detailRequest(cfg))
        print(">>> BIF [detail] HTTP \(status), \(data.count) bytes")
        guard status == 200,
              let decoded = try? JSONDecoder().decode(MetadataResponse.self, from: data),
              let item = decoded.mediaContainer.metadata.first else {
            print(">>> BIF [detail] no decodable item — skipping.")
            return
        }
        let parts = (item.media ?? []).flatMap(\.part)
        for (i, part) in parts.enumerated() {
            print(">>> BIF [detail] part[\(i)] id=\(part.id) indexes=\(part.indexes ?? "nil") hasSDBIF=\(part.hasStandardDefinitionBIFIndex)")
        }
        print(">>> BIF [detail] chapters=\(item.chapters?.count ?? 0)")

        // Leg 2: regardless of the advertisement, does the BIF endpoint serve a parseable index?
        for part in parts {
            let req = TrickPlayRequest.plexBIFIndex(server: cfg.base.server,
                                                    token: cfg.base.token,
                                                    identity: cfg.base.identity,
                                                    partID: part.id,
                                                    quality: "sd")
            let (bifData, bifStatus) = try await send(req)
            let parsed = try? BIFParser.parse(bifData)
            print(">>> BIF [fetch] part=\(part.id) HTTP \(bifStatus), \(bifData.count) bytes, parsedFrames=\(parsed?.frameCount ?? -1)")
        }
    }
}
