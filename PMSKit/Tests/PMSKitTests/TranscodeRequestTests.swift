import Testing
import Foundation
@testable import PMSKit

private let server = URL(string: "https://192.0.2.10:32400")!
private let id = ClientIdentity(clientIdentifier: "CID", product: "VisionPlex", version: "0.1.0", deviceName: "AVP")

private func queryItems(_ url: URL) -> [URLQueryItem] {
    URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
}

// MARK: - Plan-listed tests

@Test func startURLHasRequiredTranscodeParams() {
    let req = TranscodeRequest(server: server, token: "tok", identity: id,
                               metadataKey: "/library/metadata/101",
                               maxVideoBitrateKbps: 8000,
                               sessionID: "SESSION-1",
                               mediaIndex: 0, partIndex: 0)
    let url = req.startM3U8URL()
    let q = queryItems(url)
    func v(_ n: String) -> String? { q.first { $0.name == n }?.value }
    #expect(url.path == "/video/:/transcode/universal/start.m3u8")
    #expect(v("protocol") == "hls")
    #expect(v("maxVideoBitrate") == "8000")
    #expect(v("directPlay") == "0")
    #expect(v("path") == "/library/metadata/101")
    #expect(v("session") == "SESSION-1")
    #expect(v("X-Plex-Token") == "tok")            // token as QUERY param
    #expect(v("partIndex") == "0")
}

@Test func downloadURLUsesProgressiveHTTPAndDownloadFlag() {
    let req = TranscodeRequest(server: server, token: "tok", identity: id,
                               metadataKey: "/library/metadata/101",
                               maxVideoBitrateKbps: 4000,
                               sessionID: "SESSION-DL",
                               mediaIndex: 0, partIndex: 0)
    let url = req.downloadURL()
    let q = queryItems(url)
    func v(_ n: String) -> String? { q.first { $0.name == n }?.value }
    // Single-file progressive download, NOT segmented HLS.
    #expect(url.path == "/video/:/transcode/universal/start")
    #expect(v("protocol") == "http")
    #expect(v("download") == "1")
    // The chosen quality cap is honored exactly as for streaming.
    #expect(v("maxVideoBitrate") == "4000")
    #expect(v("path") == "/library/metadata/101")
    #expect(v("X-Plex-Token") == "tok")
    // Exactly one protocol param survives the hls->http override.
    #expect(q.filter { $0.name == "protocol" }.count == 1)
}

@Test func decisionURLUsesDecisionPathAndHasMDE() {
    let req = TranscodeRequest(server: server, token: "tok", identity: id,
                               metadataKey: "/library/metadata/101",
                               maxVideoBitrateKbps: 8000, sessionID: "S", mediaIndex: 0, partIndex: 0)
    let url = req.decisionURL()
    #expect(url.path == "/video/:/transcode/universal/decision")
    let q = queryItems(url)
    #expect(q.contains(URLQueryItem(name: "hasMDE", value: "1")))
}

@Test func deviceProfileDeclaresHLSAndBitrateLimit() {
    let p = DeviceProfile.visionOS(maxVideoBitrateKbps: 8000)
    #expect(p.clientProfileExtra.contains("add-transcode-target"))
    #expect(p.clientProfileExtra.contains("protocol=hls"))
}

// MARK: - Extra over-testing (plan: HEVC fMP4, subtitle burn-in, non-zero partIndex)

@Test func deviceProfileDeclaresHEVCInFMP4Container() {
    // HEVC over HLS requires the fMP4 (mp4) container (research/09).
    let p = DeviceProfile.visionOS(maxVideoBitrateKbps: 8000)
    let extra = p.clientProfileExtra
    #expect(extra.contains("hevc"))
    #expect(extra.contains("container=mp4"))
    // And the bitrate cap is present.
    #expect(extra.contains("add-limitation"))
    #expect(extra.contains("8000"))
}

@Test func subtitleBurnInAddsBurnParams() {
    let req = TranscodeRequest(server: server, token: "tok", identity: id,
                               metadataKey: "/library/metadata/101",
                               maxVideoBitrateKbps: 8000, sessionID: "S",
                               mediaIndex: 0, partIndex: 0,
                               burnSubtitleStreamID: 3)
    let q = queryItems(req.startM3U8URL())
    func v(_ n: String) -> String? { q.first { $0.name == n }?.value }
    #expect(v("subtitles") == "burn")
    #expect(v("subtitleStreamID") == "3")
}

@Test func defaultSubtitlesAreAuto() {
    let req = TranscodeRequest(server: server, token: "tok", identity: id,
                               metadataKey: "/library/metadata/101",
                               maxVideoBitrateKbps: 8000, sessionID: "S",
                               mediaIndex: 0, partIndex: 0)
    let q = queryItems(req.startM3U8URL())
    #expect(q.first { $0.name == "subtitles" }?.value == "auto")
}

