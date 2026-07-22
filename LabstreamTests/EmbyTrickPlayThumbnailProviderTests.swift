import CoreGraphics
import Foundation
import PMSKit
import XCTest
@testable import Labstream

final class EmbyTrickPlayThumbnailProviderTests: XCTestCase {
    override func tearDown() {
        TrickPlayURLProtocol.reset()
        super.tearDown()
    }

    func testDefaultTrickPlayTransportIsEphemeralAndCredentialSafe() {
        let configuration = SideAssetTransportPolicy.nonpersistentConfiguration()

        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.urlCredentialStorage)

        let sharedConfiguration = SideAssetTransportPolicy.sharedSession.configuration
        XCTAssertEqual(sharedConfiguration.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        XCTAssertNil(sharedConfiguration.urlCache)
        XCTAssertNil(sharedConfiguration.httpCookieStorage)
        XCTAssertNil(sharedConfiguration.urlCredentialStorage)
    }

    func testPlexBIFUsesInjectedSpecializedTransportAndPreservesAuthenticatedRequest() async throws {
        let payload = Data("plex-bif-frame".utf8)
        TrickPlayURLProtocol.configure { request in
            (200, "application/octet-stream", makeBIF(payload: payload))
        }
        let configuration = SideAssetTransportPolicy.nonpersistentConfiguration()
        configuration.protocolClasses = [TrickPlayURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let identity = ClientIdentity(clientIdentifier: "test-device",
                                      product: "Labstream",
                                      version: "1",
                                      deviceName: "Test")
        let item = MediaItem(ratingKey: "item", title: "Movie", type: "movie", media: [
            Media(id: 1, part: [Part(id: 42, key: "/library/parts/42", indexes: "sd")])
        ])
        let coordinator = SideAssetFetchCoordinator(
            policy: .init(maximumRequestStartsPerSecond: 10_000, maximumConcurrentRequests: 4))
        let provider = try XCTUnwrap(PlexBIFTrickPlayThumbnailProvider(
            item: item,
            mediaIndex: 0,
            server: URL(string: "https://plex.invalid:32400")!,
            token: "secret-token",
            identity: identity,
            session: session,
            coordinator: coordinator
        ))

        let result = await provider.thumbnail(nearMs: 9_000)

        XCTAssertEqual(result?.timeMs, 0)
        XCTAssertEqual(result?.imageData, payload)
        let request = try XCTUnwrap(TrickPlayURLProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/library/parts/42/indexes/sd")
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first(where: { $0.name == "X-Plex-Token" })?.value, "secret-token")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
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

    func testMalformedChapterPayloadIsRejectedAndNotCached() async throws {
        TrickPlayURLProtocol.configure { request in
            switch request.url!.path {
            case "/Items/item/ThumbnailSet":
                return (200, "application/json", #"{"Thumbnails":[]}"#.data(using: .utf8)!)
            case "/Items/item/Images/Chapter/0":
                return (200, "image/jpeg", Data("not-an-image".utf8))
            default:
                return (404, "application/json", Data([0]))
            }
        }
        let chapter = Chapter(startTimeOffset: 0, thumb: "emby://item/item/Chapter/0?tag=c")
        let provider = try makeProvider(item: MediaItem(
            ratingKey: "item", title: "", type: "movie", chapters: [chapter]))

        let first = await provider.thumbnail(nearMs: 0)
        let second = await provider.thumbnail(nearMs: 0)
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(TrickPlayURLProtocol.count(path: "/Items/item/Images/Chapter/0"), 2,
                       "a malformed 2xx body must never become a provider cache hit")
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

    func testConcurrentThumbnailRequestsShareASingleBIFLoad() async throws {
        // Hits BIFBackedTrickPlayThumbnailProvider directly: the Emby tests above route through the
        // SideAssetFetchCoordinator, which coalesces on its own and so masks a provider-level
        // single-flight regression. This gates the loader so all callers are in-flight at once.
        let bif = makeBIF(payload: Data("bif-frame".utf8))
        let loadCount = LoaderInvocationCounter()
        let gate = LoaderGate()
        let provider = BIFBackedTrickPlayThumbnailProvider {
            await loadCount.increment()
            await gate.wait()
            return bif
        }

        let callerCount = 8
        let callers = (0..<callerCount).map { _ in
            Task { await provider.thumbnail(nearMs: 0) }
        }

        // Wait until the shared load has actually begun, then let the remaining callers reach the
        // shared task before releasing the gate.
        while await loadCount.value == 0 { await Task.yield() }
        for _ in 0..<50 { await Task.yield() }
        gate.open()

        var frames: [TrickPlayThumbnail?] = []
        for caller in callers { frames.append(await caller.value) }

        let finalLoadCount = await loadCount.value
        XCTAssertEqual(finalLoadCount, 1, "concurrent scrub targets must share one BIF fetch")
        XCTAssertEqual(frames.compactMap { $0 }.count, callerCount, "every caller must get a frame")
        for frame in frames.compactMap({ $0 }) {
            XCTAssertEqual(frame.imageData, Data("bif-frame".utf8))
        }
    }

    func testLocalBIFProviderUsesMappedParserAndReturnsSelectedFrame() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("preview.bif")
        try makeBIF(payload: Data("mapped-provider-frame".utf8)).write(to: url)
        let provider = try XCTUnwrap(LocalBIFTrickPlayThumbnailProvider(bifURL: url))

        let frame = await provider.thumbnail(nearMs: 0)

        XCTAssertEqual(frame?.imageData, Data("mapped-provider-frame".utf8))
    }

    func testCostBoundedLRUPromotesReplacesAndRejectsOversizeEntries() {
        var cache = TrickPlayCostBoundedLRU<String, String>(costLimit: 10, countLimit: 3)
        cache.insert("a", for: "a", cost: 4)
        cache.insert("b", for: "b", cost: 4)
        XCTAssertEqual(cache.value(for: "a"), "a", "a hit should promote it over b")

        cache.insert("c", for: "c", cost: 4)
        XCTAssertNil(cache.value(for: "b"))
        XCTAssertEqual(cache.value(for: "a"), "a")
        XCTAssertEqual(cache.value(for: "c"), "c")
        XCTAssertEqual(cache.totalCost, 8)

        cache.insert("a2", for: "a", cost: 2)
        XCTAssertEqual(cache.value(for: "a"), "a2")
        XCTAssertEqual(cache.totalCost, 6, "replacement must subtract the old cost")

        cache.insert("too-large", for: "oversize", cost: 11)
        XCTAssertNil(cache.value(for: "oversize"))
        XCTAssertEqual(cache.totalCost, 6)
    }

    func testCostBoundedLRUAlsoEnforcesEntryCeiling() {
        var cache = TrickPlayCostBoundedLRU<Int, Int>(costLimit: 1_000, countLimit: 2)
        cache.insert(1, for: 1, cost: 1)
        cache.insert(2, for: 2, cost: 1)
        _ = cache.value(for: 1)
        cache.insert(3, for: 3, cost: 1)

        XCTAssertEqual(cache.count, 2)
        XCTAssertNotNil(cache.value(for: 1))
        XCTAssertNil(cache.value(for: 2))
        XCTAssertNotNil(cache.value(for: 3))
    }

    func testDecodedTileCacheEvictsByPixelBytesRatherThanOnlyEntryCount() throws {
        let first = DecodedImage(cgImage: try makeImage(width: 4, height: 4))
        let second = DecodedImage(cgImage: try makeImage(width: 4, height: 4))
        let oneImageCost = first.cgImage.bytesPerRow * first.cgImage.height
        var cache = JellyfinTrickPlayTileCache(byteLimit: oneImageCost, entryLimit: 4)

        cache.insert(first, for: "first")
        cache.insert(second, for: "second")

        XCTAssertNil(cache.image(for: "first"))
        XCTAssertNotNil(cache.image(for: "second"))
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

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try XCTUnwrap(context.makeImage())
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

private actor LoaderInvocationCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// One-shot async gate: callers awaiting `wait()` before `open()` suspend until it is opened.
private final class LoaderGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        opened = true
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume() }
    }
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
