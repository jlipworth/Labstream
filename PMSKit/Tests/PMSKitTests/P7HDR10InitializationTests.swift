import Foundation
import XCTest
@testable import PMSKit

final class P7HDR10InitializationTests: XCTestCase {
    private func box(_ type: String, _ payload: Data) -> Data {
        let count = UInt32(payload.count + 8)
        return Data([UInt8(count >> 24), UInt8(truncatingIfNeeded: count >> 16),
                     UInt8(truncatingIfNeeded: count >> 8), UInt8(truncatingIfNeeded: count)])
            + Data(type.utf8) + payload
    }

    private func fixture(profile: UInt8 = 7, compatibility: UInt8 = 6,
                         transfer: UInt8 = 16, entry: String = "hvc1",
                         duplicateDV: Bool = false, extra: Data = Data(), audio: Data = Data()) -> Data {
        var hevc = Data(repeating: 0, count: 23)
        hevc[0] = 1; hevc[1] = 2; hevc[16] = 1
        hevc[17] = 2; hevc[18] = 2; hevc[21] = 3; hevc[22] = 3
        for type: UInt8 in [32, 33, 34] { hevc += Data([type, 0, 1, 0, 2, type << 1, 1]) }
        var dv = Data(repeating: 0, count: 24)
        dv[0] = 1; dv[2] = profile << 1; dv[3] = (6 << 3) | 7; dv[4] = compatibility << 4
        let dvBox = box("dvcC", dv)
        let extensions = box("hvcC", hevc)
            + box("colr", Data("nclx".utf8) + Data([0, 9, 0, transfer, 0, 9, 0]))
            + dvBox + (duplicateDV ? dvBox : Data()) + extra
        let visual = box(entry, Data(repeating: 0, count: 78) + extensions)
        let stsd = box("stsd", Data([0, 0, 0, 0, 0, 0, 0, 1]) + visual)
        let hdlr = box("hdlr", Data(repeating: 0, count: 8) + Data("vide".utf8))
        let media = box("mdia", hdlr + box("minf", box("stbl", stsd)))
        return box("ftyp", Data("iso6".utf8)) + box("moov", box("trak", media) + audio + box("mvex", Data()))
    }

    private func audioTrack(entry: String = "ac-3", config: Data = Data([0x10, 0x3e, 0x40]),
                            extra: Data = Data(), corruptHeader: Bool = false) -> Data {
        var header = Data([0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0,
                           0, 6, 0, 16, 0, 0, 0, 0, 0xbb, 0x80, 0, 0])
        if corruptHeader { header[8] = 1 }
        let sample = box(entry, header + box("dac3", config) + extra)
        let stsd = box("stsd", Data([0, 0, 0, 0, 0, 0, 0, 1]) + sample)
        let hdlr = box("hdlr", Data(repeating: 0, count: 8) + Data("soun".utf8))
        return box("trak", box("mdia", hdlr + box("minf", box("stbl", stsd))))
    }

    func testObservedAC3AudioIsPreservedWithoutChangingVideoAdmission() throws {
        let audio = audioTrack(extra: box("btrt", Data(repeating: 0, count: 12)))
        let input = fixture(audio: audio)
        var expected = input
        expected.replaceSubrange(try XCTUnwrap(input.range(of: Data("dvcC".utf8))), with: "free".utf8)
        XCTAssertEqual(try P7HDR10Initialization.normalize(input), expected)
        XCTAssertThrowsError(try P7HDR10Initialization.normalize(fixture(profile: 5, audio: audio)))
        for unsupported in [audioTrack(entry: "ec-3"), audioTrack(entry: "enca"),
                            audioTrack(config: Data([0x10, 0x3e])),
                            audioTrack(config: Data([0x10, 0x3e, 0x41])),
                            audioTrack(corruptHeader: true),
                            audioTrack(extra: box("sinf", Data())),
                            audioTrack(extra: box("dac3", Data([0x10, 0x3e, 0x40]))),
                            audioTrack(extra: box("btrt", Data(repeating: 0, count: 11)))] {
            XCTAssertThrowsError(try P7HDR10Initialization.normalize(fixture(audio: unsupported)))
        }
    }

