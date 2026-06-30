import Foundation

/// Pure source-part selection for server-prepared Plex optimize rows.
///
/// Optimizer polling needs a stable baseline of source part ids to distinguish a newly-rendered
/// Plex Version from the original media and from older server-generated versions. Newer rows persist
/// the selected source part directly; older rows may carry broader baselines. Keep that compatibility
/// policy in PMSKit so retry/relaunch and enqueue paths share one tested interpretation.
public enum DownloadOptimizeSourcePolicy {
    public static func resumeBaselinePartIDs(metadata: OfflineMetadata, item: MediaItem) -> Set<Int> {
        if let sourcePartID = metadata.sourcePartID { return [sourcePartID] }
        if let mediaIndex = metadata.mediaIndex,
           let partIndex = metadata.partIndex,
           let id = partID(item: item, mediaIndex: mediaIndex, partIndex: partIndex) {
            return [id]
        }
        if let baseline = metadata.optimizeBaselinePartIDs, !baseline.isEmpty {
            return Set(baseline)
        }
        return Set(nonOptimizedPartIDs(item: item))
    }

    public static func sourcePartIDs(item: MediaItem,
                                     fallbackItem: MediaItem,
                                     mediaIndex: Int,
                                     partIndex: Int) -> [Int] {
        let media = selectedMedia(item: item, mediaIndex: mediaIndex)
            ?? selectedMedia(item: fallbackItem, mediaIndex: mediaIndex)
        if let selected = media.flatMap({ part(in: $0, partIndex: partIndex) })?.id {
            return [selected]
        }
        if let ids = media?.part.map(\.id), !ids.isEmpty { return ids }
        let fallback = MediaItem(ratingKey: fallbackItem.ratingKey,
                                 title: fallbackItem.title,
                                 type: fallbackItem.type,
                                 media: item.media ?? fallbackItem.media)
        return nonOptimizedPartIDs(item: fallback)
    }

    /// True when `file` is exactly `directory` or is nested below it.
    ///
    /// Plex library locations are directory roots. Optimizer setup uses this containment check to
    /// identify locations that already hold the original media so it can prefer a different writable
    /// optimized-version location when one exists. Keep the path-boundary semantics here so
    /// `/Movies2/file.mkv` is not treated as a child of `/Movies`.
    public static func filePath(_ file: String, isUnder directory: String) -> Bool {
        let normalizedDirectory = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        return file == normalizedDirectory || file.hasPrefix(normalizedDirectory + "/")
    }

    public static func sourceLocationIDs(sourceFiles: [String],
                                         libraryLocations: [(id: Int, path: String)]) -> Set<Int> {
        Set(libraryLocations.compactMap { location in
            sourceFiles.contains { filePath($0, isUnder: location.path) } ? location.id : nil
        })
    }

    public static func alternateOptimizerLocationID(sourceFiles: [String],
                                                    libraryLocations: [(id: Int, path: String)]) -> Int? {
        let sourceLocationIDs = sourceLocationIDs(sourceFiles: sourceFiles,
                                                  libraryLocations: libraryLocations)
        return libraryLocations.first { !sourceLocationIDs.contains($0.id) }?.id
    }

    private static func selectedMedia(item: MediaItem, mediaIndex: Int) -> Media? {
        guard let media = item.media, media.indices.contains(mediaIndex) else { return nil }
        return media[mediaIndex]
    }

    private static func part(in media: Media, partIndex: Int) -> Part? {
        media.part.indices.contains(partIndex) ? media.part[partIndex] : nil
    }

    private static func partID(item: MediaItem, mediaIndex: Int, partIndex: Int) -> Int? {
        selectedMedia(item: item, mediaIndex: mediaIndex).flatMap { part(in: $0, partIndex: partIndex) }?.id
    }

    private static func nonOptimizedPartIDs(item: MediaItem) -> [Int] {
        (item.media ?? []).flatMap { media in
            media.part.filter { !OptimizedVersionMatch.isServerOptimizedPart($0) }.map(\.id)
        }
    }
}
