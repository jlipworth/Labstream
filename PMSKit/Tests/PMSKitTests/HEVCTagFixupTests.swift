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

    @Test func rewritesFileWhenSampleEntryStraddlesReadChunk() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("boundary.mp4")
        var bytes = [UInt8](repeating: 0xEE, count: 1024 * 1024 - 2)
        bytes += Array("hev1".utf8)
        bytes += [UInt8](repeating: 0xAB, count: 78)
        bytes += Array("hvcC".utf8)
        bytes += [UInt8](repeating: 0xCD, count: 16)
        try Data(bytes).write(to: url)

        #expect(try HEVCTagFixup.rewriteFile(at: url) == 1)
        let rewritten = try Data(contentsOf: url)
        #expect(contains(rewritten, "hvc1") == true)
        #expect(contains(rewritten, "hev1") == false)
    }
    @Test("A middle moov is scanned even after a window match, past an extended-size predecessor")
    func scansWholeMiddleMoovAfterWindowMatch() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let middle: UInt64 = 66 * 1024 * 1024
        let end: UInt64 = 140 * 1024 * 1024
        // Extended-size free box contains a visible sample entry in the front scan window.
        try handle.write(contentsOf: boxHeader(size: 1, type: "free") + uint64(middle))
        try handle.write(contentsOf: sampleEntry(fourcc: "hev1", gap: 78))
        try handle.seek(toOffset: middle)
        let entry = sampleEntry(fourcc: "hev1", gap: 78)
        try handle.write(contentsOf: boxHeader(size: UInt32(entry.count + 8), type: "moov") + entry)
        try handle.write(contentsOf: boxHeader(size: 0, type: "mdat"))
        try handle.truncate(atOffset: end)
        #expect(try HEVCTagFixup.rewriteFile(at: url) == 2)
        try handle.seek(toOffset: middle + 8)
        let rewritten = try handle.read(upToCount: entry.count) ?? Data()
        #expect(contains(rewritten, "hvc1"))
        #expect(!contains(rewritten, "hev1"))
    }

    @Test("Malformed box lengths stop walking safely", arguments: [UInt32(0), 1, 4, 7, UInt32.max])
    func malformedPredecessorStopsSafely(size: UInt32) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        // Size 0 is a valid final box consuming the file; the apparent moov is inside its payload.
        try boxHeader(size: size, type: "free").write(to: url)
        #expect(try HEVCTagFixup.rewriteFile(at: url) == 0)
    }

    private func uint64(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private func boxHeader(size: UInt32, type: String) -> Data {
        withUnsafeBytes(of: size.bigEndian) { Data($0) } + Data(type.utf8)
    }

}
