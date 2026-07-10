import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PMSKit

/// Opt-in discovery probe for the downloads-engine fault harness.
///
/// Phase 6 needs an original/static Plex item larger than one segment; choosing an arbitrary
/// item is unreliable because an MKV or incompatible source enters server optimization before
/// `BackgroundDownloadSession` ever creates a range train. This probe scans live movie metadata,
/// runs the production direct-play decision for plausible MP4/M4V parts, and prints only stable
/// identifiers plus technical facts needed to invoke `probe-plex-range-drop.sh`.
struct LivePhase6DownloadCandidateProbeTests {
    private struct Candidate {
        let ratingKey: String
        let mediaIndex: Int
        let partIndex: Int
        let media: Media
        let part: Part
    }

    @Test func findLargeOriginalStaticCandidates() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let config = LiveProbeConfig(env, deviceName: "Labstream Phase 6 Candidate Probe") else {
            print(">>> PHASE6 skipped: PLEX_LIVE_SERVER / PLEX_LIVE_TOKEN not set")
            return
        }

        let scanLimit = max(1, env["PLEX_LIVE_PHASE6_SCAN_LIMIT"].flatMap(Int.init) ?? 300)
        let decisionLimit = max(1, env["PLEX_LIVE_PHASE6_DECISION_LIMIT"].flatMap(Int.init) ?? 20)
        let segmentBytes = 512 * 1_024 * 1_024
        let minimumBytes = max(
            segmentBytes + 1,
            env["PLEX_LIVE_PHASE6_MIN_BYTES"].flatMap(Int.init) ?? 600 * 1_024 * 1_024
        )
        let maxVideoBitrateKbps = env["PLEX_LIVE_MAX_KBPS"].flatMap(Int.init) ?? 200_000
        let headers = PlexHeaders.standard(identity: config.identity, token: config.token)
        let transport = LiveProbeTransport()

        let sectionsRequest = PlexRequest(
            url: config.server.appendingPathComponent("/library/sections"),
            method: "GET",
            headers: headers
        )
        let (sectionsData, sectionsStatus) = try await transport.send(sectionsRequest.urlRequest())
        #expect(sectionsStatus == 200)
        let sections = try JSONDecoder().decode(SectionsResponse.self, from: sectionsData)
            .mediaContainer.directory.filter { $0.type == "movie" }

        var candidates: [Candidate] = []
        for section in sections where candidates.count < decisionLimit {
            let listRequest = PlexRequest(
                url: config.server.appendingPathComponent("/library/sections/\(section.key)/all"),
                method: "GET",
                queryItems: [
                    URLQueryItem(name: "type", value: "1"),
                    URLQueryItem(name: "sort", value: "addedAt:desc"),
                    URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
                    URLQueryItem(name: "X-Plex-Container-Size", value: String(scanLimit)),
                ],
                headers: headers
            )
            let (listData, listStatus) = try await transport.send(listRequest.urlRequest())
            guard listStatus == 200,
                  let response = try? JSONDecoder().decode(MetadataResponse.self, from: listData)
            else { continue }

            for item in response.mediaContainer.metadata {
                for (mediaIndex, media) in (item.media ?? []).enumerated() {
                    for (partIndex, part) in media.part.enumerated() {
                        let container = (part.container ?? media.container ?? "").lowercased()
                        guard (container == "mp4" || container == "m4v"),
                              (part.size ?? 0) >= minimumBytes else { continue }
                        candidates.append(Candidate(ratingKey: item.ratingKey,
                                                    mediaIndex: mediaIndex,
                                                    partIndex: partIndex,
                                                    media: media,
                                                    part: part))
                        if candidates.count >= decisionLimit { break }
                    }
                    if candidates.count >= decisionLimit { break }
                }
                if candidates.count >= decisionLimit { break }
            }
        }

        print(">>> PHASE6 plausible=\(candidates.count) min_bytes=\(minimumBytes) decision_limit=\(decisionLimit)")
        var eligible = 0
        for candidate in candidates {
            let metadataKey = "/library/metadata/\(candidate.ratingKey)"
            let request = TranscodeRequest(
                server: config.server,
                token: config.token,
                identity: config.identity,
                metadataKey: metadataKey,
                maxVideoBitrateKbps: maxVideoBitrateKbps,
                sessionID: "phase6-candidate-\(UUID().uuidString)",
                mediaIndex: candidate.mediaIndex,
                partIndex: candidate.partIndex
            ).directPlayProbeRequest()
            let (decisionData, status) = try await transport.send(request.urlRequest())
            guard status == 200,
                  let decision = try? JSONDecoder().decode(DecisionResponse.self, from: decisionData)
            else {
                print(">>> PHASE6 candidate ratingKey=\(candidate.ratingKey) media=\(candidate.mediaIndex) "
                      + "part=\(candidate.partIndex) status=\(status) eligible=false reason=decision_http")
                continue
            }
            let result = OfflineDownloadDecision.originalEligibility(decision: decision,
                                                                       part: candidate.part)
            let sizeBucket = DiagnosticRedactor.byteBucket(candidate.part.size ?? 0)
            print(">>> PHASE6 candidate ratingKey=\(candidate.ratingKey) media=\(candidate.mediaIndex) "
                  + "part=\(candidate.partIndex) size=\(sizeBucket) "
                  + "container=\(candidate.part.container ?? candidate.media.container ?? "unknown") "
                  + "video=\(candidate.media.videoCodec ?? candidate.part.videoStreams.first?.codec ?? "unknown") "
                  + "audio=\(candidate.media.audioCodec ?? candidate.part.audioStreams.first?.codec ?? "unknown") "
                  + "eligible=\(result.canDownloadOriginal) reason=\(result.optimizeReason ?? "none")")
            if result.canDownloadOriginal { eligible += 1 }
        }
        print(">>> PHASE6 eligible=\(eligible)")
    }
}
