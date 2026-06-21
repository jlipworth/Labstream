import Testing
import Foundation
@testable import PMSKit

// #83: the hev1→hvc1 MP4 sample-entry FourCC fixup that AVFoundation requires for stream-copied
// HEVC. Verified against synthetic buffers shaped like a VisualSampleEntry (`hev1` + header + an
// `hvcC` config box) — a byte-length-preserving in-place edit.

@Suite("HEVC tag fixup")
struct HEVCTagFixupTests {
    /// Build a buffer: <padding> hev1 <N filler bytes> hvcC <tail> — mimics a sample entry whose
    /// config box (`hvcC`) follows the FourCC within the header window.
    private func sampleEntry(fourcc: String, gap: Int) -> Data {
        var bytes: [UInt8] = Array("....mdat...".utf8)   // leading non-box noise
        bytes += Array(fourcc.utf8)
        bytes += [UInt8](repeating: 0xAB, count: gap)
        bytes += Array("hvcC".utf8)
        bytes += [UInt8](repeating: 0xCD, count: 16)
        return Data(bytes)
    }

    private func contains(_ data: Data, _ fourcc: String) -> Bool {
        data.range(of: Data(fourcc.utf8)) != nil
    }

    @Test func rewritesHev1FollowedByConfigBox() {
        var data = sampleEntry(fourcc: "hev1", gap: 78)
        let original = data.count
        let count = HEVCTagFixup.rewriteSampleEntries(in: &data)

        #expect(count == 1)
        #expect(data.count == original)                          // length preserved
        #expect(contains(data, "hvc1") == true)
        #expect(contains(data, "hev1") == false)
    }

    @Test func leavesAlreadyHvc1Untouched() {
        var data = sampleEntry(fourcc: "hvc1", gap: 78)
        let count = HEVCTagFixup.rewriteSampleEntries(in: &data)
        #expect(count == 0)
        #expect(contains(data, "hvc1") == true)
    }

    @Test func ignoresHev1BytesWithoutNearbyConfigBox() {
        // A bare "hev1" byte run far from any hvcC (e.g. inside media payload) must NOT be flipped.
        var bytes = Array("hev1".utf8)
        bytes += [UInt8](repeating: 0x00, count: 4096)
        bytes += Array("hvcC".utf8)   // too far away → outside the 256-byte window
        var data = Data(bytes)
        let count = HEVCTagFixup.rewriteSampleEntries(in: &data)
        #expect(count == 0)
    }

    @Test func handlesEmptyOrTinyData() {
        var empty = Data()
        #expect(HEVCTagFixup.rewriteSampleEntries(in: &empty) == 0)
        var tiny = Data([0x68, 0x65, 0x76])   // "hev" — incomplete FourCC
        #expect(HEVCTagFixup.rewriteSampleEntries(in: &tiny) == 0)
    }

    @Test func rewritesFileOnDiskOnlyWhenMatched() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let hevURL = dir.appendingPathComponent("hev.mp4")
        try sampleEntry(fourcc: "hev1", gap: 78).write(to: hevURL)
        #expect(try HEVCTagFixup.rewriteFile(at: hevURL) == 1)
        let rewritten = try Data(contentsOf: hevURL)
        #expect(contains(rewritten, "hvc1") == true)

        let h264URL = dir.appendingPathComponent("avc.mp4")
        try Data(Array("....avc1....".utf8)).write(to: h264URL)
        #expect(try HEVCTagFixup.rewriteFile(at: h264URL) == 0)   // no write, no match
    }
}
