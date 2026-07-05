import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PMSKit

/// Headless live probe for GH #195: verify the new HDR/color/Dolby Vision stream-metadata
/// decoding against REAL Plex, Jellyfin, and Emby servers. Opt-in via the same env files as
/// the other `Live*Probe`s (scripts/plex-live.env, jellyfin-live.env, emby-live.env); with
/// the env absent every test no-ops, keeping plain `swift test` and CI hermetic.
///
/// For each backend it lists recent/known movies, decodes the video streams with the
/// PRODUCTION decoders (`Stream.hdrMetadata` / `MediaBrowserItemMediaStreamDto.hdrMetadata`),
/// and prints one `>>> LIVE` line per item: raw color/DV attributes + the classified label.
/// Output is shape-only where it must be (no tokens/hosts); item ids/titles stay in the
/// local terminal only — do not commit probe output.
///
/// Run: set -a; source scripts/plex-live.env scripts/jellyfin-live.env scripts/emby-live.env; set +a
///      cd PMSKit && swift test --filter LiveHDRMetadataProbe
struct LiveHDRMetadataProbeTests {

    private let transport = LiveProbeTransport()

    private func hdrSummary(_ hdr: VideoHDRMetadata?) -> String {
        guard let hdr else { return "nil (no color/DV facts)" }
        return "\(hdr.format.rawValue) | \(hdr.displayLabel) | short=\(hdr.shortLabel)"
    }

    // MARK: Plex

    @Test func plexVideoStreamsClassify() async throws {
        guard let cfg = LiveProbeConfig(deviceName: "Labstream HDR Probe") else {
            print(">>> LIVE [plex-hdr] skipped: PLEX_LIVE_SERVER / PLEX_LIVE_TOKEN not set")
            return
        }
        let headers = PlexHeaders.standard(identity: cfg.identity, token: cfg.token)

        // 1. Sections → movie section keys.
        let sectionsReq = PlexRequest(url: cfg.server.appendingPathComponent("/library/sections"),
                                      method: "GET",
                                      headers: headers)
        let (sectionsData, sectionsStatus) = try await transport.send(sectionsReq.urlRequest())
        #expect(sectionsStatus == 200)
        let sections = try JSONDecoder().decode(SectionsResponse.self, from: sectionsData)
        let movieSections = sections.mediaContainer.directory.filter { $0.type == "movie" }
        print(">>> LIVE [plex-hdr] sections HTTP \(sectionsStatus), movie sections: \(movieSections.count)")

        // 2. For each movie section, take a page of items and fetch full metadata (which
        //    carries the per-part Stream elements) for a handful.
        var classified = 0
        var withHDRFacts = 0
        for section in movieSections.prefix(2) {
            let listReq = PlexRequest(url: cfg.server.appendingPathComponent("/library/sections/\(section.key)/all"),
                                      method: "GET",
                                      queryItems: [URLQueryItem(name: "type", value: "1")],
                                      headers: headers)
            let (listData, listStatus) = try await transport.send(listReq.urlRequest())
            guard listStatus == 200 else {
                print(">>> LIVE [plex-hdr] section list HTTP \(listStatus) — skipping section")
                continue
            }
            let list = try JSONDecoder().decode(MetadataResponse.self, from: listData)
            for item in list.mediaContainer.metadata.prefix(12) {
                let ratingKey = item.ratingKey
                let metaReq = PlexRequest(url: cfg.server.appendingPathComponent("/library/metadata/\(ratingKey)"),
                                          method: "GET",
                                          headers: headers)
                let (metaData, metaStatus) = try await transport.send(metaReq.urlRequest())
                guard metaStatus == 200,
                      let full = try? JSONDecoder().decode(MetadataResponse.self, from: metaData),
                      let fullItem = full.mediaContainer.metadata.first else { continue }
                for media in fullItem.media ?? [] {
                    for part in media.part {
                        for video in part.videoStreams {
                            classified += 1
                            if video.hdrMetadata != nil { withHDRFacts += 1 }
                            let raw = "trc=\(video.colorTrc ?? "-") prim=\(video.colorPrimaries ?? "-") "
                                + "depth=\(video.bitDepth.map(String.init) ?? "-") "
                                + "dovi=\(video.doviPresent.map(String.init) ?? "-") "
                                + "p=\(video.doviProfile.map(String.init) ?? "-") "
                                + "compat=\(video.doviBLCompatID.map(String.init) ?? "-")"
                            print(">>> LIVE [plex-hdr] rk=\(ratingKey) codec=\(video.codec ?? "-") "
                                + "{\(raw)} → \(hdrSummary(video.hdrMetadata))")
                        }
                        if let audio = part.audioStreams.first {
                            let label = AVFormatLabels.audioDisplayName(codec: audio.codec,
                                                                        channels: audio.channels,
                                                                        profile: audio.profile) ?? "-"
                            print(">>> LIVE [plex-hdr] rk=\(ratingKey) audio codec=\(audio.codec ?? "-") "
                                + "profile=\(audio.profile ?? "-") ch=\(audio.channels.map(String.init) ?? "-") → \(label)")
                        }
                    }
                }
            }
        }
        print(">>> LIVE [plex-hdr] video streams decoded: \(classified), with HDR classification: \(withHDRFacts)")
        #expect(classified > 0, "expected at least one decodable Plex video stream")
    }

