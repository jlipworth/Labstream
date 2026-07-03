import Foundation

/// Backend-neutral HDR format classification for a video stream (GH #195).
///
/// Derived from Plex `Stream` color/DOVI attributes or Jellyfin/Emby `MediaStream`
/// range/color/DV fields. Classification is deliberately conservative: it only claims a
/// format on positive evidence and returns `nil` when the backend supplied nothing usable,
/// so the Stats panel can omit the row instead of guessing.
public enum VideoHDRFormat: String, Sendable, Equatable, CaseIterable {
    case sdr
    case hdr10
    case hdr10Plus
    case hlg
    case dolbyVision
    /// Backend says "HDR" but neither the transfer function nor a specific format is known.
    case unknownHDR
}

/// Dolby Vision facts as reported by the backend (not verified against the bitstream).
public struct VideoDolbyVisionInfo: Sendable, Equatable {
    public let profile: Int?
    public let level: Int?
    /// DV base-layer signal compatibility ID: 0 = none (P5-style IPTPQc2),
    /// 1/6 = HDR10-compatible, 2 = SDR-compatible, 4 = HLG-compatible.
    public let blCompatibilityID: Int?
    public let rpuPresent: Bool?
    public let elPresent: Bool?
    public let blPresent: Bool?

    public init(profile: Int?, level: Int?, blCompatibilityID: Int?,
                rpuPresent: Bool?, elPresent: Bool?, blPresent: Bool?) {
        self.profile = profile
        self.level = level
        self.blCompatibilityID = blCompatibilityID
        self.rpuPresent = rpuPresent
        self.elPresent = elPresent
        self.blPresent = blPresent
    }

    /// Human name for the base layer a non-DV player falls back to, from the
    /// compatibility ID when known. `nil` means "unknown" (omit), not "none".
    var fallbackName: String? {
        switch blCompatibilityID {
        case 1, 6: return "HDR10 fallback"
        case 2: return "SDR fallback"
        case 4: return "HLG fallback"
        case 0: return "no fallback"
        default: return nil
        }
    }
}

/// One video stream's HDR/color facts, normalized across backends.
public struct VideoHDRMetadata: Sendable, Equatable {
    public let format: VideoHDRFormat
    public let bitDepth: Int?
    public let colorPrimaries: String?
    public let colorTransfer: String?
    public let colorSpace: String?
    public let colorRange: String?
    public let dolbyVision: VideoDolbyVisionInfo?
    public let hdr10PlusPresent: Bool?

    /// Full Stats-panel label, e.g. "Dolby Vision P8 (HDR10 fallback)" or
    /// "HDR10 · PQ · BT.2020 · 10-bit". Never includes titles/ids/URLs.
    public var displayLabel: String {
        switch format {
        case .dolbyVision:
            var name = "Dolby Vision"
            if let profile = dolbyVision?.profile { name += " P\(profile)" }
            if let fallback = dolbyVision?.fallbackName { name += " (\(fallback))" }
            return name
        case .hdr10, .hdr10Plus:
            var parts = [format == .hdr10Plus ? "HDR10+" : "HDR10"]
            if Self.isPQ(colorTransfer) { parts.append("PQ") }
            if let primaries = Self.primariesName(colorPrimaries) { parts.append(primaries) }
            if let bitDepth { parts.append("\(bitDepth)-bit") }
            return parts.joined(separator: " · ")
        case .hlg:
            var parts = ["HLG"]
            if let primaries = Self.primariesName(colorPrimaries) { parts.append(primaries) }
            if let bitDepth { parts.append("\(bitDepth)-bit") }
            return parts.joined(separator: " · ")
        case .sdr:
            var parts = ["SDR"]
            if let bitDepth { parts.append("\(bitDepth)-bit") }
            return parts.joined(separator: " · ")
        case .unknownHDR:
            return "HDR (unspecified)"
        }
    }

    /// Compact badge-style label: "DV P8", "HDR10+", "HLG", "SDR".
    public var shortLabel: String {
        switch format {
        case .dolbyVision:
            if let profile = dolbyVision?.profile { return "DV P\(profile)" }
            return "DV"
        case .hdr10: return "HDR10"
        case .hdr10Plus: return "HDR10+"
        case .hlg: return "HLG"
        case .sdr: return "SDR"
        case .unknownHDR: return "HDR"
        }
    }

    /// Classify raw backend fields. Precedence: Dolby Vision > HDR10+ > PQ (HDR10) >
    /// HLG > generic-HDR range string > positive SDR evidence > nil (nothing known).
    ///
    /// `rangeDescribesHDR` carries a backend's coarse range verdict (Jellyfin
    /// `VideoRange == "HDR"` → true, `"SDR"` → false) when no finer detail exists.
    /// Bit depth alone is never treated as HDR evidence — 10-bit SDR encodes exist.
    public static func classify(colorTransfer: String?,
                                colorPrimaries: String?,
                                colorSpace: String?,
                                colorRange: String?,
                                bitDepth: Int?,
                                dolbyVision: VideoDolbyVisionInfo?,
                                hdr10PlusPresent: Bool?,
                                rangeDescribesHDR: Bool?) -> VideoHDRMetadata? {
        // A non-nil `dolbyVision` is itself the DV verdict: callers only construct one
        // when the backend positively signalled DV (DOVIPresent, DvProfile, a DOVI*
        // range type, …), even if every individual field inside it is unknown.
        let format: VideoHDRFormat
        if dolbyVision != nil {
            format = .dolbyVision
        } else if hdr10PlusPresent == true {
            format = .hdr10Plus
        } else if isPQ(colorTransfer) {
            format = .hdr10
        } else if isHLG(colorTransfer) {
            format = .hlg
        } else if rangeDescribesHDR == true {
            format = .unknownHDR
        } else if isKnownSDRTransfer(colorTransfer) || rangeDescribesHDR == false {
            format = .sdr
        } else {
            return nil
        }
        return VideoHDRMetadata(format: format,
                                bitDepth: bitDepth,
                                colorPrimaries: colorPrimaries,
                                colorTransfer: colorTransfer,
                                colorSpace: colorSpace,
                                colorRange: colorRange,
                                dolbyVision: dolbyVision,
                                hdr10PlusPresent: hdr10PlusPresent)
    }

    private static func isPQ(_ transfer: String?) -> Bool {
        guard let t = transfer?.lowercased() else { return false }
        return t.contains("2084") || t == "pq"
    }

    private static func isHLG(_ transfer: String?) -> Bool {
        guard let t = transfer?.lowercased() else { return false }
        return t.contains("arib-std-b67") || t == "hlg"
    }

    private static func isKnownSDRTransfer(_ transfer: String?) -> Bool {
        guard let t = transfer?.lowercased() else { return false }
        return ["bt709", "bt601", "smpte170m", "bt470m", "bt470bg", "iec61966-2-1", "srgb"].contains(t)
    }

    private static func primariesName(_ primaries: String?) -> String? {
        guard let p = primaries?.lowercased() else { return nil }
        if p.contains("2020") { return "BT.2020" }
        if p.contains("p3") { return "P3" }
        if p.contains("709") { return "BT.709" }
        return nil
    }
}
