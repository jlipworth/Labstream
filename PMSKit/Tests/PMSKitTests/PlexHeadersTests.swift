import Testing
@testable import PMSKit

@Test func headersIncludeRequiredPlexFields() {
    let id = ClientIdentity(clientIdentifier: "ABC-123",
                            product: "VisionPlex",
                            version: "0.1.0",
                            deviceName: "Vision Pro")
    let h = PlexHeaders.standard(identity: id, token: "tok")
    #expect(h["X-Plex-Client-Identifier"] == "ABC-123")
    #expect(h["X-Plex-Product"] == "VisionPlex")
    #expect(h["X-Plex-Version"] == "0.1.0")
    #expect(h["X-Plex-Platform"] == "visionOS")
    #expect(h["X-Plex-Device-Name"] == "Vision Pro")
    #expect(h["X-Plex-Token"] == "tok")
    #expect(h["Accept"] == "application/json")
}

@Test func headersOmitTokenWhenNil() {
    let id = ClientIdentity(clientIdentifier: "ABC-123", product: "p", version: "1", deviceName: "d")
    let h = PlexHeaders.standard(identity: id, token: nil)
    #expect(h["X-Plex-Token"] == nil)
}