    func testOnlyConfigurationTypeChangesAndLengthIsStable() throws {
        let input = fixture()
        let output = try P7HDR10Initialization.normalize(input)
        let range = try XCTUnwrap(input.range(of: Data("dvcC".utf8)))
        var expected = input
        expected.replaceSubrange(range, with: "free".utf8)
        XCTAssertEqual(output, expected)
        XCTAssertEqual(output.count, input.count)
        XCTAssertThrowsError(try P7HDR10Initialization.normalize(output))
    }

    func testOtherProfilesAndColorSpacesFailClosed() {
        for profile: UInt8 in [0, 5, 8, 9] {
            XCTAssertThrowsError(try P7HDR10Initialization.normalize(fixture(profile: profile)))
        }
        for compatibility: UInt8 in [0, 1, 2, 4] {
            XCTAssertThrowsError(try P7HDR10Initialization.normalize(fixture(compatibility: compatibility)))
        }
        for transfer: UInt8 in [1, 2, 18] {
            XCTAssertThrowsError(try P7HDR10Initialization.normalize(fixture(transfer: transfer)))
        }
    }

    func testEncryptionUnknownExtensionsAndDuplicateConfigurationRejected() {
        XCTAssertThrowsError(try P7HDR10Initialization.normalize(fixture(entry: "encv")))
        XCTAssertThrowsError(try P7HDR10Initialization.normalize(fixture(entry: "hev1")))
        XCTAssertThrowsError(try P7HDR10Initialization.normalize(fixture(duplicateDV: true)))
        XCTAssertThrowsError(try P7HDR10Initialization.normalize(fixture(extra: box("sinf", Data()))))
        XCTAssertThrowsError(try P7HDR10Initialization.normalize(fixture(extra: box("dvvC", Data()))))
    }

    func testEveryTruncatedPrefixFailsClosed() {
        let input = fixture()
        for count in 0..<input.count {
            XCTAssertThrowsError(try P7HDR10Initialization.normalize(Data(input.prefix(count))), "prefix \(count)")
        }
    }

    func testMediaAndUnboundedSizesRejected() {
        XCTAssertThrowsError(try P7HDR10Initialization.normalize(fixture() + box("mdat", Data([1, 2, 3]))))
        XCTAssertThrowsError(try P7HDR10Initialization.normalize(Data(repeating: 0, count: 1_048_577)))
        for size: UInt8 in [0, 1, 7, 255] {
            var input = fixture(); input[3] = size
            XCTAssertThrowsError(try P7HDR10Initialization.normalize(input))
        }
    }
    func testSessionPinsExactInitializationBytesUntilFreshOpen() async throws {
        let root = URL(string: "https://plex.example.internal/media.m3u8")!
        let initURL = root.deletingLastPathComponent().appendingPathComponent("init.mp4")
        let playlist = Data("#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:10,\n0.m4s\n".utf8)
        let session = P7HDR10Session(playlist: root)
        let original = fixture()
        // Both configurations independently pass admission. A stable URL is not
        // sufficient to establish that their byte-range representations are identical.
        let changed = fixture(audio: audioTrack())
        let expected = try P7HDR10Initialization.normalize(original)
        _ = try P7HDR10Initialization.normalize(changed)
        do {
            _ = try await session.normalizeInitialization(original, at: initURL)
            XCTFail("unadmitted initialization accepted")
        } catch {}
        try await session.admit(playlist)
        do {
            _ = try await session.normalizeInitialization(Data(), at: initURL)
            XCTFail("malformed initialization accepted")
        } catch {}
        let first = try await session.normalizeInitialization(original, at: initURL)
        XCTAssertEqual(first, expected)
        do {
            _ = try await session.normalizeInitialization(changed, at: initURL)
            XCTFail("changed representation accepted at the same URL")
        } catch {}
        try await session.admit(playlist)
        let repeated = try await session.normalizeInitialization(original, at: initURL)
        XCTAssertEqual(repeated, expected)
        let reopened = P7HDR10Session(playlist: root)
        try await reopened.admit(playlist)
        let fresh = try await reopened.normalizeInitialization(changed, at: initURL)
        XCTAssertEqual(fresh, try P7HDR10Initialization.normalize(changed))
    }

