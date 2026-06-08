import Testing
import Foundation
@testable import PlexKit

private let server = URL(string: "https://192.168.1.10:32400")!
private let id = ClientIdentity(clientIdentifier: "CID", product: "plex-avp-app", version: "0.1.0", deviceName: "AVP")

@Test func timelineCarriesStateAndOffset() {
    let r = TimelineRequest.timeline(server: server, token: "tok", identity: id,
                                     ratingKey: "101", key: "/library/metadata/101",
                                     state: .playing, timeMs: 120000, durationMs: 9540000)
    #expect(r.url.path == "/:/timeline")
    func v(_ n: String) -> String? { r.queryItems.first { $0.name == n }?.value }
    #expect(v("state") == "playing")
    #expect(v("time") == "120000")
    #expect(v("ratingKey") == "101")
    #expect(v("key") == "/library/metadata/101")   // key is a PATH here
}

@Test func scrobbleUsesRatingKeyNumber() {
    let r = TimelineRequest.scrobble(server: server, token: "tok", identity: id, ratingKey: "101")
    #expect(r.url.path == "/:/scrobble")
    #expect(r.queryItems.first { $0.name == "key" }?.value == "101")  // key is a NUMBER here
    #expect(r.queryItems.first { $0.name == "identifier" }?.value == "com.plexapp.plugins.library")
}

@Test func timelineDefaultsToLegacyGET() {
    let r = TimelineRequest.timeline(server: server, token: "tok", identity: id,
                                     ratingKey: "101", key: "/library/metadata/101",
                                     state: .paused, timeMs: 0, durationMs: 1)
    #expect(r.method == "GET")
}

@Test func timelineMethodKnobHonorsOfficialPOST() {
    let r = TimelineRequest.timeline(server: server, token: "tok", identity: id,
                                     ratingKey: "101", key: "/library/metadata/101",
                                     state: .stopped, timeMs: 0, durationMs: 1,
                                     method: "POST")
    #expect(r.method == "POST")
}

@Test func timelineCarriesDurationAndToken() {
    let r = TimelineRequest.timeline(server: server, token: "tok", identity: id,
                                     ratingKey: "101", key: "/library/metadata/101",
                                     state: .buffering, timeMs: 5, durationMs: 9540000)
    func v(_ n: String) -> String? { r.queryItems.first { $0.name == n }?.value }
    #expect(v("duration") == "9540000")
    #expect(v("X-Plex-Token") == "tok")
    #expect(r.headers["X-Plex-Token"] == "tok")
    #expect(v("X-Plex-Client-Identifier") == "CID")
}

@Test func scrobbleDefaultsToLegacyGETAndKnobFlipsToPUT() {
    let g = TimelineRequest.scrobble(server: server, token: "tok", identity: id, ratingKey: "101")
    #expect(g.method == "GET")
    let p = TimelineRequest.scrobble(server: server, token: "tok", identity: id, ratingKey: "101", method: "PUT")
    #expect(p.method == "PUT")
}

@Test func unscrobbleTargetsUnscrobblePathWithRatingKeyNumber() {
    let r = TimelineRequest.unscrobble(server: server, token: "tok", identity: id, ratingKey: "101")
    #expect(r.url.path == "/:/unscrobble")
    #expect(r.queryItems.first { $0.name == "key" }?.value == "101")
    #expect(r.queryItems.first { $0.name == "identifier" }?.value == "com.plexapp.plugins.library")
}

@Test func playQueueCreateShape() {
    let r = PlayQueue.createRequest(server: server, token: "tok", identity: id,
                                    machineIdentifier: "MACHINE-ABC", ratingKey: "101")
    #expect(r.url.path == "/playQueues")
    #expect(r.method == "POST")
    func v(_ n: String) -> String? { r.queryItems.first { $0.name == n }?.value }
    #expect(v("type") == "video")
    #expect(v("continuous") == "1")
    #expect(v("uri")?.contains("server://MACHINE-ABC") == true)
    #expect(v("uri")?.contains("/library/metadata/101") == true)
    #expect(v("X-Plex-Token") == "tok")
}

@Test func playQueueContinuousCanBeDisabled() {
    let r = PlayQueue.createRequest(server: server, token: "tok", identity: id,
                                    machineIdentifier: "M", ratingKey: "7", continuous: false)
    #expect(r.queryItems.first { $0.name == "continuous" }?.value == "0")
}
