import Foundation

/// Pure Emby Convert-source selection rules.
///
/// Emby persistent Convert jobs expose their finished output as additional `File` MediaSources on
/// the source item. The app must distinguish the original source from reusable converted siblings,
/// pick a freshly-created source after a completed job, and avoid silently downgrading 4K/Original
/// requests to an older lower-resolution copy. Keep that brittle source-selection policy here so the
/// app layer can focus on item refresh, polling, diagnostics, and the final download handoff.
public enum EmbyConvertedSourcePolicy {
    /// Sources that are eligible for byte-for-byte static download / convert reuse inspection:
    /// non-empty id and on-disk `File` protocol. Older Emby servers may omit `Protocol`; treat that
    /// as file-backed to preserve the historical app behavior.
    public static func fileSources(_ sources: [EmbyMediaSourceInfo]) -> [EmbyMediaSourceInfo] {
        sources.filter { source in
            guard let id = source.id, !id.isEmpty else { return false }
            if let proto = source.mediaProtocol {
                return proto.caseInsensitiveCompare("File") == .orderedSame
            }
            return true
        }
    }

    /// The video height a Convert preset is expected to output. 4K/Original use the custom profile
    /// and should preserve source resolution, so 2160 is a high-water tier hint rather than a cap.
    public static func presetOutputHeight(forLabel label: String) -> Int? {
        let token = label.split(separator: " ").first.map { $0.lowercased() } ?? ""
        switch token {
        case "4k", "2160p": return 2160
        case "1080p":       return 1080
        case "720p":        return 720
        case "480p":        return 480
        default:
            return label.lowercased().hasPrefix("original") ? 2160 : nil
        }
    }

    /// Strict fresh-output detector used while polling after a Convert job completes. A source must
    /// be both outside the pre-conversion snapshot and shaped like a converted output.
    public static func newConvertedSource(_ sources: [EmbyMediaSourceInfo],
                                          excludingSnapshotIDs snapshotIDs: Set<String>) -> EmbyMediaSourceInfo? {
        mostRecent(sources.filter { source in
            guard !snapshotIDs.contains(source.id ?? "") else { return false }
            return looksConverted(source)
        })
    }

    /// Final fallback once the bounded post-completion poll has expired: prefer any new file source,
    /// then the most-recent converted-looking source visible in PlaybackInfo.
    public static func completedSourceFallback(_ sources: [EmbyMediaSourceInfo],
                                               excludingSnapshotIDs snapshotIDs: Set<String>) -> EmbyMediaSourceInfo? {
        let notInSnapshot = sources.filter { !snapshotIDs.contains($0.id ?? "") }
        return mostRecent(notInSnapshot) ?? mostRecent(sources.filter(looksConverted))
    }

    /// Pick an already-existing server-prepared `File` source to reuse for a Convert request.
    ///
    /// For tv-profile tiers (≤1080p), Emby may expose non-ladder output dimensions below the nominal
    /// tier, so falling back to the most-recent converted source no larger than the requested tier is
    /// intentional. For 4K/Original custom-profile requests, require an exact tier match so we don't
    /// silently reuse an older 1080p sibling for a resolution-preserving request.
    public static func reusableSource(_ sources: [EmbyMediaSourceInfo],
                                      requestedHeight: Int?,
                                      primaryMediaSourceID: String?) -> EmbyMediaSourceInfo? {
        guard let requestedHeight,
              let wantedTier = DownloadResolutionLabel.label(width: nil, height: requestedHeight) else {
            return nil
        }
        let converted = sources.filter { $0.id != primaryMediaSourceID && looksConverted($0) }
        if let exact = converted
            .filter({ resolutionLabel(for: $0) == wantedTier })
            .max(by: { recency($0) < recency($1) }) {
            return exact
        }

        guard requestedHeight <= 1080 else { return nil }
        let requestedRank = tierRank(wantedTier)
        return converted
            .filter { tierRank(resolutionLabel(for: $0)) <= requestedRank }
            .max { recency($0) < recency($1) }
    }

    public static func looksConverted(_ source: EmbyMediaSourceInfo) -> Bool {
        if (source.container ?? "").lowercased().contains("mp4") { return true }
        if source.videoCodec?.caseInsensitiveCompare("h264") == .orderedSame { return true }
        if let video = source.mediaStreams.first(where: { $0.type == "Video" }),
           video.codec?.caseInsensitiveCompare("h264") == .orderedSame {
            return true
        }
        return false
    }

    private static func resolutionLabel(for source: EmbyMediaSourceInfo) -> String? {
        let video = source.mediaStreams.first { $0.type == "Video" }
        return DownloadResolutionLabel.label(width: source.width ?? video?.width,
                                             height: source.height ?? video?.height)
    }

    private static func recency(_ source: EmbyMediaSourceInfo) -> Int {
        Int(source.id ?? "") ?? -1
    }

    private static func mostRecent(_ sources: [EmbyMediaSourceInfo]) -> EmbyMediaSourceInfo? {
        sources.max(by: { recency($0) < recency($1) })
    }

    private static func tierRank(_ label: String?) -> Int {
        switch label {
        case "4K":    return 4
        case "1080p": return 3
        case "720p":  return 2
        case "480p":  return 1
        default:      return 0
        }
    }
}
