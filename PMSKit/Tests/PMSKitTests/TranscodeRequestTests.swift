import Testing
import Foundation
@testable import PMSKit

private let server = URL(string: "https://192.168.1.10:32400")!
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
    #expect(v("maxVideoResolution") == "1920x1080")
    #expect(v("maxAudioBitrate") == "640")
    #expect(v("directPlay") == "0")
    #expect(v("path") == "/library/metadata/101")
    #expect(v("session") == "SESSION-1")
    #expect(v("X-Plex-Token") == "tok")            // token as QUERY param
    #expect(v("partIndex") == "0")
}


@Test func qualityLadderAddsResolutionAndAudioCaps() {
    let low = TranscodeRequest(server: server, token: "tok", identity: id,
                               metadataKey: "/library/metadata/101",
                               maxVideoBitrateKbps: 3000,
                               sessionID: "S", mediaIndex: 0, partIndex: 0)
    let lowQuery = queryItems(low.startM3U8URL())
    func lowValue(_ n: String) -> String? { lowQuery.first { $0.name == n }?.value }
    #expect(lowValue("maxVideoResolution") == "1280x720")
    #expect(lowValue("maxAudioBitrate") == "256")

    let maximum = TranscodeRequest(server: server, token: "tok", identity: id,
                                   metadataKey: "/library/metadata/101",
                                   maxVideoBitrateKbps: 200_000,
                                   sessionID: "S", mediaIndex: 0, partIndex: 0)
    let maximumNames = Set(queryItems(maximum.startM3U8URL()).map(\.name))
    #expect(!maximumNames.contains("maxVideoResolution"))
    #expect(!maximumNames.contains("maxAudioBitrate"))
}

@Test func startURLPercentEncodesReservedQuerySeparators() throws {
    let unsafeIdentity = ClientIdentity(clientIdentifier: "CID;bad=1",
                                        product: "VisionPlex",
                                        version: "0.1.0",
                                        deviceName: "AVP")
    let req = TranscodeRequest(server: server,
                               token: "tok;download=0&x=/",
                               identity: unsafeIdentity,
                               metadataKey: "/library/metadata/101;bad=true",
                               maxVideoBitrateKbps: 8000,
                               sessionID: "SESSION;evil=1",
                               mediaIndex: 0,
                               partIndex: 0)
    let query = try #require(URLComponents(url: req.startM3U8URL(),
                                           resolvingAgainstBaseURL: false)?.percentEncodedQuery)

    #expect(query.contains("path=%2Flibrary%2Fmetadata%2F101%3Bbad%3Dtrue"))
    #expect(query.contains("session=SESSION%3Bevil%3D1"))
    #expect(query.contains("X-Plex-Token=tok%3Bdownload%3D0%26x%3D%2F"))
    #expect(query.contains("X-Plex-Client-Identifier=CID%3Bbad%3D1"))
    #expect(!query.contains(";"))
    #expect(!query.contains("&x="))
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
    let p = DeviceProfile.visionOS(maxVideoBitrateKbps: 8000, maxAudioBitrateKbps: 640)
    #expect(p.clientProfileExtra.contains("add-transcode-target"))
    #expect(p.clientProfileExtra.contains("protocol=hls"))
    #expect(p.clientProfileExtra.contains("name=video.bitrate&value=8000"))
    #expect(p.clientProfileExtra.contains("name=audio.bitrate&value=640"))
}

@Test func stopRequestTargetsUniversalStopWithSession() {
    let req = TranscodeRequest.stop(server: server, token: "tok", identity: id,
                                    sessionID: "SESSION-1")
    #expect(req.url.path == "/video/:/transcode/universal/stop")
    #expect(req.method == "GET")
    func v(_ n: String) -> String? { req.queryItems.first { $0.name == n }?.value }
    #expect(v("session") == "SESSION-1")
    #expect(v("X-Plex-Token") == "tok")
    #expect(v("X-Plex-Client-Identifier") == "CID")
}