@Test func nonZeroPartIndexIsIndependentOfMediaIndex() {
    // Guards against python-plexapi's partIndex=mediaIndex bug (research/09):
    // mediaIndex and partIndex must travel independently.
    let req = TranscodeRequest(server: server, token: "tok", identity: id,
                               metadataKey: "/library/metadata/101",
                               maxVideoBitrateKbps: 8000, sessionID: "S",
                               mediaIndex: 0, partIndex: 2)
    let q = queryItems(req.startM3U8URL())
    func v(_ n: String) -> String? { q.first { $0.name == n }?.value }
    #expect(v("mediaIndex") == "0")
    #expect(v("partIndex") == "2")
    // The two must NOT be coupled.
    #expect(v("partIndex") != v("mediaIndex"))
}

@Test func nonZeroMediaIndexDoesNotLeakIntoPartIndex() {
    let req = TranscodeRequest(server: server, token: "tok", identity: id,
                               metadataKey: "/library/metadata/101",
                               maxVideoBitrateKbps: 8000, sessionID: "S",
                               mediaIndex: 3, partIndex: 0)
    let q = queryItems(req.startM3U8URL())
    func v(_ n: String) -> String? { q.first { $0.name == n }?.value }
    #expect(v("mediaIndex") == "3")
    #expect(v("partIndex") == "0")
}

@Test func resumeOffsetIsSentToPMSOnStreamButStrippedFromDownload() {
    let req = TranscodeRequest(server: server, token: "tok", identity: id,
                               metadataKey: "/library/metadata/101",
                               maxVideoBitrateKbps: 8000, sessionID: "S",
                               mediaIndex: 0, partIndex: 0,
                               startOffsetSeconds: 1860)
    func v(_ items: [URLQueryItem], _ n: String) -> String? { items.first { $0.name == n }?.value }
    // Streaming carries the resume offset (so PMS primes the transcoder + emits EXT-X-START).
    #expect(v(queryItems(req.startM3U8URL()), "offset") == "1860")
    #expect(v(queryItems(req.decisionURL()), "offset") == "1860")
    // A download always grabs the whole file from the start — never an offset.
    #expect(v(queryItems(req.downloadURL()), "offset") == nil)
    // Absent/zero offset must not emit the param at all.
    let noOffset = TranscodeRequest(server: server, token: "tok", identity: id,
                                    metadataKey: "/library/metadata/101",
                                    maxVideoBitrateKbps: 8000, sessionID: "S",
                                    mediaIndex: 0, partIndex: 0)
    #expect(v(queryItems(noOffset.startM3U8URL()), "offset") == nil)
}

@Test func decisionAndStartShareTheSameCoreParams() {
    let req = TranscodeRequest(server: server, token: "tok", identity: id,
                               metadataKey: "/library/metadata/101",
                               maxVideoBitrateKbps: 8000, sessionID: "S",
                               mediaIndex: 1, partIndex: 2)
    let decision = queryItems(req.decisionURL())
    let start = queryItems(req.startM3U8URL())
    func v(_ items: [URLQueryItem], _ n: String) -> String? { items.first { $0.name == n }?.value }
    for name in ["path", "protocol", "maxVideoBitrate", "mediaIndex", "partIndex", "session", "X-Plex-Token"] {
        #expect(v(decision, name) == v(start, name))
    }
    // Only the decision URL carries hasMDE.
    #expect(decision.contains(URLQueryItem(name: "hasMDE", value: "1")))
    #expect(!start.contains(URLQueryItem(name: "hasMDE", value: "1")))
}

@Test func startURLCarriesProfileNameAndExtra() {
    let req = TranscodeRequest(server: server, token: "tok", identity: id,
                               metadataKey: "/library/metadata/101",
                               maxVideoBitrateKbps: 8000, sessionID: "S",
                               mediaIndex: 0, partIndex: 0)
    let q = queryItems(req.startM3U8URL())
    func v(_ n: String) -> String? { q.first { $0.name == n }?.value }
    // Must be a profile PMS actually has on disk; "visionOS" 400s. See TranscodeRequest.
    #expect(v("X-Plex-Client-Profile-Name") == "Safari")
    #expect(v("X-Plex-Client-Profile-Extra")?.contains("add-transcode-target") == true)
    #expect(v("videoQuality") == "100")
    #expect(v("directStream") == "1")
    #expect(v("audioBoost") == "100")
}

// MARK: - Direct-play probe (issue #7) — additive decision-only probe

@Test func directPlayProbeURLAdvertisesDirectPlay() {
    let req = TranscodeRequest(server: server, token: "tok", identity: id,
                               metadataKey: "/library/metadata/101",
                               maxVideoBitrateKbps: 8000, sessionID: "S",
                               mediaIndex: 0, partIndex: 0)
    let url = req.directPlayProbeDecisionURL()
    let q = queryItems(url)
    func v(_ n: String) -> String? { q.first { $0.name == n }?.value }
    #expect(url.path == "/video/:/transcode/universal/decision")
    #expect(v("directPlay") == "1")
    #expect(v("hasMDE") == "1")
    // Exactly one directPlay param survives the 0->1 override.
    #expect(q.filter { $0.name == "directPlay" }.count == 1)
}

