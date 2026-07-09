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

    public static func displayProgress(for record: DownloadRecord,
                                       fraction: DownloadProgressDisplay.Fraction?,
                                       serverPrepProgress: Double?) -> Double? {
        if record.bytes == 0,
           record.metadata?.resolvedResumeMode(ratingKey: record.ratingKey) == .serverPrepThenStatic,
           let serverPrepProgress {
            return max(0, min(serverPrepProgress, 0.999))
        }
        return fraction?.value
    }

    public static func activeHead(lane: DownloadLane,
                                  backend: DownloadBackendKind,
                                  isServerPreparedVersion: Bool) -> String {
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

    public static func bitrateText(kbps: Int?) -> String? {
        guard let kbps, kbps > 0 else { return nil }
        if kbps < 1_000 { return "\(kbps) Kbps" }
        return String(format: "%.1f Mbps", Double(kbps) / 1_000)
    }

    public static func downloadBitrateText(kbps: Int?, requestedProfileLabel: String? = nil) -> String? {
        if let bitrate = bitrateText(kbps: kbps) {
            return "Bitrate: \(bitrate)"
        }
        if let inferred = inferredBitrateKbps(from: requestedProfileLabel),
           let bitrate = bitrateText(kbps: inferred) {
            return "Bitrate: \(bitrate)"
        }
        return nil
    }

    public static func requestedProfileText(_ label: String?) -> String? {
        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty else {
            return nil
        }
        return "Requested: \(label)"
    }

    public static func requestedProfileText(_ label: String?, status: DownloadStatus) -> String? {
        switch status {
        case .complete, .unverified:
            return nil
        case .queued, .preparing, .downloading, .failed, .paused:
            return requestedProfileText(label)
        }
    }

    private static func inferredBitrateKbps(from label: String?) -> Int? {
        guard let label else { return nil }
        let pattern = #"(?i)(\d+(?:\.\d+)?)\s*mbps"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(label.startIndex..<label.endIndex, in: label)
        guard let match = regex.firstMatch(in: label, range: range),
              match.numberOfRanges >= 2,
              let valueRange = Range(match.range(at: 1), in: label),
              let mbps = Double(label[valueRange]) else { return nil }
        return Int((mbps * 1_000).rounded())
    }
}