// MARK: - Decision requests MUST ask for JSON (regression: PMS defaults to XML, which
// made every decision call fail to decode — "Unexpected character '<'" — so the player
// silently fell through to start.m3u8 and Direct Stream could never confirm a copy).

@Test func decisionRequestAsksForJSON() {
    let req = TranscodeRequest(server: server, token: "tok", identity: id,
                               metadataKey: "/library/metadata/101",
                               maxVideoBitrateKbps: 8000,
                               sessionID: "SESSION-1",
                               mediaIndex: 0, partIndex: 0).decisionRequest()
    #expect(req.url.path == "/video/:/transcode/universal/decision")
    #expect(req.method == "GET")
    #expect(req.headers["Accept"] == "application/json")
}

@Test func directPlayProbeRequestAsksForJSON() {
    let req = TranscodeRequest(server: server, token: "tok", identity: id,
                               metadataKey: "/library/metadata/101",
                               maxVideoBitrateKbps: 8000,
                               sessionID: "SESSION-1",
                               mediaIndex: 0, partIndex: 0).directPlayProbeRequest()
    #expect(req.url.path == "/video/:/transcode/universal/decision")
    #expect(req.method == "GET")
    #expect(req.headers["Accept"] == "application/json")
    // Still the direct-play probe (directPlay=1) — the header fix must not lose the delta.
    let q = URLComponents(url: req.url, resolvingAgainstBaseURL: false)!.queryItems ?? []
    #expect(q.first { $0.name == "directPlay" }?.value == "1")
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

@Test func resumeOffsetIsSentToPMSOnStream() {
    let req = TranscodeRequest(server: server, token: "tok", identity: id,
                               metadataKey: "/library/metadata/101",
                               maxVideoBitrateKbps: 8000, sessionID: "S",
                               mediaIndex: 0, partIndex: 0,
                               startOffsetSeconds: 1860)
    func v(_ items: [URLQueryItem], _ n: String) -> String? { items.first { $0.name == n }?.value }
    // Streaming carries the resume offset (so PMS primes the transcoder + emits EXT-X-START).
    #expect(v(queryItems(req.startM3U8URL()), "offset") == "1860")
    #expect(v(queryItems(req.decisionURL()), "offset") == "1860")
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
    #expect(v("X-Plex-Client-Profile-Name") == "Generic")
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

@Test func directPlayProbeKeepsGenericProfile() {
    let req = TranscodeRequest(server: server, token: "tok", identity: id,
                               metadataKey: "/library/metadata/101",
                               maxVideoBitrateKbps: 8000, sessionID: "S",
                               mediaIndex: 0, partIndex: 0)
    let q = queryItems(req.directPlayProbeDecisionURL())
    func v(_ n: String) -> String? { q.first { $0.name == n }?.value }
    // An unknown profile name 400s — the probe must still use the server-known "Generic".
    #expect(v("X-Plex-Client-Profile-Name") == "Generic")
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

// MARK: - Direct-play start (issue #7 Step 3) — the playback URL the probe gates

@Test func directPlayStartURLMirrorsProbeParamsOnStartPath() {
    let req = TranscodeRequest(server: server, token: "tok", identity: id,
                               metadataKey: "/library/metadata/101",
                               maxVideoBitrateKbps: 8000, sessionID: "S",
                               mediaIndex: 1, partIndex: 2)
    let start = queryItems(req.directPlayStartM3U8URL())
    let probe = queryItems(req.directPlayProbeDecisionURL())
    func v(_ items: [URLQueryItem], _ n: String) -> String? { items.first { $0.name == n }?.value }
    #expect(req.directPlayStartM3U8URL().path == "/video/:/transcode/universal/start.m3u8")
    // Decision/start consistency (research/15 risk #8): what PMS decided on is what
    // the player then requests — every param identical except hasMDE.
    for name in ["path", "protocol", "maxVideoBitrate", "session", "X-Plex-Token",
                 "mediaIndex", "partIndex", "directPlay", "directStream",
                 "X-Plex-Client-Profile-Name", "X-Plex-Client-Profile-Extra"] {
        #expect(v(start, name) == v(probe, name))
    }
    #expect(v(start, "directPlay") == "1")
    #expect(v(start, "hasMDE") == nil)
    #expect(v(start, "X-Plex-Client-Profile-Name") == "Generic")
    #expect(v(start, "X-Plex-Client-Profile-Extra")?.contains("add-direct-play-profile") == true)
    // Exactly one of each overridden param survives.
    #expect(start.filter { $0.name == "directPlay" }.count == 1)
    #expect(start.filter { $0.name == "X-Plex-Client-Profile-Extra" }.count == 1)
}

@Test func directPlayStartURLCarriesResumeOffset() {
    let req = TranscodeRequest(server: server, token: "tok", identity: id,
                               metadataKey: "/library/metadata/101",
                               maxVideoBitrateKbps: 8000, sessionID: "S",
                               mediaIndex: 0, partIndex: 0,
                               startOffsetSeconds: 1860)
    let q = queryItems(req.directPlayStartM3U8URL())
    #expect(q.first { $0.name == "offset" }?.value == "1860")
}

@Test func directPlayStartRequestCanPreflightActualPlaylist() {
    let req = TranscodeRequest(server: server, token: "tok", identity: id,
                               metadataKey: "/library/metadata/101",
                               maxVideoBitrateKbps: 8000, sessionID: "S",
                               mediaIndex: 0, partIndex: 0)
    let preflight = req.directPlayStartM3U8Request()
    #expect(preflight.url.path == req.directPlayStartM3U8URL().path)
    #expect(Set(queryItems(preflight.url)) == Set(queryItems(req.directPlayStartM3U8URL())))
    #expect(preflight.method == "GET")
    #expect(preflight.headers["Accept"]?.contains("application/json") == true)
    #expect(queryItems(preflight.url).first { $0.name == "directPlay" }?.value == "1")
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

// MARK: - DecisionResponse per-stream decisions (issue #7 Step 1)

@Test func decodesPerStreamDecisions() throws {
    // The reliable copy-vs-transcode signal lives on Media>Part>Stream (research/09 §3.2):
    // streamType 1 = video, 2 = audio; `decision` is "copy" / "transcode" / "direct play".
    let json = """
    {"MediaContainer":{
       "generalDecisionCode":1001,"generalDecisionText":"Conversion OK",
       "mdeDecisionText":"Convert to HLS, copy video, transcode audio",
       "Metadata":[{"Media":[{"Part":[{"decision":"transcode","Stream":[
         {"streamType":1,"decision":"copy"},
         {"streamType":2,"decision":"transcode"},
         {"streamType":3,"decision":"burn"}
       ]}]}]}]
    }}
    """.data(using: .utf8)!
    let r = try JSONDecoder().decode(DecisionResponse.self, from: json)
    #expect(r.videoDecision == "copy")
    #expect(r.audioDecision == "transcode")
    #expect(r.mdeDecisionText == "Convert to HLS, copy video, transcode audio")
    // Video is copied -> the expensive re-encode is saved.
    #expect(r.savesVideoEncode == true)
}

@Test func directPlayPerStreamDecisionAlsoSavesVideoEncode() throws {
    let json = """
    {"MediaContainer":{"generalDecisionCode":1000,
       "Metadata":[{"Media":[{"Part":[{"Stream":[
         {"streamType":1,"decision":"direct play"},
         {"streamType":2,"decision":"direct play"}
       ]}]}]}]
    }}
    """.data(using: .utf8)!
    let r = try JSONDecoder().decode(DecisionResponse.self, from: json)
    #expect(r.videoDecision == "direct play")
    #expect(r.savesVideoEncode == true)
}

@Test func transcodedVideoDoesNotSaveVideoEncode() throws {
    let json = """
    {"MediaContainer":{"generalDecisionCode":1001,
       "Metadata":[{"Media":[{"Part":[{"Stream":[
         {"streamType":1,"decision":"transcode"},
         {"streamType":2,"decision":"copy"}
       ]}]}]}]
    }}
    """.data(using: .utf8)!
    let r = try JSONDecoder().decode(DecisionResponse.self, from: json)
    #expect(r.videoDecision == "transcode")
    #expect(r.savesVideoEncode == false)
}

@Test func missingPerStreamDecisionsAreNilAndConservative() throws {
    // Older/odd servers may omit Metadata entirely — must decode, and the
    // convenience must answer NO (never claim a saved encode without evidence).
    let json = """
    {"MediaContainer":{"generalDecisionCode":1001,"generalDecisionText":"Transcoding"}}
    """.data(using: .utf8)!
    let r = try JSONDecoder().decode(DecisionResponse.self, from: json)
    #expect(r.videoDecision == nil)
    #expect(r.audioDecision == nil)
    #expect(r.savesVideoEncode == false)
}

// MARK: - Part-level / MDE direct-play verdict (issue #7, captured from LIVE PMS)
//
// A real directPlay=1 probe against live PMS expresses a direct-play verdict via
// `mdeDecisionCode=1000` and the Part-level `decision="directplay"`, leaving
// `generalDecisionCode` AND the per-stream decisions nil. The original
// `savesVideoEncode` only read the per-stream video decision, so it never fired and
// Direct Stream (#7) could not engage. These cases pin the structured signals (codes /
// Part decision), NOT the fragile English `mdeDecisionText`.

@Test func directPlayViaPartAndMdeCodeSavesVideoEncode() throws {
    // Exact shape captured live for an HEVC title that direct-plays within the cap.
    let json = """
    {"MediaContainer":{"mdeDecisionCode":1000,"mdeDecisionText":"Direct play OK.",
       "Metadata":[{"Media":[{"Part":[{"decision":"directplay","Stream":[
         {"streamType":1},
         {"streamType":2}
       ]}]}]}]
    }}
    """.data(using: .utf8)!
    let r = try JSONDecoder().decode(DecisionResponse.self, from: json)
    #expect(r.generalDecisionCode == nil)
    #expect(r.mdeDecisionCode == 1000)
    #expect(r.partDecision == "directplay")
    #expect(r.videoDecision == nil)          // per-stream left nil on a full direct play
    #expect(r.savesVideoEncode == true)
}

@Test func partLevelCopySavesVideoEncodeEvenWithNilStreamDecisions() throws {
    // Remux (copy all streams into a new container): Part decision "copy", no re-encode.
    let json = """
    {"MediaContainer":{"generalDecisionCode":1001,
       "Metadata":[{"Media":[{"Part":[{"decision":"copy","Stream":[
         {"streamType":1},{"streamType":2}
       ]}]}]}]
    }}
    """.data(using: .utf8)!
    let r = try JSONDecoder().decode(DecisionResponse.self, from: json)
    #expect(r.partDecision == "copy")
    #expect(r.savesVideoEncode == true)
}

@Test func fullTranscodeDecisionDoesNotSave() throws {
    // Exact production-decision shape (directPlay=0): whole-file transcode, mde code absent.
    let json = """
    {"MediaContainer":{"generalDecisionCode":1001,
       "generalDecisionText":"Direct play not available; Conversion OK.",
       "Metadata":[{"Media":[{"Part":[{"decision":"transcode","Stream":[
         {"streamType":1,"decision":"transcode"},
         {"streamType":2,"decision":"transcode"}
       ]}]}]}]
    }}
    """.data(using: .utf8)!
    let r = try JSONDecoder().decode(DecisionResponse.self, from: json)
    #expect(r.mdeDecisionCode == nil)
    #expect(r.partDecision == "transcode")
    #expect(r.savesVideoEncode == false)
}