    #if canImport(Network)
    func testProxyRejectsChangedInitializationDuringRangeAndResetsOnReopen() async throws {
        actor Responses {
            var initialization: Data
            init(_ data: Data) { initialization = data }
            func replace(_ data: Data) { initialization = data }
            func current() -> Data { initialization }
        }
        let original = fixture()
        let changed = fixture(audio: audioTrack())
        let responses = Responses(original)
        let playlist = Data("#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:10,\n0.m4s\n".utf8)
        let proxy = MediaSessionProxy(upstreamFetch: { request in
            let url = request.url!
            let body = url.path.hasSuffix("m3u8") ? playlist : await responses.current()
            return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": url.path.hasSuffix("m3u8") ? "application/vnd.apple.mpegurl" : "video/mp4"])!)
        }, p7HDR10Fallback: true)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let root = URL(string: "https://plex.example.internal/media.m3u8")!
        let first = try await proxy.standUpLoopback(forStream: root)
        _ = try await session.data(from: first.localURL)
        let initURL = first.localURL.deletingLastPathComponent().appendingPathComponent("init.mp4")
        var range = URLRequest(url: initURL)
        range.setValue("bytes=0-7", forHTTPHeaderField: "Range")
        let (initial, initialResponse) = try await session.data(for: range)
        XCTAssertEqual((initialResponse as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(initial, Data(try P7HDR10Initialization.normalize(original).prefix(8)))
        await responses.replace(changed)
        let (rejected, rejectedResponse) = try await session.data(for: range)
        XCTAssertEqual((rejectedResponse as? HTTPURLResponse)?.statusCode, 502)
        XCTAssertTrue(rejected.isEmpty)
        let (_, fullResponse) = try await session.data(from: initURL)
        XCTAssertEqual((fullResponse as? HTTPURLResponse)?.statusCode, 502)
        await proxy.stop(generation: first.generation)
        let reopened = try await proxy.standUpLoopback(forStream: root)
        _ = try await session.data(from: reopened.localURL)
        let freshURL = reopened.localURL.deletingLastPathComponent().appendingPathComponent("init.mp4")
        let (fresh, freshResponse) = try await session.data(from: freshURL)
        XCTAssertEqual((freshResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(fresh, try P7HDR10Initialization.normalize(changed))
        await proxy.stop(generation: reopened.generation)
    }

    func testProxyNormalizesOnlyAdmittedInitializationAndServesRanges() async throws {
        let initData = fixture()
        let expected = try P7HDR10Initialization.normalize(initData)
        let segment = Data([0, 1, 2, 3, 4])
        let playlist = Data("#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:10,\n0.m4s\n#EXTINF:10,\n1.m4s\n".utf8)
        let proxy = MediaSessionProxy(upstreamFetch: { request in
            let url = request.url!
            let body: Data
            if url.path == "/media.m3u8" { body = playlist }
            else if url.path == "/init.mp4" {
                XCTAssertNil(request.value(forHTTPHeaderField: "Range"))
                body = initData
            } else { body = segment }
            return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": url.path.hasSuffix("m3u8") ? "application/vnd.apple.mpegurl" : "video/mp4"])!)
        }, p7HDR10Fallback: true)
        let handle = try await proxy.standUpLoopback(forStream: URL(string: "https://plex.example.internal/media.m3u8")!)
        let session = URLSession(configuration: .ephemeral)
        let initURL = handle.localURL.deletingLastPathComponent().appendingPathComponent("init.mp4")
        let (_, denied) = try await session.data(from: initURL)
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 502)
        _ = try await session.data(from: handle.localURL)
        let (full, _) = try await session.data(from: initURL)
        XCTAssertEqual(full, expected)
        let atom = try XCTUnwrap(expected.range(of: Data("free".utf8)))
        for range in [0..<8, atom.lowerBound..<(atom.lowerBound + 2), atom.lowerBound..<atom.upperBound] {
            var request = URLRequest(url: initURL)
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
            let (part, response) = try await session.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
            XCTAssertEqual(part, expected.subdata(in: range))
            XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"),
                           "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(expected.count)")
        }
        for name in ["0.m4s", "1.m4s"] {
            let (actual, _) = try await session.data(from: initURL.deletingLastPathComponent().appendingPathComponent(name))
            XCTAssertEqual(actual, segment)
        }
        await proxy.stop(generation: handle.generation)
        session.invalidateAndCancel()
    }
    #endif

}
