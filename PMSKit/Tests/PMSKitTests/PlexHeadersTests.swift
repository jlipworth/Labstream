import Testing
@testable import PMSKit

@Test func headersOmitTokenWhenNil() {
    let id = ClientIdentity(clientIdentifier: "ABC-123", product: "p", version: "1", deviceName: "d")
    let h = PlexHeaders.standard(identity: id, token: nil)
    #expect(h["X-Plex-Token"] == nil)
}
