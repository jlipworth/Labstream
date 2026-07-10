import Foundation
import Testing
@testable import PMSKit

@Suite("Plex photo transcode URL")
struct PlexPhotoTranscodeTests {
    private let server = URL(string: "https://plex.example.test:32400")!

    @Test("Absolute and relative artwork paths remain intact in the url query item")
    func artworkPathForms() throws {
        let cases = [
            "/library/metadata/42/thumb/1000",
            "library/metadata/42/thumb/1000",
        ]

        for imagePath in cases {
            let url = try #require(PlexPhotoTranscode.url(server: server,
                                                          token: "token",
                                                          imagePath: imagePath,
                                                          width: 400,
                                                          height: 600))

            #expect(try queryMap(url)["url"] == imagePath,
                    "Artwork path form changed for \(imagePath)")
        }
    }

    @Test("Artwork paths with reserved characters and an existing query are one escaped value")
    func escapingAndExistingImageQuery() throws {
        let imagePath = "/library/metadata/42/thumb/1000?title=A; B/C&lang=en US"
        let url = try #require(PlexPhotoTranscode.url(server: server,
                                                      token: "tok/en; value",
                                                      imagePath: imagePath,
                                                      width: 640,
                                                      height: 360))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(components.path == "/photo/:/transcode")
        #expect(components.percentEncodedQuery ==
                "url=%2Flibrary%2Fmetadata%2F42%2Fthumb%2F1000%3Ftitle%3DA%3B%20B%2FC%26lang%3Den%20US&width=640&height=360&minSize=1&upscale=1&X-Plex-Token=tok%2Fen%3B%20value")
        #expect(try queryMap(url)["url"] == imagePath)
        #expect(try queryMap(url)["X-Plex-Token"] == "tok/en; value")
    }

    @Test("Dimensions, resize flags, and token use the production contract")
    func productionQueryContract() throws {
        let url = try #require(PlexPhotoTranscode.url(server: server,
                                                      token: "secret-token",
                                                      imagePath: "/library/metadata/7/art",
                                                      width: 1_920,
                                                      height: 1_080))
        let query = try queryMap(url)

        #expect(query == [
            "url": "/library/metadata/7/art",
            "width": "1920",
            "height": "1080",
            "minSize": "1",
            "upscale": "1",
            "X-Plex-Token": "secret-token",
        ])
    }

    @Test("A stale query on the server base does not leak into the transcode request")
    func replacesExistingServerQuery() throws {
        let serverWithQuery = URL(string: "https://plex.example.test:32400/plex?stale=value")!
        let url = try #require(PlexPhotoTranscode.url(server: serverWithQuery,
                                                      token: "token",
                                                      imagePath: "/art",
                                                      width: 100,
                                                      height: 200))

        #expect(url.path == "/plex/photo/:/transcode")
        #expect(try queryMap(url)["stale"] == nil)
        #expect(try queryMap(url)["url"] == "/art")
    }

    @Test("Invalid request inputs are rejected")
    func invalidInput() throws {
        let cases: [(server: URL, imagePath: String, width: Int, height: Int)] = [
            (URL(fileURLWithPath: "/tmp/not-a-plex-server"), "/art", 100, 200),
            (try #require(URL(string: "https://:32400")), "/art", 100, 200),
            (server, "", 100, 200),
            (server, "/art", 0, 200),
            (server, "/art", 100, -1),
        ]

        for value in cases {
            #expect(PlexPhotoTranscode.url(server: value.server,
                                           token: "token",
                                           imagePath: value.imagePath,
                                           width: value.width,
                                           height: value.height) == nil)
        }
    }
}
