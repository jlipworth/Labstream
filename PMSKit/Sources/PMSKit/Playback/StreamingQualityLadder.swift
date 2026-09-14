import Foundation

/// The app's single bitrate-cap ladder (#21), shared by the in-player Quality tab and the
/// Settings "Default Quality" pickers so the surfaces can never drift apart — every surface
/// resolves and persists caps through `PlaybackPreferences`, and a value picked in one always
/// resolves a checkmark in the other.
///
/// Persistence is split into three `PlaybackPreferences.Keys` (see `PlayerExperiencePreferences`):
/// a separate Home cap (`homeMaxVideoBitrateKbps`) and Remote cap (`remoteMaxVideoBitrateKbps`),
/// chosen by reachability, plus the pre-split legacy key (`maxVideoBitrateKbps`) retained for
/// back-compat — it's migrated into the Remote key on first launch, and writes to the Remote cap
/// mirror back to it, so an older build still reads a sensible value.
///
/// Aligned to Plex's web quality presets so each cap maps to a sensible resolution. All
/// previously selectable caps (2/4/8/12/20 Mbps + Maximum) are retained — so an older
/// persisted choice still resolves — plus 3/10/40 Mbps for finer steps.
///
/// The two top choices express video-copy versus video-encode intent:
/// - **Original (Direct Stream)** (`maximumOriginalKbps`, 0): retain source video;
///   remuxing and audio conversion are allowed. Video encoding requires explicit consent.
/// - **Maximum (Transcode)** (`maxTranscodedKbps`): explicitly request video encoding
///   at the highest ceiling on Plex, Jellyfin and Emby.
/// Numeric rungs impose bitrate ceilings; compatible video may still be copied.
public enum StreamingQuality {

    /// The no-cap "Original (Direct Stream)" sentinel: attempt direct play/direct stream first.
    public static let maximumOriginalKbps = 0

    /// The "Maximum (Transcode)" sentinel requests effectively uncapped production HLS.
    /// It forces video encoding rather than returning to the Original copy lane.
    public static let maxTranscodedKbps = 200_000

    /// One rung of the ladder. `kbps == maximumOriginalKbps` (0) is the video-copy
    /// sentinel; `kbps == maxTranscodedKbps` is the maximum-transcode sentinel;
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
        case maximumOriginalKbps: return "Original (Direct Stream)"
        case maxTranscodedKbps:   return "Maximum (Transcode)"
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
