import Foundation

/// Pure persisted metadata builder for a new offline download row.
///
/// The app layer resolves backend sessions, chosen media/part indices, source URLs, and side effects;
/// this builder owns the durable snapshot contract: item fields copied into `OfflineMetadata`, source
/// part identity/size, per-job backend session identity, lane fallback, resume mode, and the
/// server-prepared display flag.
public enum DownloadOfflineMetadataBuilder {
    public static func metadata(from item: MediaItem,
                                resolutionLabel: String?,
                                requestedProfileLabel: String? = nil,
                                mediaIndex: Int,
                                partIndex: Int,
                                optimizeTargetName: String? = nil,
                                optimizeQueueTitle: String? = nil,
                                session: BackendSession,
                                mediaSourceID: String? = nil,
                                downloadLane: DownloadLane? = nil,
                                serverPreparedVersion: Bool = false) -> OfflineMetadata {
        let media = item.media
        let sourceMedia = media?.indices.contains(mediaIndex) == true ? media?[mediaIndex] : nil
        let sourcePart = sourceMedia?.part.indices.contains(partIndex) == true ? sourceMedia?.part[partIndex] : nil
        let lane = downloadLane ?? ((optimizeTargetName?.isEmpty == false) ? .optimize : .original)
        let resumeMode = DownloadResumeMode.resolved(backend: session.kind,
                                                     lane: lane,
                                                     optimizeTargetName: optimizeTargetName)
        return OfflineMetadata(ratingKey: item.ratingKey,
                               key: item.key,
                               title: item.title,
                               type: item.type,
                               year: item.year,
                               duration: item.duration,
                               viewOffset: item.viewOffset,
                               viewCount: item.viewCount,
                               summary: item.summary,
                               contentRating: item.contentRating,
                               tagline: item.tagline,
                               grandparentTitle: item.grandparentTitle,
                               grandparentRatingKey: item.grandparentRatingKey,
                               grandparentThumb: item.grandparentThumb,
                               parentTitle: item.parentTitle,
                               parentRatingKey: item.parentRatingKey,
                               parentThumb: item.parentThumb,
                               parentIndex: item.parentIndex,
                               index: item.index,
                               thumb: item.thumb,
                               art: item.art,
                               chapters: item.chapters?.map(OfflineChapter.init),
                               markers: item.markers?.map(OfflineMarker.init),
                               resolutionLabel: resolutionLabel,
                               requestedProfileLabel: requestedProfileLabel,
                               librarySectionID: item.librarySectionID,
                               librarySectionKey: item.librarySectionKey,
                               mediaIndex: mediaIndex,
                               partIndex: partIndex,
                               sourcePartID: sourcePart?.id,
                               sourcePartSize: sourcePart?.size,
                               optimizeTargetName: optimizeTargetName,
                               optimizeQueueTitle: optimizeQueueTitle,
                               posterRelativePath: nil,
                               backendKind: session.kind,
                               backendBaseURLString: session.baseURL.absoluteString,
                               backendServerID: session.serverID,
                               backendUserID: session.userID,
                               mediaSourceID: mediaSourceID,
                               playSessionID: nil,
                               downloadLane: downloadLane,
                               resumeMode: resumeMode,
                               serverPreparedVersion: serverPreparedVersion ? true : nil)
    }
}
