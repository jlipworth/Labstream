import Foundation

/// Pure text/pill policy for rows in the offline downloads list.
///
/// `DownloadManager` still supplies live facts (active slot, ETA dictionaries, backend auth), but
/// this type owns the backend/lane wording that used to be duplicated inline in the SwiftUI-facing
/// snapshot builder. Keeping it in PMSKit pins the user-visible nuance: server-prepared static files
/// are labelled as optimized artifacts, MediaBrowser compatible lanes say remuxing, and Plex
/// optimize's phase-2 download is a static file while Jellyfin optimize stays live encoder text.
public enum DownloadRowDisplayPolicy {
    /// Semantic route shown by the title badge. Keeping the classification outside SwiftUI makes
    /// the actual badge state share the same persisted lane/provenance rule as captions and tests.
    public enum RouteBadge: String, Sendable, Equatable {
        case original = "Original"
        case optimized = "Optimized"
        case remux = "Remux"
        case transcode = "Transcode"
    }

    public static func routeBadge(lane: DownloadLane,
                                  isServerPreparedVersion: Bool) -> RouteBadge {
        switch lane {
        case .original where isServerPreparedVersion:
            return .optimized
        case .original:
            return .original
        case .compatibleRemux:
            return .remux
        case .optimize:
            return .transcode
        }
    }

    public static func routeBadge(for record: DownloadRecord) -> RouteBadge {
        routeBadge(lane: record.metadata?.resolvedDownloadLane() ?? .original,
                   isServerPreparedVersion: record.metadata?.isServerPreparedVersion == true)
    }

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
            // A server-prepared version rides the `.original` STATIC byte-range lane: it is a
            // finished file on disk, transferred/resumed byte-for-byte like any original — NOT a
            // live server transcode. Label it by that lane ("optimized"), never "transcode", which
            // is reserved for the encoder-gated `.optimize`/`.compatibleRemux` lanes below.
            return "Downloading optimized"
        case .original:
            return "Downloading original"
        case .compatibleRemux:
            return "Remuxing + downloading"
        case .optimize:
            return backend == .plex ? "Downloading transcode" : "Transcoding + downloading"
        }
    }

    public static func pausedCaption(fraction: DownloadProgressDisplay.Fraction?,
                                     bytes: Int,
                                     sideAssetBytes: Int = 0) -> String {
        var pieces = ["Paused — tap to resume"]
        if let fraction { pieces.append(percentText(fraction)) }
        pieces.append(contentsOf: byteBreakdown(mediaBytes: bytes, sideAssetBytes: sideAssetBytes))
        return pieces.joined(separator: " • ")
    }

    public static func completeCaption(isUnverified: Bool,
                                       bytes: Int,
                                       sideAssetBytes: Int = 0,
                                       resolutionLabel: String?) -> String {
        var parts = isUnverified ? ["Downloaded — playback not verified"] : []
        parts.append(contentsOf: byteBreakdown(mediaBytes: bytes, sideAssetBytes: sideAssetBytes))
        if let resolutionLabel { parts.append(resolutionLabel) }
        return parts.joined(separator: " • ")
    }

    /// Keep media bytes (the progress denominator) distinct from posters/subtitles/chapter art.
    /// When extras exist, label both values so a caption cannot imply that percentage and the sum
    /// use the same denominator.
    public static func byteBreakdown(mediaBytes: Int, sideAssetBytes: Int) -> [String] {
        let mediaBytes = max(0, mediaBytes)
        let sideAssetBytes = max(0, sideAssetBytes)
        if sideAssetBytes > 0 {
            var pieces: [String] = []
            if mediaBytes > 0 { pieces.append("\(byteString(mediaBytes)) media") }
            pieces.append("\(byteString(sideAssetBytes)) extras")
            return pieces
        }
        return mediaBytes > 0 ? [byteString(mediaBytes)] : []
    }

    public static func bitrateText(kbps: Int?) -> String? {
        guard let kbps, kbps > 0 else { return nil }
        if kbps < 1_000 { return "\(kbps) Kbps" }
        return String(format: "%.1f Mbps", Double(kbps) / 1_000)
    }

    /// User-facing quality/bitrate text for an offline row.
    ///
    /// A selected bitrate preset is a video-encoder ceiling, while a backend `Media.bitrate`
    /// value may describe the source (and Emby can retain that source value on a converted
    /// MediaSource). Do not mix either value with the finished artifact's bitrate under one
    /// ambiguous `Bitrate:` label. Active rows show the persisted user intent; successful rows
    /// derive an average whole-file bitrate from the actual local media bytes and runtime.
    public static func downloadQualityText(for record: DownloadRecord) -> String? {
        switch record.status {
        case .complete, .unverified:
            guard let kbps = averageDownloadedBitrateKbps(bytes: record.bytes,
                                                          durationMs: record.metadata?.duration),
                  let bitrate = bitrateText(kbps: kbps) else {
                return nil
            }
            return "Downloaded: \(bitrate) avg"
        case .queued, .preparing, .downloading, .failed, .paused:
            return requestedProfileText(record.metadata?.requestedProfileLabel)
        }
    }

    /// Average whole-file/container bitrate in kbps. `Double` conversion happens before
    /// multiplication so multi-gigabyte files cannot overflow `Int` on 32-bit intermediates.
    public static func averageDownloadedBitrateKbps(bytes: Int, durationMs: Int?) -> Int? {
        guard bytes > 0, let durationMs, durationMs > 0 else { return nil }
        let kbps = Double(bytes) * 8.0 / Double(durationMs)
        guard kbps.isFinite, kbps > 0, kbps <= Double(Int.max) else { return nil }
        return Int(kbps.rounded())
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

}
