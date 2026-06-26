import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PMSKit

@Suite("MediaBrowser poster request")
struct MediaBrowserPosterRequestTests {
    private let jellyfinServer = TestFixtures.jellyfinImageServer
    private let embyServer = TestFixtures.embyServer
    private let jellyfinIdentity = TestFixtures.jellyfinIdentity
    private let embyIdentity = TestFixtures.embyIdentity

    // MARK: - Synthetic ref parsing

    @Test func parsesJellyfinPrimaryRef() throws {
        let parsed = try #require(MediaBrowserSyntheticImageRef.parse(
            "jellyfin://item/abc123/Primary?tag=tag-1", scheme: "jellyfin"))
        #expect(parsed.itemId == "abc123")
        #expect(parsed.type == .primary)
        #expect(parsed.tag == "tag-1")
    }

    @Test func parsesEmbyBackdropRef() throws {
        let parsed = try #require(MediaBrowserSyntheticImageRef.parse(
            "emby://item/xyz/Backdrop?tag=bd", scheme: "emby"))
        #expect(parsed.itemId == "xyz")
        #expect(parsed.type == .backdrop)
        #expect(parsed.tag == "bd")
    }

    @Test func parsesRefWithoutTag() throws {
        let parsed = try #require(MediaBrowserSyntheticImageRef.parse(
            "jellyfin://item/abc123/Primary", scheme: "jellyfin"))
        #expect(parsed.tag == nil)
    }

    @Test func rejectsWrongScheme() {
        #expect(MediaBrowserSyntheticImageRef.parse(
            "emby://item/abc/Primary?tag=t", scheme: "jellyfin") == nil)
    }

    @Test func rejectsPlexPath() {
        // A bare Plex thumb path must not be misparsed as a synthetic MediaBrowser ref.
        #expect(MediaBrowserSyntheticImageRef.parse(
            "/library/metadata/123/thumb/456", scheme: "jellyfin") == nil)
    }

    @Test func rejectsEmptyAndNil() {
        #expect(MediaBrowserSyntheticImageRef.parse(nil, scheme: "jellyfin") == nil)
        #expect(MediaBrowserSyntheticImageRef.parse("", scheme: "jellyfin") == nil)
    }

    @Test func rejectsUnknownImageType() {
        #expect(MediaBrowserSyntheticImageRef.parse(
            "jellyfin://item/abc/Bogus?tag=t", scheme: "jellyfin") == nil)
    }

    // MARK: - Jellyfin poster request

    @Test func jellyfinPosterRequestBuildsAuthenticatedURL() throws {
        let req = try #require(try JellyfinLibrary.posterRequest(
            syntheticRef: "jellyfin://item/item-1/Primary?tag=tag-1",
            server: jellyfinServer, token: "token-abc", identity: jellyfinIdentity))
        let url = try #require(req.url)
        #expect(url.host == "jf.example.test")
        #expect(url.path == "/jellyfin/Items/item-1/Images/Primary")
        let q = try queryMap(req)
        #expect(q["tag"] == "tag-1")
        #expect(q["width"] == "400")
        #expect(q["height"] == "600")
        // Auth header present, carries identity + token; token NOT in the URL.
        let auth = try assertAuthHeaderContainsTokenNotInURL(req, token: "token-abc")
        #expect(auth.hasPrefix("MediaBrowser "))
        #expect(auth.contains("DeviceId=\"device-123\""))
    }

    @Test func jellyfinPosterRequestReturnsNilForEmbyRef() throws {
        #expect(try JellyfinLibrary.posterRequest(
            syntheticRef: "emby://item/item-1/Primary?tag=t",
            server: jellyfinServer, token: "t", identity: jellyfinIdentity) == nil)
    }

    @Test func jellyfinPosterRequestReturnsNilForNilRef() throws {
        #expect(try JellyfinLibrary.posterRequest(
            syntheticRef: nil,
            server: jellyfinServer, token: "t", identity: jellyfinIdentity) == nil)
    }

    // MARK: - Emby poster request

    @Test func embyPosterRequestBuildsAuthenticatedURLWithUserId() throws {
        let req = try #require(try EmbyLibrary.posterRequest(
            syntheticRef: "emby://item/item-1/Primary?tag=tag-xyz",
            server: embyServer, token: "token-abc", identity: embyIdentity, userId: "user-9"))
        let url = try #require(req.url)
        #expect(url.host == "emby.example.test")
        #expect(url.path == "/emby/Items/item-1/Images/Primary")
        let q = try queryMap(req)
        #expect(q["tag"] == "tag-xyz")
        #expect(q["width"] == "400")
        #expect(q["height"] == "600")
        // Emby auth header present, carries UserId + Token; token NOT in the URL.
        let auth = try assertAuthHeaderContainsTokenNotInURL(req, token: "token-abc")
        #expect(auth.hasPrefix("Emby "))
        #expect(auth.contains("UserId=\"user-9\""))
        #expect(!url.absoluteString.contains("user-9"))
    }

    @Test func embyPosterRequestUsesBackdropFallback() throws {
        let req = try #require(try EmbyLibrary.posterRequest(
            syntheticRef: "emby://item/item-1/Backdrop?tag=bd",
            server: embyServer, token: "t", identity: embyIdentity, userId: "user-9"))
        let url = try #require(req.url)
        #expect(url.path == "/emby/Items/item-1/Images/Backdrop")
    }

    @Test func embyPosterRequestReturnsNilForJellyfinRef() throws {
        #expect(try EmbyLibrary.posterRequest(
            syntheticRef: "jellyfin://item/item-1/Primary?tag=t",
            server: embyServer, token: "t", identity: embyIdentity, userId: "user-9") == nil)
    }
}
