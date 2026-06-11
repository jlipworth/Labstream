import Testing
import Foundation
@testable import PMSKit

private let id = ClientIdentity(clientIdentifier: "CID", product: "VisionPlex", version: "0.1.0", deviceName: "AVP")

@Test func createPinRequest() {
    let r = PinAuth.createPinRequest(identity: id)
    #expect(r.url.absoluteString == "https://plex.tv/api/v2/pins")
    #expect(r.method == "POST")
    #expect(r.queryItems.contains(URLQueryItem(name: "strong", value: "true")))
    #expect(r.headers["X-Plex-Client-Identifier"] == "CID")
}

@Test func createPinRequestNonStrongForLinkCode() {
    let r = PinAuth.createPinRequest(identity: id, strong: false)
    #expect(r.url.absoluteString == "https://plex.tv/api/v2/pins")
    #expect(r.method == "POST")
    #expect(r.queryItems.contains(URLQueryItem(name: "strong", value: "false")))
}

@Test func authAppURLEmbedsCodeAndClient() {
    let url = PinAuth.authAppURL(code: "WXYZ", identity: id)
    let s = url.absoluteString
    #expect(s.hasPrefix("https://app.plex.tv/auth#?"))
    #expect(s.contains("clientID=CID"))
    #expect(s.contains("code=WXYZ"))
}

@Test func authAppURLEncodesFragmentValues() {
    let unsafe = ClientIdentity(clientIdentifier: "CID&bad=1",
                                product: "plex avp/app",
                                version: "0.1.0",
                                deviceName: "AVP")
    let url = PinAuth.authAppURL(code: "W X&Y=Z", identity: unsafe)
    let s = url.absoluteString
    #expect(s.hasPrefix("https://app.plex.tv/auth#?"))
    #expect(s.contains("clientID=CID%26bad%3D1"))
    #expect(s.contains("code=W%20X%26Y%3DZ"))
    #expect(s.contains("context%5Bdevice%5D%5Bproduct%5D=plex%20avp%2Fapp"))
}

@Test func pollPinRequestTargetsPinID() {
    let r = PinAuth.pollPinRequest(pinID: 42, identity: id)
    #expect(r.url.absoluteString == "https://plex.tv/api/v2/pins/42")
    #expect(r.method == "GET")
}

@Test func decodesPinResponse() throws {
    let json = """
    {"id":42,"code":"WXYZ","authToken":null}
    """.data(using: .utf8)!
    let p = try JSONDecoder().decode(PinResponse.self, from: json)
    #expect(p.id == 42)
    #expect(p.code == "WXYZ")
    #expect(p.authToken == nil)
}

@Test func decodesPinPollResponseWithToken() throws {
    let json = """
    {"id":42,"code":"WXYZ","authToken":"tok-123"}
    """.data(using: .utf8)!
    let p = try JSONDecoder().decode(PinPollResponse.self, from: json)
    #expect(p.id == 42)
    #expect(p.authToken == "tok-123")
}
