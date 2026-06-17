import Testing
import Foundation
@testable import PMSKit

private let id = ClientIdentity(clientIdentifier: "CID", product: "VisionPlex", version: "0.1.0", deviceName: "AVP")

@Test func plexAccountProfileRequestShape() {
    let r = PlexAccount.profileRequest(token: "tok", identity: id)
    #expect(r.url.absoluteString == "https://plex.tv/api/v2/user")
    #expect(r.method == "GET")
    #expect(r.headers["X-Plex-Token"] == "tok")
    #expect(r.headers["Accept"] == "application/json")
}

@Test func plexAccountProfileDecodesDisplayMetadataOnly() throws {
    let json = """
    {
      "id": 123,
      "uuid": "user-uuid",
      "username": "plexuser",
      "title": "Plex User",
      "email": "plex@example.invalid",
      "authToken": "secret-token"
    }
    """.data(using: .utf8)!

    let profile = try JSONDecoder().decode(PlexAccountProfile.self, from: json)
    #expect(profile.username == "plexuser")
    #expect(profile.email == "plex@example.invalid")
    #expect(profile.title == "Plex User")
    #expect(profile.displayName == "Plex User")
}

@Test func plexAccountProfileDisplayNameFallsBack() {
    #expect(PlexAccountProfile(username: "plexuser").displayName == "plexuser")
    #expect(PlexAccountProfile(email: "plex@example.invalid").displayName == "plex@example.invalid")
    #expect(PlexAccountProfile().displayName == nil)
}
