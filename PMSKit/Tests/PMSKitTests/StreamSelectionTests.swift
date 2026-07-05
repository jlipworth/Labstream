import Testing
import Foundation
@testable import PMSKit

private let server = URL(string: "https://192.0.2.10:32400")!
private let id = ClientIdentity(clientIdentifier: "CID", product: "Labstream", version: "0.1.0", deviceName: "AVP")

@Test func audioStreamSelectionShape() {
    let r = StreamSelectionRequest.selectAudioStream(server: server, token: "tok", identity: id,
                                                     partID: 555, audioStreamID: 9876)
    #expect(r.url.path == "/library/parts/555")
    #expect(r.method == "PUT")
    func v(_ n: String) -> String? { r.queryItems.first { $0.name == n }?.value }
    #expect(v("audioStreamID") == "9876")
    #expect(v("allParts") == "1")
    #expect(v("X-Plex-Token") == "tok")
    #expect(r.headers["X-Plex-Token"] == "tok")
    #expect(v("X-Plex-Client-Identifier") == "CID")
}

@Test func subtitleStreamSelectionShape() {
    let r = StreamSelectionRequest.selectSubtitleStream(server: server, token: "tok", identity: id,
                                                        partID: 555, subtitleStreamID: 0)
    #expect(r.url.path == "/library/parts/555")
    #expect(r.method == "PUT")
    func v(_ n: String) -> String? { r.queryItems.first { $0.name == n }?.value }
    #expect(v("subtitleStreamID") == "0")   // 0 = subtitles off
    #expect(v("allParts") == "1")
}
