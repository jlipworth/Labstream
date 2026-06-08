import Testing
import Foundation
@testable import PlexKit

private let server = URL(string: "https://192.0.2.10:32400")!
private let id = ClientIdentity(clientIdentifier: "CID", product: "plex-avp-app", version: "0.1.0", deviceName: "AVP")

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
    #expect(v("X-Plex-Client-Profile-Name") == "visionOS")
    #expect(v("X-Plex-Client-Profile-Extra")?.contains("add-transcode-target") == true)
    #expect(v("videoQuality") == "100")
    #expect(v("directStream") == "1")
    #expect(v("audioBoost") == "100")
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
