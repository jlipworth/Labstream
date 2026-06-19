import Foundation

/// The app's single bitrate-cap ladder (#21), shared by the in-player Quality tab and the
/// Settings "Default Quality" picker so the two surfaces can never drift apart —
/// both read/write the same persisted `maxVideoBitrateKbps` key, and a value picked in one
/// always resolves a checkmark in the other.
///
/// Aligned to Plex's web quality presets so each cap maps to a sensible resolution. All
/// previously selectable caps (2/4/8/12/20 Mbps + Maximum) are retained — so an older
/// persisted choice still resolves — plus 3/10/40 Mbps for finer steps.
///
/// The top of the ladder splits the old single "Maximum" into two explicit choices that
/// also decide the *path* (this is what replaced the experimental Direct Stream toggle +
/// headroom gate, #31):
/// - **Direct Play / Maximum** (`maximumOriginalKbps`, 0): ask PMS to direct-play/direct-stream
///   the source when compatible. If literal direct-play is rejected, use production HLS, which may
///   still copy video; only when PMS cannot copy video does it become a maximum transcode.
/// - **Maximum (HLS)** (`maxTranscodedKbps`): use Plex/Jellyfin HLS at the highest
///   ceiling. Plex may still copy/remux compatible video; this is not a forced re-encode.
/// Every numeric rung transcodes at that cap.
public enum StreamingQuality {

    /// The no-cap "Direct Play / Maximum" sentinel: attempt direct play/direct stream first.
    public static let maximumOriginalKbps = 0

    /// The "Maximum (HLS)" sentinel: request the production HLS path at this effectively
    /// uncapped ceiling. It skips the literal direct-play probe, but Plex may still Direct
    /// Stream/video-copy compatible sources; it only video-transcodes when PMS requires it.
    public static let maxTranscodedKbps = 200_000

    /// One rung of the ladder. `kbps == maximumOriginalKbps` (0) is the direct-play-or-max
    /// sentinel; `kbps == maxTranscodedKbps` is the maximum-HLS sentinel;
    /// `resolution` is the rough target PMS encodes to at that ceiling (empty for the maxima).
    public struct Option: Identifiable, Sendable {
        public let kbps: Int
        public let resolution: String
        public var id: Int { kbps }

        public init(kbps: Int, resolution: String) {
            self.kbps = kbps
            self.resolution = resolution
        }
    }

    public static let ladder: [Option] = [
        Option(kbps: 2000,  resolution: "720p"),
        Option(kbps: 3000,  resolution: "720p"),
        Option(kbps: 4000,  resolution: "720p"),
        Option(kbps: 8000,  resolution: "1080p"),
        Option(kbps: 10000, resolution: "1080p"),
        Option(kbps: 12000, resolution: "1080p"),
        Option(kbps: 20000, resolution: "1080p"),
        Option(kbps: 40000, resolution: "4K"),
        Option(kbps: maxTranscodedKbps, resolution: ""),
        Option(kbps: maximumOriginalKbps, resolution: ""),
    ]

    /// Friendly label: the two maxima get named choices; numeric rungs render
    /// "<N> Mbps · <resolution>", e.g. "8 Mbps · 1080p". Fractional Mbps (none in the
    /// current ladder) render without trailing zeros via `%g`.
    public static func label(kbps: Int) -> String {
        switch kbps {
        case maximumOriginalKbps: return "Direct Play / Maximum"
        case maxTranscodedKbps:   return "Maximum (HLS)"
        default:
            guard let resolution = ladder.first(where: { $0.kbps == kbps })?.resolution else {
                return "\(kbps / 1000) Mbps"
            }
            let mbps = Double(kbps) / 1000
            let mbpsText = mbps == mbps.rounded()
                ? String(format: "%.0f", mbps)
                : String(format: "%g", mbps)
            return "\(mbpsText) Mbps · \(resolution)"
        }
    }
}
