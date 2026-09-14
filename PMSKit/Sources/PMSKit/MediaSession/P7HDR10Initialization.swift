import Foundation

/// Narrow initialization-only candidate for the native P7 decoder-admission failure (#316).
/// This is HDR10-base decoding, NOT Dolby Vision conversion or enhancement-layer recovery.
/// The caller must independently establish a copy lane and authoritative P7 source metadata.
/// No shipping route uses this helper until live transport/source acceptance is complete.
enum P7HDR10Initialization {
    enum Rejection: Error { case unsupported }

    /// Only replaces the type of one validated dvcC box with `free`. Lengths, offsets, hvcC,
    /// color tags and every media sample remain untouched. Unknown shapes fail closed.
    static func normalize(_ input: Data) throws -> Data {
        guard input.count <= 1_048_576 else { throw Rejection.unsupported }
        let bytes = Array(input)
        struct Box {
            let start: Int
            let end: Int
            let type: String
            var payload: Int { start + 8 }
        }
        func uint(_ at: Int, _ width: Int) -> UInt64 {
            bytes[at..<(at + width)].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        func boxes(_ start: Int, _ end: Int) throws -> [Box] {
            guard start <= end, end <= bytes.count else { throw Rejection.unsupported }
            var result: [Box] = []
            var offset = start
            while offset < end {
                guard end - offset >= 8 else { throw Rejection.unsupported }
                let size = uint(offset, 4)
                // Deliberately reject zero/extended sizes rather than guessing boundaries.
                guard size >= 8, size <= UInt64(end - offset) else { throw Rejection.unsupported }
                result.append(Box(start: offset, end: offset + Int(size),
                                  type: String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)))
                offset += Int(size)
            }
            return result
        }
        func one(_ type: String, in list: [Box]) throws -> Box {
            let matches = list.filter { $0.type == type }
            guard matches.count == 1 else { throw Rejection.unsupported }
            return matches[0]
        }
        func children(_ box: Box) throws -> [Box] { try boxes(box.payload, box.end) }
        let top = try boxes(0, bytes.count)
        guard top.count == 2, top[0].type == "ftyp", top[1].type == "moov" else {
            throw Rejection.unsupported
        }
        let movie = try children(top[1])
        _ = try one("mvex", in: movie)
        var videoEntries: [Box] = []
        for track in movie where track.type == "trak" {
            let mdia = try one("mdia", in: children(track))
            let media = try children(mdia)
            let handler = try one("hdlr", in: media)
            guard handler.end - handler.payload >= 12 else { throw Rejection.unsupported }
            let kind = String(decoding: bytes[(handler.payload + 8)..<(handler.payload + 12)], as: UTF8.self)
            guard kind == "vide" || kind == "soun" else { throw Rejection.unsupported }
            let minf = try one("minf", in: media)
            let stbl = try one("stbl", in: children(minf))
            let stsd = try one("stsd", in: children(stbl))
            guard stsd.end - stsd.payload >= 8,
                  uint(stsd.payload, 4) == 0, uint(stsd.payload + 4, 4) == 1 else {
                throw Rejection.unsupported
            }
            let entries = try boxes(stsd.payload + 8, stsd.end)
            guard entries.count == 1 else { throw Rejection.unsupported }
            if kind == "vide" { videoEntries.append(entries[0]) }
            else {
                let audio = entries[0]
                if audio.type == "ac-3" {
                    // Exact observed six-channel AC-3 sample-entry shape. Audio is retained
                    // byte-for-byte; this is not permission to normalize other audio codecs.
                    let header = Data([0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0,
                                       0, 6, 0, 16, 0, 0, 0, 0, 0xbb, 0x80, 0, 0])
                    guard audio.end - audio.payload >= header.count,
                          Data(bytes[audio.payload..<(audio.payload + header.count)]) == header else {
                        throw Rejection.unsupported
                    }
                    let audioBoxes = try boxes(audio.payload + header.count, audio.end)
                    guard audioBoxes.allSatisfy({ ["dac3", "btrt"].contains($0.type) }) else {
                        throw Rejection.unsupported
                    }
                    let config = try one("dac3", in: audioBoxes)
                    guard Data(bytes[config.payload..<config.end]) == Data([0x10, 0x3e, 0x40]),
                          audioBoxes.filter({ $0.type == "btrt" }).count <= 1,
                          audioBoxes.filter({ $0.type == "btrt" }).allSatisfy({ $0.end - $0.payload == 12 }) else {
                        throw Rejection.unsupported
                    }
                } else {
                    guard audio.type == "mp4a" else { throw Rejection.unsupported }
                }
            }
        }
        guard videoEntries.count == 1, let video = videoEntries.first,
              video.type == "hvc1", video.end - video.start >= 86 else { throw Rejection.unsupported }
        let extensions = try boxes(video.start + 86, video.end)
        guard extensions.allSatisfy({ ["hvcC", "colr", "dvcC", "pasp", "btrt"].contains($0.type) }) else {
            throw Rejection.unsupported
        }
        let hevc = try one("hvcC", in: extensions)
        guard hevc.end - hevc.payload >= 23,
              bytes[hevc.payload] == 1,
              bytes[hevc.payload + 1] & 0x1f == 2, // Main 10
              bytes[hevc.payload + 16] & 3 == 1, // 4:2:0
              bytes[hevc.payload + 17] & 7 == 2,
              bytes[hevc.payload + 18] & 7 == 2,
              bytes[hevc.payload + 21] & 3 == 3 else { throw Rejection.unsupported }
        // Validate all length-prefixed parameter-set arrays before changing signalling.
        var cursor = hevc.payload + 23
        var parameterSets = Set<UInt8>()
        for _ in 0..<Int(bytes[hevc.payload + 22]) {
            guard hevc.end - cursor >= 3 else { throw Rejection.unsupported }
            let type = bytes[cursor] & 0x3f
            guard [32, 33, 34, 39, 40].contains(type) else { throw Rejection.unsupported }
            let count = Int(uint(cursor + 1, 2))
            guard count > 0 else { throw Rejection.unsupported }
            cursor += 3
            for _ in 0..<count {
                guard hevc.end - cursor >= 2 else { throw Rejection.unsupported }
                let length = Int(uint(cursor, 2))
                cursor += 2
                guard length >= 2, length <= hevc.end - cursor,
                      (bytes[cursor] >> 1) & 0x3f == type else { throw Rejection.unsupported }
                cursor += length
            }
            parameterSets.insert(type)
        }
        guard cursor == hevc.end, parameterSets.isSuperset(of: [32, 33, 34]) else {
            throw Rejection.unsupported
        }
        let color = try one("colr", in: extensions)
        guard color.end - color.payload == 11,
              String(decoding: bytes[color.payload..<(color.payload + 4)], as: UTF8.self) == "nclx",
              uint(color.payload + 4, 2) == 9, uint(color.payload + 6, 2) == 16,
              uint(color.payload + 8, 2) == 9, bytes[color.payload + 10] == 0 else {
            throw Rejection.unsupported
        }
        let dv = try one("dvcC", in: extensions)
        guard dv.end - dv.payload == 24,
              bytes[dv.payload] == 1, bytes[dv.payload + 1] == 0,
              bytes[dv.payload + 2] >> 1 == 7,
              bytes[dv.payload + 3] & 7 == 7, // BL, EL and RPU present
              bytes[dv.payload + 4] == 0x60, // exact evidenced compatibility 6
              bytes[(dv.payload + 5)..<dv.end].allSatisfy({ $0 == 0 }) else {
            throw Rejection.unsupported
        }
        let level = ((bytes[dv.payload + 2] & 1) << 5) | (bytes[dv.payload + 3] >> 3)
        guard level == 6 else { throw Rejection.unsupported }
        var output = Data(bytes)
        output.replaceSubrange((dv.start + 4)..<(dv.start + 8), with: "free".utf8)
        return output
    }
}
