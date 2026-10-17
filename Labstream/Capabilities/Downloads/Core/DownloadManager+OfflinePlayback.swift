#if !os(tvOS)
import Foundation
import PMSKit

extension DownloadManager: OfflinePlaybackLaunchFactory {
    /// The manager is the factory; this authority is stable for its entire lifetime.
    var offlinePlaybackLaunchFactory: any OfflinePlaybackLaunchFactory { self }

    func beginPresentationRequest() -> OfflinePlaybackPresentationRequest {
        offlinePresentationGeneration &+= 1
        return .init(generation: offlinePresentationGeneration)
    }

    func makeLaunch(for identity: OfflineDownloadRowActionIdentity,
                    request: OfflinePlaybackPresentationRequest,
                    resumeRewindSeconds: Int) async
        -> Result<OfflinePlaybackLaunch, OfflinePlaybackLaunchRejection> {
        guard request.generation == offlinePresentationGeneration else { return .failure(.supersededPresentation) }
        switch offlineIndexAccess {
        case .unreadable: return .failure(.unreadableIndex)
        case .unsupported: return .failure(.unsupportedIndex)
        case .readable, .admissionBlockedReadable: break
        }
        guard let record = currentRecord(for: identity), let attemptID = record.attemptID else {
            return .failure(.staleAttempt)
        }
        let key = DownloadAttemptKey(ratingKey: record.ratingKey, attemptID: attemptID)
        guard !store.isDeletionPending(for: key) else { return .failure(.deleting) }
        guard record.isComplete else { return .failure(.nonterminal) }
        let url = record.localURL
        let exists = await Task.detached { FileManager.default.fileExists(atPath: url.path) }.value
        // No suspension between this final authority check and handing the launch to its surface.
        guard request.generation == offlinePresentationGeneration else { return .failure(.supersededPresentation) }
        guard let current = currentRecord(for: identity), current.localURL == url else { return .failure(.staleAttempt) }
        guard !store.isDeletionPending(for: key) else { return .failure(.deleting) }
        guard current.isComplete else { return .failure(.nonterminal) }
        guard exists else { return .failure(.missingFile) }
        switch offlineIndexAccess {
        case .unreadable: return .failure(.unreadableIndex)
        case .unsupported: return .failure(.unsupportedIndex)
        case .readable, .admissionBlockedReadable: break
        }
        let backend = current.metadata?.resolvedBackendKind(ratingKey: current.ratingKey)
            ?? DownloadBackendKind(ratingKeyPrefix: current.ratingKey)
        let preview: OfflinePlaybackLaunch.Preview
        switch backend {
        case .plex: preview = .plexBIF(current.plexBIFURL)
        case .jellyfin: preview = .jellyfinTiles(current.jellyfinTrickPlayPlaylistURL)
        case .emby: preview = .embyBIF(current.embyBIFURL)
        }
        let item = DetailPlaybackLauncher.itemWithResumeRewind(
            current.metadata?.makeMediaItem()
                ?? MediaItem(ratingKey: current.ratingKey, title: current.title, type: "movie"),
            resumeRewindSeconds: resumeRewindSeconds)
        return .success(.init(attemptKey: key, presentationRequest: request, fileURL: url,
            item: item, backend: backend, posterURL: current.posterURL,
            artworkSource: OfflineArtworkSource(fileURL: current.posterURL, metadata: current.metadata,
                ratingKey: current.ratingKey), preview: preview,
            chapters: current.metadata?.chapters ?? [], chapterImageURLs: current.chapterImageURLs,
            textSubtitles: current.metadata?.offlineTextSubtitles ?? [], events: makeOfflinePlaybackSink(for: key)))
    }

    func makeOfflinePlaybackSink(for key: DownloadAttemptKey) -> BoundOfflinePlaybackEventSink {
        offlinePlaybackSinks[key]?.supersede()
        let sink = BoundOfflinePlaybackEventSink(attemptKey: key, store: store,
            admitsMutation: { [weak self] in self?.offlineIndexAccess == .readable },
            didResolve: { [weak self] in self?.refreshRecords() })
        offlinePlaybackSinks[key] = sink
        // Retire sinks whose exact row has disappeared; delayed callbacks remain revoked.
        for (oldKey, old) in offlinePlaybackSinks where !store.ownsAttempt(oldKey) {
            old.supersede()
            offlinePlaybackSinks.removeValue(forKey: oldKey)
        }
        return sink
    }

    var offlineIndexAccess: OfflinePlayableIndexAccess {
        switch store.startupIndexAdmission() {
        case .unreadableIndex: return .unreadable
        case .requiresDestructiveReset: return .unsupported
        case .malformedCurrentRows, .seasonCommitIndeterminate: return .admissionBlockedReadable
        case .current:
            if case .blocked = startupRecoveryState { return .admissionBlockedReadable }
            return .readable
        }
    }

    func refreshOfflineAvailability(force: Bool = false) {
        // The initial empty snapshot is unpublished while the worker reads the index. Preserve
        // P7.5's unresolved scan rather than claiming that the durable library is empty.
        if store.startupIndexProbe == nil {
            // A terminal deadline before classification is opaque, not an empty readable library.
            // Resolve the launch gate so session recovery controls can replace the splash.
            guard case .blocked = startupRecoveryState else { return }
            offlineAvailabilityCache.refresh(records: [], access: .unreadable,
                                              force: force, fileExists: offlineFileExists)
            return
        }
        guard startupRecoveryState != .preparing || store.initialStartupSubmission == nil else { return }
        let candidates = records.filter { row in
            guard let attemptID = row.attemptID else { return false }
            return store.ownsAttempt(.init(ratingKey: row.ratingKey, attemptID: attemptID))
        }
        offlineAvailabilityCache.refresh(records: candidates, access: offlineIndexAccess,
                                          force: force, fileExists: offlineFileExists)
    }
}
#endif