    // MARK: Jellyfin

    @Test func jellyfinMediaStreamsClassify() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let serverString = env["JELLYFIN_SERVER_URL"], let server = URL(string: serverString),
              let token = env["JELLYFIN_ACCESS_TOKEN"], !token.isEmpty,
              let userId = env["JELLYFIN_USER_ID"], !userId.isEmpty else {
            print(">>> LIVE [jf-hdr] skipped: JELLYFIN_SERVER_URL / JELLYFIN_ACCESS_TOKEN / JELLYFIN_USER_ID not set")
            return
        }
        try await probeMediaBrowser(label: "jf-hdr",
                                    itemsURL: server.appendingPathComponent("/Users/\(userId)/Items"),
                                    token: token)
    }

    // MARK: Emby

    @Test func embyMediaStreamsClassify() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let serverString = env["EMBY_LIVE_SERVER"],
              let server = try? EmbyServerURL.normalized(serverString),
              let token = env["EMBY_LIVE_TOKEN"], !token.isEmpty,
              let userId = env["EMBY_LIVE_USER_ID"], !userId.isEmpty else {
            print(">>> LIVE [emby-hdr] skipped: EMBY_LIVE_SERVER / EMBY_LIVE_TOKEN / EMBY_LIVE_USER_ID not set")
            return
        }
        try await probeMediaBrowser(label: "emby-hdr",
                                    itemsURL: server.appendingPathComponent("/emby/Users/\(userId)/Items"),
                                    token: token)
    }

    // MARK: Shared MediaBrowser (Jellyfin + Emby) probe

    /// Minimal local wrapper: we only need Id/Name/MediaSources → the production
    /// `MediaBrowserItemMediaStreamDto` decoder underneath.
    private struct ItemsEnvelope: Decodable {
        struct Item: Decodable {
            let id: String?
            let mediaSources: [MediaSource]?
            enum CodingKeys: String, CodingKey {
                case id = "Id"
                case mediaSources = "MediaSources"
            }
        }
        struct MediaSource: Decodable {
            let container: String?
            let mediaStreams: [MediaBrowserItemMediaStreamDto]?
            enum CodingKeys: String, CodingKey {
                case container = "Container"
                case mediaStreams = "MediaStreams"
            }
        }
        let items: [Item]
        enum CodingKeys: String, CodingKey { case items = "Items" }
    }

    private func probeMediaBrowser(label: String, itemsURL: URL, token: String) async throws {
        var components = URLComponents(url: itemsURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie"),
            URLQueryItem(name: "Fields", value: "MediaSources"),
            URLQueryItem(name: "Limit", value: "60"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        let (data, status) = try await transport.send(request)
        print(">>> LIVE [\(label)] items HTTP \(status), bytes=\(data.count)")
        #expect(status == 200)
        guard status == 200 else { return }

        let envelope = try JSONDecoder().decode(ItemsEnvelope.self, from: data)
        var classified = 0
        var withHDRFacts = 0
        for item in envelope.items {
            for source in item.mediaSources ?? [] {
                for stream in source.mediaStreams ?? []
                where stream.type?.caseInsensitiveCompare("Video") == .orderedSame {
                    classified += 1
                    if stream.hdrMetadata != nil { withHDRFacts += 1 }
                    let raw = "range=\(stream.videoRange ?? "-")/\(stream.videoRangeType ?? "-") "
                        + "trc=\(stream.colorTransfer ?? "-") depth=\(stream.bitDepth.map(String.init) ?? "-") "
                        + "dvP=\(stream.dvProfile.map(String.init) ?? "-") "
                        + "compat=\(stream.dvBlSignalCompatibilityId.map(String.init) ?? "-") "
                        + "hdr10+=\(stream.hdr10PlusPresentFlag.map(String.init) ?? "-") "
                        + "ext=\(stream.extendedVideoType ?? "-")/\(stream.extendedVideoSubType ?? "-")"
                    print(">>> LIVE [\(label)] id=\(item.id ?? "-") codec=\(stream.codec ?? "-") "
                        + "{\(raw)} → \(hdrSummary(stream.hdrMetadata))")
                }
                if let audio = (source.mediaStreams ?? []).first(where: {
                    $0.type?.caseInsensitiveCompare("Audio") == .orderedSame
                }) {
                    let friendly = AVFormatLabels.audioDisplayName(codec: audio.codec,
                                                                   channels: audio.channels,
                                                                   profile: audio.profile) ?? "-"
                    print(">>> LIVE [\(label)] id=\(item.id ?? "-") audio codec=\(audio.codec ?? "-") "
                        + "profile=\(audio.profile ?? "-") ch=\(audio.channels.map(String.init) ?? "-") → \(friendly)")
                }
            }
        }
        print(">>> LIVE [\(label)] video streams decoded: \(classified), with HDR classification: \(withHDRFacts)")
        #expect(classified > 0, "expected at least one decodable \(label) video stream")
    }
}
