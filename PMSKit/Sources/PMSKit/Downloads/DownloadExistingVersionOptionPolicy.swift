import Foundation

/// Pure presentation/selection model for already-rendered server versions shown in the download
/// sheet. Plex exposes alternates as additional `Media` array entries; Emby exposes Convert-Media
/// copies as additional PlaybackInfo `MediaSource`s. Both are static byte-for-byte downloads whose
/// server-side copy is left in place, but they need different addressing at start time.
public struct DownloadExistingVersionOption: Sendable, Equatable, Identifiable {
    public enum Target: Sendable, Equatable {
        case plexMediaIndex(Int)
        case embyMediaSource(id: String, sizeBytes: Int?)
    }

    public let id: String
    public let label: String
    public let detail: String?
    public let sizeBytes: Int?
    public let width: Int?
    public let height: Int?
    /// Normalized to kbps across Plex (already kbps) and Emby (reported in bits/sec).
    public let bitrateKbps: Int?
    /// True only when this server-rendered alternate is safe to download byte-for-byte and play as a
    /// local offline file on this device. Incompatible versions stay visible but disabled in the UI.
    public let playableOffline: Bool
    public let target: Target

    public init(id: String,
                label: String,
                detail: String?,
                sizeBytes: Int?,
                width: Int? = nil,
                height: Int? = nil,
                bitrateKbps: Int? = nil,
                playableOffline: Bool,
                target: Target) {
        self.id = id
        self.label = label
        self.detail = detail
        self.sizeBytes = sizeBytes
        self.width = width
        self.height = height
        self.bitrateKbps = bitrateKbps
        self.playableOffline = playableOffline
        self.target = target
    }
}

public enum DownloadExistingVersionOptionPolicy {
    /// Existing server-generated Plex Versions to offer as explicit download choices, derived from
    /// the item's `Media` array separately from the currently selected source media. The selected
    /// source is already represented by the normal Original / Optimize choices, so it is skipped.
    public static func plexOptions(media: [Media]?, sourceMediaIndex: Int) -> [DownloadExistingVersionOption] {
        guard let media, media.count > 1 else { return [] }
        return media.enumerated().compactMap { index, m in
            guard index != sourceMediaIndex else { return nil }
            guard let part = m.part.first, !part.key.isEmpty else { return nil }
            let playableOffline = OfflineDownloadDecision.existingVersionPlayableOffline(
                container: part.container ?? m.container,
                videoCodec: m.videoCodec)
            return DownloadExistingVersionOption(
                id: "plex:\(index)",
                label: mediaVersionLabel(m),
                detail: mediaVersionDetail(media: m, part: part),
                sizeBytes: part.size,
                width: m.width,
                height: m.height,
                bitrateKbps: m.bitrate,
                playableOffline: playableOffline,
                target: .plexMediaIndex(index))
        }
    }

    /// Emby Convert-Media copies exposed by an unfiltered PlaybackInfo response. These are addressed
    /// by MediaSource id rather than `Media` index, but use the same disabled-not-hidden offline gate.
    public static func embyOptions(response: EmbyPlaybackInfoResponse,
                                   primaryMediaSourceId: String?) -> [DownloadExistingVersionOption] {
        embyOptions(versions: EmbyPlayback.existingDownloadableVersions(
            response: response,
            primaryMediaSourceId: primaryMediaSourceId))
    }

    public static func embyOptions(versions: [EmbyPlayback.EmbyExistingVersion]) -> [DownloadExistingVersionOption] {
        versions.enumerated().map { index, version in
            let playableOffline = version.supportsDirectPlay
                && OfflineDownloadDecision.existingVersionPlayableOffline(
                    container: version.container,
                    videoCodec: version.videoCodec)
            return DownloadExistingVersionOption(
                id: "emby:\(index):\(version.mediaSourceId)",
                label: embyVersionLabel(version),
                detail: embyVersionDetail(version),
                sizeBytes: version.size,
                width: version.width,
                height: version.height,
                bitrateKbps: version.bitrate.map { $0 / 1_000 },
                playableOffline: playableOffline,
                target: .embyMediaSource(id: version.mediaSourceId, sizeBytes: version.size))
        }
    }

    /// Extract a MediaBrowser MediaSource id from a selected `Media`/`Part` pair. The app sheet and
    /// backend planners both receive PMS-shaped `Part.key` values, so keep this parsing in one place.
    public static func selectedMediaSourceID(media: Media?, part: Part?) -> String? {
        DownloadMediaSelectionPolicy.mediaSourceID(media: media, part: part)
    }

    /// Primary label for a Plex existing-version row: resolution · codec · bitrate.
    public static func mediaVersionLabel(_ media: Media) -> String {
        var parts: [String] = []
        if let res = DownloadResolutionLabel.label(width: media.width, height: media.height) { parts.append(res) }
        if let codec = media.videoCodec?.uppercased(), !codec.isEmpty { parts.append(codec) }
        if let bitrate = media.bitrate, bitrate > 0 {
            parts.append(String(format: "%.1f Mbps", Double(bitrate) / 1000))
        }
        return parts.isEmpty ? "Server version" : parts.joined(separator: " · ")
    }

    /// Secondary Plex caption: container + file size where available.
    public static func mediaVersionDetail(media: Media, part: Part) -> String? {
        var parts: [String] = []
        if let container = (part.container ?? media.container)?.uppercased(), !container.isEmpty {
            parts.append(container)
        }
        if let size = part.size, size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Primary label for an Emby existing-version row: resolution · codec · bitrate (Emby bitrate is
    /// bits/sec). Falls back to the source name, then a generic label.
    public static func embyVersionLabel(_ version: EmbyPlayback.EmbyExistingVersion) -> String {
        var parts: [String] = []
        if let resolution = DownloadResolutionLabel.label(width: version.width, height: version.height) {
            parts.append(resolution)
        }
        if let codec = version.videoCodec?.uppercased(), !codec.isEmpty { parts.append(codec) }
        if let bitrate = version.bitrate, bitrate > 0 {
            parts.append(String(format: "%.1f Mbps", Double(bitrate) / 1_000_000))
        }
        if parts.isEmpty, let name = version.name, !name.isEmpty { return name }
        return parts.isEmpty ? "Server version" : parts.joined(separator: " · ")
    }

    /// Secondary Emby caption: container + file size where available.
    public static func embyVersionDetail(_ version: EmbyPlayback.EmbyExistingVersion) -> String? {
        var parts: [String] = []
        if let container = version.container?.uppercased(), !container.isEmpty { parts.append(container) }
        if let size = version.size, size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