@Test func directPlayProbeKeepsSafariProfile() {
    let req = TranscodeRequest(server: server, token: "tok", identity: id,
                               metadataKey: "/library/metadata/101",
                               maxVideoBitrateKbps: 8000, sessionID: "S",
                               mediaIndex: 0, partIndex: 0)
    let q = queryItems(req.directPlayProbeDecisionURL())
    func v(_ n: String) -> String? { q.first { $0.name == n }?.value }
    // An unknown profile name 400s — the probe must still use the server-known "Safari".
    #expect(v("X-Plex-Client-Profile-Name") == "Safari")
}

@Test func directPlayProbeProfileHasDirectPlayAndRequiredCap() {
    let req = TranscodeRequest(server: server, token: "tok", identity: id,
                               metadataKey: "/library/metadata/101",
                               maxVideoBitrateKbps: 8000, sessionID: "S",
                               mediaIndex: 0, partIndex: 0)
    let q = queryItems(req.directPlayProbeDecisionURL())
    func v(_ n: String) -> String? { q.first { $0.name == n }?.value }
    let extra = v("X-Plex-Client-Profile-Extra")
    #expect(extra?.contains("add-direct-play-profile") == true)
    #expect(extra?.contains("isRequired=true") == true)
    #expect(extra?.contains("8000") == true)
    // Exactly one -Extra param survives the swap.
    #expect(q.filter { $0.name == "X-Plex-Client-Profile-Extra" }.count == 1)
}

@Test func directPlayProbeShareCoreParamsWithDecision() {
    let req = TranscodeRequest(server: server, token: "tok", identity: id,
                               metadataKey: "/library/metadata/101",
                               maxVideoBitrateKbps: 8000, sessionID: "S",
                               mediaIndex: 1, partIndex: 2)
    let probe = queryItems(req.directPlayProbeDecisionURL())
    let decision = queryItems(req.decisionURL())
    func v(_ items: [URLQueryItem], _ n: String) -> String? { items.first { $0.name == n }?.value }
    // Everything except directPlay and -Extra is identical to the production decision URL.
    for name in ["path", "protocol", "maxVideoBitrate", "session", "X-Plex-Token",
                 "mediaIndex", "partIndex", "X-Plex-Client-Profile-Name", "hasMDE"] {
        #expect(v(probe, name) == v(decision, name))
    }
    // The two intentional deltas.
    #expect(v(probe, "directPlay") == "1")
    #expect(v(decision, "directPlay") == "0")
}

// MARK: - Regression guards (production path must stay byte-identical)

@Test func productionStartURLStillDirectPlayZeroAndUnchangedProfile() {
    let req = TranscodeRequest(server: server, token: "tok", identity: id,
                               metadataKey: "/library/metadata/101",
                               maxVideoBitrateKbps: 8000, sessionID: "S",
                               mediaIndex: 0, partIndex: 0)
    let q = queryItems(req.startM3U8URL())
    func v(_ n: String) -> String? { q.first { $0.name == n }?.value }
    #expect(v("directPlay") == "0")
    #expect(v("X-Plex-Client-Profile-Extra")?.contains("add-direct-play-profile") == false)
}

@Test func visionOSProfileUnchanged() {
    let extra = DeviceProfile.visionOS(maxVideoBitrateKbps: 8000).clientProfileExtra
    #expect(extra.contains("add-direct-play-profile") == false)
    #expect(extra.contains("isRequired=true") == false)
}

// MARK: - DecisionResponse / Decision

@Test func decodesTranscodeDecision() throws {
    let json = """
    {"MediaContainer":{"generalDecisionCode":1001,"generalDecisionText":"Transcoding"}}
    """.data(using: .utf8)!
    let r = try JSONDecoder().decode(DecisionResponse.self, from: json)
    #expect(r.generalDecisionCode == 1001)
    #expect(r.generalDecisionText == "Transcoding")
    #expect(r.decision == .transcode)
}

@Test func decodesDirectPlayDecision() throws {
    let json = """
    {"MediaContainer":{"generalDecisionCode":1000,"generalDecisionText":"Direct Play"}}
    """.data(using: .utf8)!
    let r = try JSONDecoder().decode(DecisionResponse.self, from: json)
    #expect(r.decision == .directPlay)
}

@Test func mapsUnknownDecisionCode() {
    #expect(Decision(generalDecisionCode: 2000) == .unsupported(code: 2000))
}

@Test func missingDecisionCodeFallsBackToUnsupported() throws {
    let json = """
    {"MediaContainer":{"generalDecisionText":"Unknown"}}
    """.data(using: .utf8)!
    let r = try JSONDecoder().decode(DecisionResponse.self, from: json)
    #expect(r.generalDecisionCode == nil)
    #expect(r.decision == .unsupported(code: -1))
}
