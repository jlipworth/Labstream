import Foundation

/// Pure, IO-free policy deciding which stashed out-of-order segment bodies are safe to fold into
/// the durable partial file next (range-segments work).
///
/// Background segment tasks can finish in any order; their finished bodies are stashed on disk
/// tagged with the byte offset they cover. This policy never touches disk or the network — it
/// only decides, given the current durable checkpoint and the set of stashed bodies, which ones
/// form the maximal contiguous run starting exactly at the checkpoint (safe to append now, in
/// order), which are legitimate future segments waiting on a gap (hold), and which can never be
/// appended and should be dropped (discard) — either because they are fully behind the
/// checkpoint already, or because they overlap the checkpoint without starting exactly on it. A
/// mis-aligned append must never be attempted, mirroring the existing durable-checkpoint-ahead
/// guard used elsewhere in the static-range pipeline.
public enum StaticRangeSegmentAssemblyPolicy {
    /// Decide the disposition of each stashed segment body relative to the durable checkpoint.
    ///
    /// - Parameters:
    ///   - durableBytes: bytes already durably written to the partial file.
    ///   - stashedSegments: finished segment bodies stashed on disk, as `(offset, length)` pairs.
    ///     Order does not matter; the policy sorts internally.
    /// - Returns: `append` is the maximal contiguous run starting exactly at `durableBytes`, in
    ///   ascending offset order. `hold` is segments beyond a gap after the run — legitimate
    ///   future segments not yet appendable. `discard` is segments fully behind the checkpoint,
    ///   segments that overlap the checkpoint without being aligned to it, and any duplicate
    ///   stash of an offset already classified (the first occurrence of a given offset wins;
    ///   later duplicates always discard).
    public static func appendableRun(
        durableBytes: Int,
        stashedSegments: [(offset: Int, length: Int)]
    ) -> (append: [(offset: Int, length: Int)], hold: [(offset: Int, length: Int)], discard: [(offset: Int, length: Int)]) {
        let sorted = stashedSegments.sorted { $0.offset < $1.offset }

        var append: [(offset: Int, length: Int)] = []
        var hold: [(offset: Int, length: Int)] = []
        var discard: [(offset: Int, length: Int)] = []
        var seenOffsets = Set<Int>()
        var cursor = durableBytes
        var stillContiguous = true

        for segment in sorted {
            guard seenOffsets.insert(segment.offset).inserted else {
                discard.append(segment)
                continue
            }

            let segmentEnd = segment.offset + segment.length
            if segmentEnd <= durableBytes {
                // Fully behind the checkpoint: already durable, nothing to do.
                discard.append(segment)
                continue
            }
            if segment.offset < durableBytes {
                // Overlaps the checkpoint but does not start exactly on it: appending would
                // write a mis-aligned range. Never attempt it.
                discard.append(segment)
                continue
            }

            if stillContiguous && segment.offset == cursor {
                append.append(segment)
                cursor = segmentEnd
            } else {
                stillContiguous = false
                hold.append(segment)
            }
        }

        return (append, hold, discard)
    }
}
