import Foundation
import Testing
@testable import PMSKit

struct EmbyTrickPlayTests {
    private let server = URL(string: "https://emby.example/base")!
    private let identity = EmbyClientIdentity(
        client: "Labstream", device: "Test", deviceId: "device-id", version: "1.0")

    @Test func thumbnailSetDecodesSortsAndSelectsFrames() throws {
        let data = Data(#"""
        {
          "AspectRatio": 1.7777778,
          "Thumbnails": [
            {"PositionTicks": 200000000, "ImageTag": "later"},
            {"PositionTicks": 0, "ImageTag": "first"},
            {"PositionTicks": 100000000, "ImageTag": ""}
          ]
        }
        """#.utf8)

        let set = try EmbyThumbnailSetInfo.decode(from: data)

        #expect(set.aspectRatio == 1.7777778)
        #expect(set.thumbnails.map(\.imageTag) == ["first", "later"])
        #expect(set.thumbnail(nearMs: -1)?.imageTag == "first")
        #expect(set.thumbnail(nearMs: 19_999)?.imageTag == "first")
        #expect(set.thumbnail(nearMs: 20_000)?.imageTag == "later")
    }

    @Test func thumbnailSetMissingArrayDecodesAsUnavailable() throws {
        let set = try EmbyThumbnailSetInfo.decode(from: Data(#"{"AspectRatio":null}"#.utf8))
        #expect(set.thumbnails.isEmpty)
        #expect(set.thumbnail(nearMs: 0) == nil)
    }

    @Test func thumbnailSetRequestCarriesSelectedSourceAndCanonicalAuth() throws {
        let request = try EmbyTrickPlayRequest.thumbnailSet(
            server: server, token: "secret", identity: identity, userId: "user-id",
            itemId: "item-id", mediaSourceId: "selected-source")

        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "secret")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Emby ") == true)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.url?.path == "/base/Items/item-id/ThumbnailSet")
        #expect(query(request)["Width"] == "320")
        #expect(query(request)["MediaSourceId"] == "selected-source")
    }

    @Test func thumbnailImageRequestCarriesTagPositionSourceAndImageAccept() throws {
        let frame = EmbyThumbnailInfo(positionTicks: 123_450_000, imageTag: "tag/value")
        let request = try EmbyTrickPlayRequest.thumbnailImage(
            server: server, token: "secret", identity: identity, userId: "user-id",
            itemId: "item-id", mediaSourceId: "selected-source", thumbnail: frame, width: 480)

        #expect(request.url?.path == "/base/Items/item-id/Images/Thumbnail")
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "secret")
        #expect(request.value(forHTTPHeaderField: "Accept") == "image/*")
        #expect(query(request)["tag"] == "tag/value")
        #expect(query(request)["PositionTicks"] == "123450000")
        #expect(query(request)["MediaSourceId"] == "selected-source")
        #expect(query(request)["maxWidth"] == "480")
    }

    @Test func bifRequestCarriesSelectedSourceAndBinaryAccept() throws {
        let request = try EmbyTrickPlayRequest.bifIndex(
            server: server, token: "secret", identity: identity, userId: "user-id",
            itemId: "item-id", mediaSourceId: "selected-source")

        #expect(request.url?.path == "/base/Videos/item-id/index.bif")
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "secret")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/octet-stream")
        #expect(query(request)["Width"] == "320")
        #expect(query(request)["MediaSourceId"] == "selected-source")
    }

    private func query(_ request: URLRequest) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(
            url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .compactMap { item in item.value.map { (item.name, $0) } })
    }
}
