import Foundation

/// Pure text/pill policy for rows in the offline downloads list.
///
/// `DownloadManager` still supplies live facts (active slot, ETA dictionaries, backend auth), but
/// this type owns the backend/lane wording that used to be duplicated inline in the SwiftUI-facing
/// snapshot builder. Keeping it in PMSKit pins the user-visible nuance: server-prepared static files
/// are labelled as transcodes, MediaBrowser compatible lanes say remuxing, and Plex optimize's
/// phase-2 download is a static transcode file while Jellyfin/Emby optimize stays live encoder text.
public enum DownloadRowDisplayPolicy {
    public static func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    public static func timeLeftString(_ seconds: TimeInterval) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        if seconds < 60 { return "under a min" }
        let totalMinutes = Int((seconds / 60).rounded())
        guard totalMinutes >= 1 else { return nil }
        if totalMinutes < 60 { return "\(totalMinutes) min" }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours < 48 { return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m" }
        let days = hours / 24
        let remainingHours = hours % 24
        return remainingHours == 0 ? "\(days)d" : "\(days)d \(remainingHours)h"
    }

    public static func percentText(_ fraction: DownloadProgressDisplay.Fraction) -> String {
        let pct = "\(Int(fraction.value * 100))%"
        return fraction.isEstimated ? "~\(pct)" : pct
    }

    public static func activeHead(lane: DownloadLane,
                                  backend: DownloadBackendKind,
                                  isServerPreparedVersion: Bool,
                                  isCheckpointPausing: Bool) -> String {
        if isCheckpointPausing { return "Pausing at checkpoint" }
        switch lane {
        case .original where isServerPreparedVersion:
            return "Downloading transcode"
        case .original:
            return "Downloading original"
        case .compatibleRemux:
            return "Remuxing + downloading"
        case .optimize:
            return backend == .plex ? "Downloading transcode" : "Transcoding + downloading"
        }
    }

    public static func pausedCaption(fraction: DownloadProgressDisplay.Fraction?, bytes: Int) -> String {
        var pieces = ["Paused — tap to resume"]
        if let fraction { pieces.append(percentText(fraction)) }
        if bytes > 0 { pieces.append(byteString(bytes)) }
        return pieces.joined(separator: " • ")
    }

    public static func completeCaption(isUnverified: Bool, bytes: Int, resolutionLabel: String?) -> String {
        var parts = isUnverified
            ? ["Downloaded — playback not verified", byteString(bytes)]
            : [byteString(bytes)]
        if let resolutionLabel { parts.append(resolutionLabel) }
        return parts.joined(separator: " • ")
    }
}
