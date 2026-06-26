import Foundation

/// Pure matcher for Plex server-optimized ("Plex Versions") download candidates.
///
/// When a Plex optimize/convert render finishes it appears as an additional `Media`/`Part`
/// alongside the original. Picking the right one is subtle: a multi-version library can already
/// hold several compatible parts, and a concurrent/manual version creation for the same item must
/// not win unless it has Plex's optimized-version path shape AND matches the tier the current
/// attempt requested. Plex does not preserve our queue title on the rendered Part, so the match is
/// on the durable media attributes PMS exposes — resolution (as a bounding box) and approximate
/// bitrate — which is exactly what stops a retry that asked for 1080p/8 Mbps from silently reusing
/// an old 720p/3 Mbps render.
///
/// Extracted from `DownloadManager` (GH #135 Stage 1a) so the load-bearing ±16 px / ×1.10+768 kbps
/// slop constants are unit-testable. The app keeps the target-name → settings resolution
/// (`customDownloadProfile`/`mediaSettings`/`isPlexOriginalQualityTarget`) and injects the already
/// resolved values, so this stays a pure function over PMSKit value types.
public enum OptimizedVersionMatch {

    /// A `Part` whose file path is under Plex's optimized-version directory ("Plex Versions").
    /// This is what distinguishes a server-rendered optimized output from an original source part.
    public static func isServerOptimizedPart(_ part: Part) -> Bool {
        guard let file = part.file?.lowercased() else { return false }
        return file.contains("/plex versions/")
    }

    /// Whether an already-rendered `Media` is the same effective target the current attempt
    /// requested. `targetDimensions` / `targetVideoKbps` come from the resolved download settings
    /// (nil = no constraint on that axis); `isOriginalQuality` + `sourceHeight` enforce that an
    /// "original quality" optimize lands at the source height.
    public static func matches(media: Media,
                               targetDimensions: (width: Int, height: Int)?,
                               targetVideoKbps: Int?,
                               isOriginalQuality: Bool,
                               sourceHeight: Int?) -> Bool {
        // Original-quality target: the render must land at (≈) the source height, else it's a
        // down-rezzed reuse masquerading as original.
        if isOriginalQuality, let sourceHeight, let actualHeight = media.height,
           abs(actualHeight - sourceHeight) > 16 {
            return false
        }
        // Treat the target resolution as a bounding box, not an exact output height. Wide
        // CinemaScope-ish sources rendered by a 1080p profile can legitimately come back as e.g.
        // 1920x802: width hits the 1080p target while height preserves aspect ratio. Reject only
        // outputs that exceed the box or land near NEITHER target edge (so an old 720p version is
        // not reused for a 1080p request).
        if let targetDimensions {
            let actualWidth = media.width
            let actualHeight = media.height
            if let actualWidth, actualWidth > targetDimensions.width + 16 { return false }
            if let actualHeight, actualHeight > targetDimensions.height + 16 { return false }
            if let actualWidth, let actualHeight {
                let nearWidth = abs(actualWidth - targetDimensions.width) <= 16
                let nearHeight = abs(actualHeight - targetDimensions.height) <= 16
                if !nearWidth && !nearHeight { return false }
            } else if let actualHeight {
                // Legacy metadata may omit width; keep the old height-only behavior in that case.
                if abs(actualHeight - targetDimensions.height) > 16 { return false }
            }
        }
        // `media.bitrate` is the whole-container rate (video + audio); `targetVideoKbps` caps VIDEO
        // only. Allow the video variance (×1.10) plus a realistic surround-audio ceiling (~768 kbps)
        // so a valid optimized Part isn't judged a mismatch and needlessly re-rendered. The slop
        // stays well under the gap between bitrate-ladder rungs, so 8 vs 10 Mbps is still distinct.
        if let targetVideoKbps, let actualKbps = media.bitrate {
            let allowedKbps = Int(Double(targetVideoKbps) * 1.10) + 768
            if actualKbps > allowedKbps { return false }
        }
        return true
    }

    /// Pick the first NEW server-optimized Part the local/offline player can open: a part whose id
    /// is not in `baselinePartIDs` (the pre-optimize originals), that has the optimized-version path
    /// shape, that is a locally-playable container, on a `Media` whose tier matches the request.
    public static func candidate(from media: [Media],
                                 baselinePartIDs: Set<Int>,
                                 targetDimensions: (width: Int, height: Int)?,
                                 targetVideoKbps: Int?,
                                 isOriginalQuality: Bool,
                                 sourceHeight: Int?) -> Part? {
        for mediaItem in media where matches(media: mediaItem,
                                             targetDimensions: targetDimensions,
                                             targetVideoKbps: targetVideoKbps,
                                             isOriginalQuality: isOriginalQuality,
                                             sourceHeight: sourceHeight) {
            if let part = mediaItem.part.first(where: { part in
                !baselinePartIDs.contains(part.id)
                    && isServerOptimizedPart(part)
                    && OfflineDownloadDecision.isLocallyPlayableOriginal(part: part)
            }) {
                return part
            }
        }
        return nil
    }
}
