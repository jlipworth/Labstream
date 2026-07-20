import Foundation
import PMSKit
import XCTest
@testable import Labstream

final class EmbyTrickPlayThumbnailProviderTests: XCTestCase {
    override func tearDown() {
        TrickPlayURLProtocol.reset()
        super.tearDown()
    }

    func testMalformedBIFFallsBackToCoalescedSelectedSourcePositionImage() async throws {
        let image = onePixelPNG
        TrickPlayURLProtocol.configure { request in
            switch request.url!.path {
            case "/Items/item/ThumbnailSet":
                return (200, "application/json", #"{"Thumbnails":[{"PositionTicks":20000000,"ImageTag":"frame"}]}"#.data(using: .utf8)!)
            case "/Videos/item/index.bif":
                return (200, "application/octet-stream", Data("not-a-bif".utf8))
            case "/Items/item/Images/Thumbnail":
                return (200, "image/png", image)
            default:
                return (404, "application/json", Data([0]))
            }
        }
        let provider = try makeProvider(item: MediaItem(ratingKey: "item", title: "", type: "movie"))

        async let first = provider.thumbnail(nearMs: 2_000)
        async let second = provider.thumbnail(nearMs: 2_000)
        let results = await [first, second]

        XCTAssertEqual(results.compactMap { $0 }.count, 2)
        XCTAssertEqual(results.first??.timeMs, 2_000)
        XCTAssertEqual(TrickPlayURLProtocol.count(path: "/Items/item/ThumbnailSet"), 1)
        XCTAssertEqual(TrickPlayURLProtocol.count(path: "/Videos/item/index.bif"), 1)
        XCTAssertEqual(TrickPlayURLProtocol.count(path: "/Items/item/Images/Thumbnail"), 1)
        for request in TrickPlayURLProtocol.requests {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.first(where: { $0.name == "MediaSourceId" })?.value, "selected-source")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Emby-Token"), "token")
        }
    }

    func testParseableBIFWinsAndDoesNotRequestPositionOrChapterImage() async throws {
        TrickPlayURLProtocol.configure { request in
            switch request.url!.path {
            case "/Items/item/ThumbnailSet":
                return (200, "application/json", #"{"Thumbnails":[{"PositionTicks":0,"ImageTag":"frame"}]}"#.data(using: .utf8)!)
            case "/Videos/item/index.bif":
                return (200, "application/octet-stream", makeBIF(payload: Data("bif-frame".utf8)))
            default:
                return (500, "application/json", Data([0]))
            }
        }
        let chapter = Chapter(startTimeOffset: 0, thumb: "emby://item/item/Chapter/0?tag=c")
        let provider = try makeProvider(item: MediaItem(ratingKey: "item", title: "", type: "movie", chapters: [chapter]))

        let result = await provider.thumbnail(nearMs: 0)

        XCTAssertEqual(result?.imageData, Data("bif-frame".utf8))
        XCTAssertEqual(TrickPlayURLProtocol.count(path: "/Items/item/Images/Thumbnail"), 0)
        XCTAssertEqual(TrickPlayURLProtocol.count(path: "/Items/item/Images/Chapter/0"), 0)
    }

    func testUnavailableThumbnailSetFallsBackToExistingChapterProvider() async throws {
        let image = onePixelPNG
        TrickPlayURLProtocol.configure { request in
            switch request.url!.path {
            case "/Items/item/ThumbnailSet":
                return (200, "application/json", #"{"Thumbnails":[]}"#.data(using: .utf8)!)
            case "/Items/item/Images/Chapter/0":
                return (200, "image/png", image)
            default:
                return (404, "application/json", Data([0]))
            }
        }
        let chapter = Chapter(startTimeOffset: 5_000, thumb: "emby://item/item/Chapter/0?tag=c")
        let provider = try makeProvider(item: MediaItem(ratingKey: "item", title: "", type: "movie", chapters: [chapter]))

        let result = await provider.thumbnail(nearMs: 7_000)

        XCTAssertEqual(result?.timeMs, 5_000)
        XCTAssertEqual(result?.imageData, image)
        XCTAssertEqual(TrickPlayURLProtocol.count(path: "/Videos/item/index.bif"), 0)
    }

    func testCancelledRequestDoesNotStartPreviewWork() async throws {
        TrickPlayURLProtocol.configure { _ in (500, "application/json", Data([0])) }
        let provider = try makeProvider(item: MediaItem(ratingKey: "item", title: "", type: "movie"))
        let task = Task { await provider.thumbnail(nearMs: 0) }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertTrue(TrickPlayURLProtocol.requests.isEmpty)
    }

    func testOfflineMalformedBIFFallsBackToCachedChapterImage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bif = directory.appendingPathComponent("preview.emby.bif")
        let chapter = directory.appendingPathComponent("chapter.jpg")
        try Data("bad".utf8).write(to: bif)
        try onePixelPNG.write(to: chapter)
        let providers: [any TrickPlayThumbnailProviding] = [
            try XCTUnwrap(LocalBIFTrickPlayThumbnailProvider(bifURL: bif)),
            try XCTUnwrap(LocalEmbyChapterTrickPlayThumbnailProvider(
                chapters: [OfflineChapter(startTimeOffset: 4_000)],
                imageURLsByChapterIndex: [0: chapter]))
        ]

        let result = await HierarchicalTrickPlayThumbnailProvider(providers).thumbnail(nearMs: 5_000)

        XCTAssertEqual(result?.timeMs, 4_000)
        XCTAssertEqual(result?.imageData, onePixelPNG)
    }

    private func makeProvider(item: MediaItem) throws -> EmbyTrickPlayThumbnailProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TrickPlayURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let coordinator = SideAssetFetchCoordinator(
            policy: .init(maximumRequestStartsPerSecond: 10_000, maximumConcurrentRequests: 4))
        return try XCTUnwrap(EmbyTrickPlayThumbnailProvider(
            item: item, mediaSourceId: "selected-source", server: URL(string: "https://emby.invalid")!,
            token: "token", identity: EmbyClientIdentity(client: "Labstream", device: "Test",
            deviceId: "test", version: "1"), userId: "user", session: session,
            coordinator: coordinator))
    }

    private var onePixelPNG: Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    }
}

private final class TrickPlayURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Response = @Sendable (URLRequest) -> (Int, String, Data)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responder: Response?
    nonisolated(unsafe) private static var captured: [URLRequest] = []

    static var requests: [URLRequest] { lock.withLock { captured } }
    static func count(path: String) -> Int { requests.filter { $0.url?.path == path }.count }
    static func configure(_ value: @escaping Response) { lock.withLock { responder = value; captured = [] } }
    static func reset() { lock.withLock { responder = nil; captured = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = Self.lock.withLock { () -> (Int, String, Data)? in
            Self.captured.append(request)
            return Self.responder?(request)
        }
        guard let (status, contentType, data) = response else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": contentType])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func makeBIF(payload: Data) -> Data {
    func le(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
    var data = Data([0x89, 0x42, 0x49, 0x46, 0x0D, 0x0A, 0x1A, 0x0A])
    data += le(0); data += le(1); data += le(1_000)
    data += Data(repeating: 0, count: 64 - data.count)
    let start = UInt32(80)
    data += le(0); data += le(start)
    data += le(UInt32.max); data += le(start + UInt32(payload.count))
    data += payload
    return data
}
