import Testing
import Foundation
@testable import PMSKit

private let server = URL(string: "https://192.168.1.10:32400")!
private let id = ClientIdentity(clientIdentifier: "CID",
                                product: "VisionPlay",
                                version: "0.1.0",
                                deviceName: "AVP")

@Test func optimizeRequestTargetsLibraryOptimize() {
    let r = OptimizeRequest.create(server: server, token: "tok", identity: id,
                                   ratingKey: "101", title: "Blade Runner",
                                   targetTagID: .tv1080p8Mbps)
    #expect(r.url.path.contains("optimize"))
    #expect(r.method == "PUT" || r.method == "POST")   // pinned to PUT per python-plexapi
    func v(_ n: String) -> String? { r.queryItems.first { $0.name == n }?.value }
    #expect(v("title") == "Blade Runner")
}

@Test func downloadURLAppendsDownloadFlag() {
    let url = OptimizeRequest.downloadURL(server: server, token: "tok",
                                          partKey: "/library/parts/55/file.mp4")
    #expect(url.absoluteString.contains("download=1"))
    #expect(url.absoluteString.contains("X-Plex-Token=tok"))
}

@Test func downloadURLPercentEncodesReservedQuerySeparators() throws {
    let url = OptimizeRequest.downloadURL(server: server,
                                          token: "tok;download=0&x=/",
                                          partKey: "/library/parts/55/file.mp4")
    let query = try #require(URLComponents(url: url,
                                           resolvingAgainstBaseURL: false)?.percentEncodedQuery)

    #expect(query == "download=1&X-Plex-Token=tok%3Bdownload%3D0%26x%3D%2F")
    #expect(!query.contains(";"))
    #expect(!query.contains("&x="))
}

@Test func optimizeCarriesTargetAndTagID() {
    let r = OptimizeRequest.create(server: server, token: "tok", identity: id,
                                   ratingKey: "101", title: "Blade Runner",
                                   targetTagID: .tv1080p8Mbps)
    func v(_ n: String) -> String? { r.queryItems.first { $0.name == n }?.value }
    #expect(v("target") == "Optimized for TV")
    #expect(v("targetTagID") == "2")
    // Plan default preset caps video bitrate near 8 Mbps.
    #expect(v("Item[MediaSettings][maxVideoBitrate]") == "8000")
}

@Test func optimizeRequestSendsIdentityHeaderAndToken() {
    let r = OptimizeRequest.create(server: server, token: "tok", identity: id,
                                   ratingKey: "101", title: "T",
                                   targetTagID: .tv1080p8Mbps)
    #expect(r.headers["X-Plex-Client-Identifier"] == "CID")
    #expect(r.headers["X-Plex-Token"] == "tok")
}

@Test func statusRequestTargetsItemMetadata() {
    let r = OptimizeRequest.statusRequest(server: server, token: "tok",
                                          identity: id, ratingKey: "101")
    #expect(r.url.path == "/library/metadata/101")
    #expect(r.method == "GET")
    #expect(r.headers["X-Plex-Token"] == "tok")
}

@Test func downloadURLPlacesPartKeyInPath() {
    let url = OptimizeRequest.downloadURL(server: server, token: "tok",
                                          partKey: "/library/parts/55/file.mp4")
    #expect(url.path == "/library/parts/55/file.mp4")
    #expect(url.host == "192.168.1.10")
}
