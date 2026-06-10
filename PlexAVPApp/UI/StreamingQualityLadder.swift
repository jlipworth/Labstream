import Foundation

/// The app's single bitrate-cap ladder (#21), shared by the in-player Quality tab and the
/// Settings "Streaming quality" default picker so the two surfaces can never drift apart —
/// both read/write the same persisted `maxVideoBitrateKbps` key, and a value picked in one
/// always resolves a checkmark in the other.
///
/// Aligned to Plex's web quality presets so each cap maps to a sensible resolution. All
/// previously selectable caps (2/4/8/12/20 Mbps + Maximum) are retained — so an older
/// persisted choice still resolves — plus 3/10/40 Mbps for finer steps.
enum StreamingQuality {

    /// One rung of the ladder. `kbps == 0` is the "Maximum (original)" sentinel (no cap);
    /// `resolution` is the rough target PMS encodes to at that ceiling (empty for Maximum).
    struct Option: Identifiable {
        let kbps: Int
        let resolution: String
        var id: Int { kbps }
    }

    static let ladder: [Option] = [
        Option(kbps: 2000,  resolution: "720p"),
        Option(kbps: 3000,  resolution: "720p"),
        Option(kbps: 4000,  resolution: "720p"),
        Option(kbps: 8000,  resolution: "1080p"),
        Option(kbps: 10000, resolution: "1080p"),
        Option(kbps: 12000, resolution: "1080p"),
        Option(kbps: 20000, resolution: "1080p"),
        Option(kbps: 40000, resolution: "4K"),
        Option(kbps: 0,     resolution: ""),
    ]

    /// "Maximum (original)" for the no-cap sentinel; otherwise "<N> Mbps · <resolution>",
    /// e.g. "8 Mbps · 1080p". Fractional Mbps (none in the current ladder) render without
    /// trailing zeros via `%g`.
    static func label(kbps: Int) -> String {
        guard kbps > 0 else { return "Maximum (original)" }
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
