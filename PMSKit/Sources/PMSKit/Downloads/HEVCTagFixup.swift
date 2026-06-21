import Foundation

/// #83: rewrite an MP4's HEVC sample-entry FourCC from `hev1` to `hvc1`.
///
/// AVFoundation decodes only `hvc1`-tagged HEVC; an `hev1`-tagged track renders black / "not
/// supported". When Jellyfin/Emby stream-COPY HEVC into a progressive MP4 they preserve the
/// source's `hev1` tag (the `hvc1`-forcing only happens on the HLS/fMP4 path). The two tags
/// describe the same bitstream — `hvc1` keeps the parameter sets in the sample description
/// (`hvcC`), `hev1` allows them inline — and for a stream-copied file from these servers the
/// `hvcC` box is already present, so flipping the FourCC is a lossless, byte-length-preserving
/// fixup (no re-encode, original video quality kept).
///
/// This is a deliberately MINIMAL, targeted edit: it finds occurrences of the ASCII bytes `hev1`
/// that are immediately followed (within the sample entry header) by an `hvcC` configuration box
/// and rewrites only those four bytes in place. It does NOT reparse the full box tree, so it
/// cannot corrupt offsets (every byte length is preserved) and it leaves non-HEVC files untouched.
public enum HEVCTagFixup {
    private static let hev1: [UInt8] = Array("hev1".utf8)
    private static let hvc1: [UInt8] = Array("hvc1".utf8)
    private static let hvcC: [UInt8] = Array("hvcC".utf8)

    /// Rewrite `hev1` sample entries to `hvc1` in-place within `data`. Returns the number of entries
    /// rewritten (0 when the file has no `hev1` HEVC sample entry — e.g. it is `hvc1` already, or not
    /// HEVC at all).
    @discardableResult
    public static func rewriteSampleEntries(in data: inout Data) -> Int {
        guard data.count >= 8 else { return 0 }
        var bytes = [UInt8](data)
        var rewritten = 0
        var i = 0
        // A `VisualSampleEntry` is `hev1` followed by a 78-byte header, then child boxes; the first
        // child for HEVC is the `hvcC` config box. We confirm an `hvcC` appears in a bounded window
        // after the FourCC so we only flip genuine HEVC sample entries, never an `hev1` byte run that
        // happens to occur inside media data.
        let searchWindow = 256
        while i + 4 <= bytes.count {
            if bytes[i] == hev1[0], bytes[i + 1] == hev1[1],
               bytes[i + 2] == hev1[2], bytes[i + 3] == hev1[3],
               hasConfigBox(in: bytes, near: i + 4, window: searchWindow) {
                bytes[i] = hvc1[0]
                bytes[i + 1] = hvc1[1]
                bytes[i + 2] = hvc1[2]
                bytes[i + 3] = hvc1[3]
                rewritten += 1
                i += 4
            } else {
                i += 1
            }
        }
        if rewritten > 0 { data = Data(bytes) }
        return rewritten
    }

    private static func hasConfigBox(in bytes: [UInt8], near start: Int, window: Int) -> Bool {
        var j = start
        let limit = min(bytes.count - 4, start + window)
        while j <= limit {
            if bytes[j] == hvcC[0], bytes[j + 1] == hvcC[1],
               bytes[j + 2] == hvcC[2], bytes[j + 3] == hvcC[3] {
                return true
            }
            j += 1
        }
        return false
    }

    /// Apply the fixup to a completed download file on disk. Reads the file, rewrites any `hev1`
    /// sample entries to `hvc1`, and writes it back atomically only if something changed. Returns
    /// the number of entries rewritten; 0 (and no write) when nothing matched. Throws only on I/O.
    @discardableResult
    public static func rewriteFile(at url: URL) throws -> Int {
        var data = try Data(contentsOf: url, options: .mappedIfSafe)
        let count = rewriteSampleEntries(in: &data)
        if count > 0 {
            try data.write(to: url, options: .atomic)
        }
        return count
    }
}
