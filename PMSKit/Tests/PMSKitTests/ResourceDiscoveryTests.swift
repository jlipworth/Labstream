import Testing
import Foundation
@testable import PMSKit

private let id = ClientIdentity(clientIdentifier: "CID", product: "VisionPlex", version: "0.1.0", deviceName: "AVP")

@Test func resourcesRequestShape() {
    let r = ResourceDiscovery.resourcesRequest(token: "tok", identity: id)
    #expect(r.url.absoluteString == "https://clients.plex.tv/api/v2/resources")
    #expect(r.queryItems.contains(URLQueryItem(name: "includeHttps", value: "1")))
    #expect(r.headers["X-Plex-Token"] == "tok")
}

@Test func ranksLocalAboveRelay() {
    let conns = [
        PlexConnection(uri: "https://relay", local: false, relay: true),
        PlexConnection(uri: "https://192-168", local: true, relay: false),
    ]
    #expect(ResourceDiscovery.bestConnection(conns)?.uri == "https://192-168")
}

@Test func ranksNonRelayAboveRelayWhenNoLocal() {
    let conns = [
        PlexConnection(uri: "https://relay", local: false, relay: true),
        PlexConnection(uri: "https://remote", local: false, relay: false),
    ]
    #expect(ResourceDiscovery.bestConnection(conns)?.uri == "https://remote")
}

@Test func bestConnectionEmptyIsNil() {
    #expect(ResourceDiscovery.bestConnection([]) == nil)
}

@Test func decodesResourcesArray() throws {
    let json = """
    [
      {"name":"Home Server","clientIdentifier":"SRV-1","provides":"server","accessToken":"atok",
       "connections":[
         {"uri":"https://10-0-0-5.abc.plex.direct:32400","local":true,"relay":false},
         {"uri":"https://relay.plex.direct:443","local":false,"relay":true}
       ]}
    ]
    """.data(using: .utf8)!
    let resp = try JSONDecoder().decode(ResourcesResponse.self, from: json)
    #expect(resp.devices.count == 1)
    #expect(resp.devices[0].clientIdentifier == "SRV-1")
    #expect(resp.devices[0].connections.count == 2)
    let best = ResourceDiscovery.bestConnection(resp.devices[0].connections)
    #expect(best?.local == true)
}

@Test func decodesProductVersion() throws {
    let json = """
    [
      {"name":"Home Server","clientIdentifier":"SRV-1","provides":"server",
       "productVersion":"1.40.2.8395-c67dce28e",
       "connections":[{"uri":"https://192.0.2.10:32400","local":true,"relay":false}]}
    ]
    """.data(using: .utf8)!
    let resp = try JSONDecoder().decode(ResourcesResponse.self, from: json)
    #expect(resp.devices[0].productVersion == "1.40.2.8395-c67dce28e")
}

@Test func productVersionAbsentIsNil() throws {
    let json = """
    [{"name":"Old","clientIdentifier":"SRV-2","connections":[]}]
    """.data(using: .utf8)!
    let resp = try JSONDecoder().decode(ResourcesResponse.self, from: json)
    #expect(resp.devices[0].productVersion == nil)
}
