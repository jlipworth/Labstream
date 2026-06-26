import Foundation
import Testing
@testable import PMSKit

@Suite("MediaBrowser URL origin policy")
struct MediaBrowserURLTests {
    @Test func acceptsSameOriginAbsoluteURLWithExplicitAndDefaultPorts() throws {
        let httpsServer = URL(string: "https://Jellyfin.Example.test/base")!
        let httpsURL = URL(string: "https://jellyfin.example.test:443/other/master.m3u8")!
        #expect(MediaBrowserURL.isSameOrigin(httpsURL, server: httpsServer))
        #expect(MediaBrowserURL.joinTrustedServerURL(server: httpsServer,
                                                    pathOrURLString: httpsURL.absoluteString) == httpsURL)

        let httpServer = URL(string: "http://emby.example.test:80/emby")!
        let httpURL = URL(string: "http://EMBY.example.test/videos/stream.mp4")!
        #expect(MediaBrowserURL.isSameOrigin(httpURL, server: httpServer))
        #expect(MediaBrowserURL.joinTrustedServerURL(server: httpServer,
                                                    pathOrURLString: httpURL.absoluteString) == httpURL)
    }

    @Test func rejectsAbsoluteURLWithDifferentHost() {
        let server = URL(string: "https://jellyfin.example.test/base")!
        let url = URL(string: "https://evil.example.test/Videos/movie/master.m3u8")!

        #expect(MediaBrowserURL.isSameOrigin(url, server: server) == false)
        #expect(MediaBrowserURL.joinTrustedServerURL(server: server,
                                                    pathOrURLString: url.absoluteString) == nil)
    }

    @Test func rejectsAbsoluteURLWithSameHostDifferentScheme() {
        let server = URL(string: "https://jellyfin.example.test/base")!
        let url = URL(string: "http://jellyfin.example.test/Videos/movie/master.m3u8")!

        #expect(MediaBrowserURL.isSameOrigin(url, server: server) == false)
        #expect(MediaBrowserURL.joinTrustedServerURL(server: server,
                                                    pathOrURLString: url.absoluteString) == nil)
    }

    @Test func rejectsAbsoluteURLWithSameHostDifferentPort() {
        let server = URL(string: "https://jellyfin.example.test/base")!
        let url = URL(string: "https://jellyfin.example.test:8443/Videos/movie/master.m3u8")!

        #expect(MediaBrowserURL.isSameOrigin(url, server: server) == false)
        #expect(MediaBrowserURL.joinTrustedServerURL(server: server,
                                                    pathOrURLString: url.absoluteString) == nil)
    }

    @Test func relativeJoinPreservesServerBasePath() throws {
        let server = URL(string: "https://emby.example.test/emby")!
        let url = try #require(MediaBrowserURL.joinTrustedServerURL(
            server: server,
            pathOrURLString: "/videos/movie-1/stream.mp4?MediaSourceId=source-1"))

        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(comps.scheme == "https")
        #expect(comps.host == "emby.example.test")
        #expect(comps.path == "/emby/videos/movie-1/stream.mp4")
        #expect(comps.query == "MediaSourceId=source-1")
    }
}
