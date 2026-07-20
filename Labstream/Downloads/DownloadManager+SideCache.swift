import Foundation
import PMSKit
import os

// GH #135 Stage 5c: the offline SIDE-ASSET caching cluster, split out of the DownloadManager
// god-object into its own file. Behavior-unchanged — the same @MainActor methods (an extension of a
// @MainActor class inherits its isolation), relocated verbatim: poster art (Plex/Jellyfin/Emby),
// text subtitles (Plex/Jellyfin), the Plex BIF trick-play index, and per-chapter images — each a
// best-effort cache that never fails the media download. (Stage 7 will further unify these into one
// fetch→write→persist→refresh helper; this is the file-level separation.)

/// Launch-scoped, in-memory bound on how many times a COMPLETED row's optional side-asset rehydrate
/// re-issues a fetch that never lands. `missingKnownOptionalSideAssetKinds` stays non-empty for the
/// life of a row whose metadata references an optional asset the server can never produce (a 404'd
/// poster, a chapter-thumb ref with no generated thumbnail), so without a bound every
/// foreground/backend-ready/scene-active trigger re-arms the same failing fetch forever. After
/// `maxAttemptsPerLaunch` rehydrate passes leave a given (row, kind) still missing, stop offering
/// that kind until the process restarts. Deliberately in-memory and not persisted: a fresh launch
/// retries once, which is the intended behavior for a genuinely transient (offline) miss.
struct CompletedRowSideAssetRehydrateBudget {
    /// The optional-asset kinds the completed-row scan tracks (mirrors the `metadata`-derived refs
    /// the gate inspects: the poster and the per-chapter thumbnails).
    enum Kind: Hashable { case poster, chapterImages }

    static let maxAttemptsPerLaunch = 5

    private struct Key: Hashable { let ratingKey: String; let kind: Kind }
    private var attempts: [Key: Int] = [:]

    /// Whether this (row, kind) still has retry budget this launch.
    func canOffer(ratingKey: String, kind: Kind) -> Bool {
        (attempts[Key(ratingKey: ratingKey, kind: kind)] ?? 0) < Self.maxAttemptsPerLaunch
    }

    /// Record that a rehydrate pass offered this (row, kind) while it was still missing.
    mutating func recordAttempt(ratingKey: String, kind: Kind) {
        attempts[Key(ratingKey: ratingKey, kind: kind), default: 0] += 1
    }
}

extension DownloadManager {

    /// Retry optional side assets that were cancelled or never finished before media completion.
    ///
    /// Clean-restart retries pass through the normal backend download entry points, which already
    /// enqueue side assets. Resume-data retries do not: they restart URLSession directly and return.
    /// All cache functions are missing-file aware and attempt fenced, so this is safe for a partial
    /// first pass and does not redownload assets that already reached durable storage. Completed-row
    /// scans are limited to rows with a known missing poster/chapter file; unsupported optional
    /// assets must not turn every foreground activation into server traffic. A per-launch budget
    /// (`completedRowSideAssetRehydrateBudget`) stops re-arming a (row, kind) whose asset the server
    /// can never produce, so a permanently-404'd poster/chapter ref does not re-issue forever.
    func rehydrateMissingOptionalSideAssetsForCompletedRows(reason: String) {
        guard !isQueuePaused else { return }
        for record in store.records where record.isComplete {
            guard let attemptID = record.attemptID else { continue }
            let key = DownloadAttemptKey(ratingKey: record.ratingKey, attemptID: attemptID)
            let missing = missingKnownOptionalSideAssetKinds(record: record, attemptKey: key)
            // Only offer kinds that still have per-launch retry budget. A row whose remaining missing
            // kinds have all exhausted their budget stops triggering rehydrate entirely, which is the
            // whole point: `reusableSideAssetRelativePath` never becomes non-nil for an asset the
            // server can't produce, so the missing state alone would re-arm the fetch forever.
            let offerable = missing.filter {
                completedRowSideAssetRehydrateBudget.canOffer(ratingKey: record.ratingKey, kind: $0)
            }
            guard !offerable.isEmpty else { continue }
            // Charge the budget only when a fetch was actually dispatched. Rehydrate bails without
            // issuing work when the row's backend has no live session or a different server is
            // signed in (routine while another backend is active) — burning the launch budget on
            // those passes would permanently block the asset from rehydrating once its own backend
            // comes back, while real dispatched-but-failed fetches still exhaust it as intended.
            guard rehydrateMissingOptionalSideAssets(record: record, attemptKey: key,
                                                     reason: reason) else { continue }
            for kind in offerable {
                completedRowSideAssetRehydrateBudget.recordAttempt(ratingKey: record.ratingKey, kind: kind)
            }
        }
    }

    private func missingKnownOptionalSideAssetKinds(record: DownloadRecord,
                                                    attemptKey: DownloadAttemptKey)
        -> Set<CompletedRowSideAssetRehydrateBudget.Kind> {
        guard let metadata = record.metadata else { return [] }
        let item = metadata.makeMediaItem()
        var kinds: Set<CompletedRowSideAssetRehydrateBudget.Kind> = []
        if DownloadSideAssetPolicy.offlinePosterRef(for: item)?.isEmpty == false,
           store.reusableSideAssetRelativePath(
            for: attemptKey,
            destination: store.posterDestinationURL(ratingKey: record.ratingKey)
           ) == nil {
            kinds.insert(.poster)
        }
        for (index, chapter) in (item.chapters ?? []).enumerated()
            where chapter.thumb?.isEmpty == false {
            if store.reusableSideAssetRelativePath(
                for: attemptKey,
                destination: store.chapterImageDestinationURL(
                    ratingKey: record.ratingKey, index: index)
            ) == nil {
                kinds.insert(.chapterImages)
                break
            }
        }
        return kinds
    }

    /// Returns whether side-asset work was actually dispatched, so the completed-row scan's
    /// per-launch budget only charges for real fetch attempts (see the caller above).
    @discardableResult
    func rehydrateMissingOptionalSideAssets(record: DownloadRecord,
                                            attemptKey: DownloadAttemptKey,
                                            reason: String) -> Bool {
        guard let metadata = record.metadata,
              let backendSession = appModel.backendSession(for: metadata.resolvedBackendKind(
                ratingKey: record.ratingKey)),
              backendSession.matchesPersistedServer(metadata) else { return false }

        let item = metadata.makeMediaItem()
        let server = backendSession.baseURL
        let token = backendSession.token
        let backend = metadata.resolvedBackendKind(ratingKey: record.ratingKey)
        recordDownloadDiagnostic("downloads.side_assets_rehydrate", fields: [
            "download_id": .identifier(record.ratingKey),
            "backend": .label(backend.rawValue),
            "reason": .label(reason),
        ])
        switch backend {
        case .plex:
            // Poster and chapter refs are present in OfflineMetadata, so restart them immediately.
            cachePoster(for: attemptKey, thumb: DownloadSideAssetPolicy.offlinePosterRef(for: item),
                        server: server, token: token)
            cacheChapterImages(for: attemptKey, item: item, backend: .plex,
                               server: server, token: token)

            // Stream/index detail is intentionally not persisted. Refresh the current Plex item
            // before retrying BIF and text subtitles; ownership/status guards prevent a delayed
            // response from reviving work after Delete, Pause, or another terminal failure.
            let mediaIndex = metadata.mediaIndex ?? 0
            let partIndex = metadata.partIndex ?? 0
            downloadWorkRegistry.startIfAbsent(
                for: attemptKey, kind: .sideCache(.sourceMetadataRefresh)
            ) { [weak self] in
                guard let self,
                      !Task.isCancelled,
                      let currentItem = await self.fetchCurrentMediaItem(
                        ratingKey: metadata.ratingKey, server: server, token: token,
                        identity: self.appModel.identity),
                      !Task.isCancelled,
                      let currentRecord = self.store.record(for: attemptKey),
                      currentRecord.status != .failed,
                      currentRecord.status != .paused else { return }
                self.cachePoster(for: attemptKey,
                                 thumb: DownloadSideAssetPolicy.offlinePosterRef(for: currentItem),
                                 server: server, token: token)
                self.cachePlexBIF(for: attemptKey, item: currentItem, mediaIndex: mediaIndex,
                                  server: server, token: token)
                self.cacheChapterImages(for: attemptKey, item: currentItem, backend: .plex,
                                        server: server, token: token)
                if let part = currentItem.media?[safe: mediaIndex]?.part[safe: partIndex] {
                    self.cachePlexTextSubtitles(for: attemptKey, part: part,
                                                server: server, token: token)
                }
            }

        case .jellyfin:
            let identity = appModel.identity.jellyfin
            let itemID = DownloadRecordIdentity.jellyfinItemID(fromRecordKey: record.ratingKey)
            cacheJellyfinPoster(for: attemptKey, item: item, server: server,
                                token: token, identity: identity)
            cacheChapterImages(for: attemptKey, item: item, backend: .jellyfin,
                               server: server, token: token)
            cacheJellyfinTrickPlay(for: attemptKey, itemId: itemID,
                                   mediaSourceId: metadata.mediaSourceID,
                                   server: server, token: token, identity: identity)

        case .emby:
            // No usable user id means no request can be built — report no dispatch so the
            // completed-row budget is not charged for a pass that fetched nothing.
            guard let userID = backendSession.userID, !userID.isEmpty else { return false }
            cacheEmbyPoster(for: attemptKey, item: item, server: server, token: token,
                            identity: appModel.identity.emby, userId: userID)
            cacheChapterImages(for: attemptKey, item: item, backend: .emby,
                               server: server, token: token, userID: userID)
        }
        return true
    }

    /// Lens 4 F2: side assets (posters, text subtitles, chapter images, Plex BIF, JF trickplay)
    /// are DATA-PLANE payloads — multi-MB in aggregate — and must honor the same Wi-Fi-only
    /// download setting as the media transfer itself. Mirrors the transfer engine's
    /// `requestApplyingCellularPolicy` (replicated here; that helper is private to
    /// `BackgroundDownloadSession`). Control-plane requests (keepalive/poll/teardown) stay exempt.
    nonisolated static func sideAssetRequest(applyingCellularPolicy request: URLRequest) -> URLRequest {
        var policyRequest = request
        policyRequest.allowsCellularAccess = PlaybackPreferences.allowsCellularDownloads()
        return policyRequest
    }

    /// Download + cache the item's poster locally so the offline library shows artwork
    /// without the server (D5). Best-effort: any failure leaves the row poster-less and
    /// never fails the download. Fetches via the same `/photo/:/transcode` path the
    /// online `PosterImage` uses, with the same server + token as the media download.
    func cachePoster(for attemptKey: DownloadAttemptKey, thumb: String?, server: URL, token: String) {
        guard let thumb, !thumb.isEmpty,
              let url = Self.posterTranscodeURL(thumb: thumb, server: server, token: token)
        else { return }
        // Plex carries the token in-query, so a bare `URLRequest(url:)` authenticates the fetch.
        cachePoster(for: attemptKey, request: URLRequest(url: url))
    }

    /// #135 Stage 7: shared poster-cache tail for all three backends. Fetch the (already
    /// backend-authenticated) request OFF the main actor — mirrors `PlaybackController.fetchArtworkData`
    /// — atomically write it to the row's poster destination, and on success record the relative path
    /// + refresh on the main actor. Best-effort: a nil request or any fetch/write failure leaves the
    /// row poster-less and never fails the download. The three public entry points differ ONLY in how
    /// they build the request (Plex token-in-query URL vs Jellyfin/Emby authenticated header request
    /// with a primary→backdrop ref fallback), so that is all they do before delegating here.
    private func cachePoster(for attemptKey: DownloadAttemptKey, request: URLRequest?) {
        guard let request else { return }
        let posterURL = store.posterDestinationURL(ratingKey: attemptKey.ratingKey)
        if store.reusableSideAssetRelativePath(for: attemptKey, destination: posterURL) != nil { return }
        guard let stagingURL = store.attemptStagingURL(for: attemptKey, stableURL: posterURL) else { return }
        let store = self.store
        downloadWorkRegistry.startIfAbsent(for: attemptKey, kind: .sideCache(.poster)) { [weak self] in
            guard let self, !Task.isCancelled else { return }
            defer { try? FileManager.default.removeItem(at: stagingURL) }
            guard let data = try? await self.fetchOptionalSideAsset(request, for: attemptKey),
                  (try? data.write(to: stagingURL, options: .atomic)) != nil,
                  !Task.isCancelled,
                  Self.promoteSideAsset(store: store, key: attemptKey,
                                        stagingURL: stagingURL, stableURL: posterURL) else { return }
            await MainActor.run {
                let result = store.updateMetadata(for: attemptKey) {
                    $0.posterRelativePath = posterURL.lastPathComponent
                }
                if result == .applied || result == .noChange { self.refreshRecords() }
            }
        }
    }

    /// Best-effort cache of a Jellyfin item's poster so the offline library shows artwork
    /// without the server (#102). Mirrors `cacheJellyfinTrickPlay` (authenticated,
    /// off-main-actor side-asset cache). Resolves the item's inline synthetic Primary ref
    /// (`item.thumb`), falling back to the Backdrop ref (`item.art`); a fetch failure
    /// leaves the row poster-less and never fails the download.
    func cacheJellyfinPoster(for attemptKey: DownloadAttemptKey, item: MediaItem, server: URL,
                                     token: String, identity: JellyfinClientIdentity) {
        let primaryRef = DownloadSideAssetPolicy.offlinePosterRef(for: item)
        let request = (try? JellyfinLibrary.posterRequest(syntheticRef: primaryRef, server: server,
                                                          token: token, identity: identity))
            ?? (try? JellyfinLibrary.posterRequest(syntheticRef: item.art, server: server,
                                                   token: token, identity: identity))
        cachePoster(for: attemptKey, request: request)
    }

    /// Best-effort cache of an Emby item's poster (#102). Same shape as
    /// `cacheJellyfinPoster`, but the Emby image endpoint additionally needs `userId` on
    /// the authenticated request.
    func cacheEmbyPoster(for attemptKey: DownloadAttemptKey, item: MediaItem, server: URL,
                                 token: String, identity: EmbyClientIdentity, userId: String) {
        let primaryRef = DownloadSideAssetPolicy.offlinePosterRef(for: item)
        let request = (try? EmbyLibrary.posterRequest(syntheticRef: primaryRef, server: server,
                                                      token: token, identity: identity, userId: userId))
            ?? (try? EmbyLibrary.posterRequest(syntheticRef: item.art, server: server,
                                               token: token, identity: identity, userId: userId))
        cachePoster(for: attemptKey, request: request)
    }

    /// Build the `/photo/:/transcode` URL for an image path via the shared `PlexPhotoTranscode`
    /// builder. Requests a poster-sized image so the cached file stays small.
    private static func posterTranscodeURL(thumb: String, server: URL, token: String) -> URL? {
        PlexPhotoTranscode.url(server: server, token: token, imagePath: thumb,
                               width: 400, height: 600)
    }

    func cachePlexTextSubtitles(for attemptKey: DownloadAttemptKey, part: Part, server: URL, token: String) {
        // Resolve each compatible subtitle stream into its request/destination/track on the main
        // actor (`stream` stays inferred — the PMSKit `Stream` type can't be spelled here without
        // colliding with `Foundation.Stream`). The `.track` is pure and its inputs are all known up
        // front, so it is computed now and the shared tail just gates it on a successful fetch.
        let pending: [PendingSubtitle] = part.subtitleStreams.enumerated()
            .filter { OfflineTextSubtitleCachePlanner.isCompatibleTextSubtitle($0.element) }
            .compactMap { fallbackIndex, stream in
                guard let key = stream.key,
                      let url = Self.plexSubtitleURL(server: server, token: token, key: key) else { return nil }
                let ext = OfflineTextSubtitleCachePlanner.fileExtension(for: stream)
                let destination = store.textSubtitleDestinationURL(ratingKey: attemptKey.ratingKey, streamID: stream.id, ext: ext)
                guard let staging = store.attemptStagingURL(for: attemptKey, stableURL: destination) else { return nil }
                return PendingSubtitle(
                    request: URLRequest(url: url), destination: destination, staging: staging,
                    track: OfflineTextSubtitleCachePlanner.track(for: stream,
                                                                 relativePath: destination.lastPathComponent,
                                                                 fallbackIndex: fallbackIndex))
            }
        cacheTextSubtitles(for: attemptKey, pending: pending)
    }

    func cacheJellyfinTextSubtitles(for attemptKey: DownloadAttemptKey,
                                           itemId: String,
                                           mediaSourceId: String?,
                                           part: Part?,
                                           server: URL,
                                           token: String,
                                           identity: JellyfinClientIdentity) {
        guard let mediaSourceId, !mediaSourceId.isEmpty, let part else { return }
        let pending: [PendingSubtitle] = part.subtitleStreams.enumerated()
            .filter { OfflineTextSubtitleCachePlanner.isCompatibleTextSubtitle($0.element) }
            .compactMap { fallbackIndex, stream in
                let ext = OfflineTextSubtitleCachePlanner.fileExtension(for: stream)
                let streamIndex = stream.index ?? stream.id
                guard let request = try? JellyfinLibrary.textSubtitleRequest(server: server, token: token,
                                                                             identity: identity, itemId: itemId,
                                                                             mediaSourceId: mediaSourceId,
                                                                             streamIndex: streamIndex, format: ext)
                else { return nil }
                let destination = store.textSubtitleDestinationURL(ratingKey: attemptKey.ratingKey, streamID: stream.id, ext: ext)
                guard let staging = store.attemptStagingURL(for: attemptKey, stableURL: destination) else { return nil }
                return PendingSubtitle(
                    request: request, destination: destination, staging: staging,
                    track: OfflineTextSubtitleCachePlanner.track(for: stream,
                                                                 relativePath: destination.lastPathComponent,
                                                                 fallbackIndex: fallbackIndex))
            }
        cacheTextSubtitles(for: attemptKey, pending: pending)
    }

    func cacheEmbyTextSubtitles(for attemptKey: DownloadAttemptKey,
                                itemId: String,
                                mediaSourceId: String?,
                                part: Part?,
                                server: URL,
                                token: String,
                                identity: EmbyClientIdentity,
                                userId: String) {
        guard let mediaSourceId, !mediaSourceId.isEmpty, let part else { return }
        let pending: [PendingSubtitle] = part.subtitleStreams.enumerated()
            .filter { OfflineTextSubtitleCachePlanner.isCompatibleTextSubtitle($0.element) }
            .compactMap { fallbackIndex, stream in
                let ext = OfflineTextSubtitleCachePlanner.fileExtension(for: stream)
                let streamIndex = stream.index ?? stream.id
                guard let request = try? EmbyLibrary.textSubtitleRequest(server: server, token: token,
                                                                         identity: identity, userId: userId,
                                                                         itemId: itemId,
                                                                         mediaSourceId: mediaSourceId,
                                                                         streamIndex: streamIndex, format: ext)
                else { return nil }
                let destination = store.textSubtitleDestinationURL(ratingKey: attemptKey.ratingKey, streamID: stream.id, ext: ext)
                guard let staging = store.attemptStagingURL(for: attemptKey, stableURL: destination) else { return nil }
                return PendingSubtitle(
                    request: request, destination: destination, staging: staging,
                    track: OfflineTextSubtitleCachePlanner.track(for: stream,
                                                                 relativePath: destination.lastPathComponent,
                                                                 fallbackIndex: fallbackIndex))
            }
        cacheTextSubtitles(for: attemptKey, pending: pending)
    }

    /// One compatible text-subtitle stream resolved into the work needed to cache it offline: the
    /// already-backend-authenticated request, the on-disk destination, and the pre-computed
    /// `OfflineTextSubtitleTrack` (pure; its inputs are known before the fetch). Deliberately carries
    /// no `Stream` so the shared tail names no PMSKit type that collides with `Foundation.Stream`.
    private struct PendingSubtitle: Sendable {
        let request: URLRequest
        let destination: URL
        let staging: URL
        let track: OfflineTextSubtitleTrack?
    }

    /// #135 Stage 7: shared text-subtitle cache tail for Plex and Jellyfin. Fetch+write each
    /// pre-resolved sidecar OFF the main actor; a stream that fails is skipped, and on success its
    /// pre-computed track is accumulated. Persist the lot + refresh if any landed. Best-effort — the
    /// whole cache failing never fails the media download. The two public entry points differ ONLY in
    /// how each stream's request is built (Plex token-in-query URL from the stream key; Jellyfin
    /// authenticated request by stream index), so that is all they resolve before delegating.
    private func cacheTextSubtitles(for attemptKey: DownloadAttemptKey, pending: [PendingSubtitle]) {
        guard !pending.isEmpty else { return }
        let store = self.store
        downloadWorkRegistry.startIfAbsent(for: attemptKey, kind: .sideCache(.textSubtitles)) { [weak self] in
            guard let self else { return }
            var tracks: [OfflineTextSubtitleTrack] = []
            for item in pending {
                guard !Task.isCancelled else { return }
                if store.reusableSideAssetRelativePath(for: attemptKey,
                                                       destination: item.destination) != nil {
                    if let track = item.track { tracks.append(track) }
                    continue
                }
                defer { try? FileManager.default.removeItem(at: item.staging) }
                guard let data = try? await self.fetchOptionalSideAsset(item.request, for: attemptKey),
                      Self.validTextSubtitleData(data),
                      (try? data.write(to: item.staging, options: .atomic)) != nil,
                      !Task.isCancelled,
                      Self.promoteSideAsset(store: store, key: attemptKey,
                                            stagingURL: item.staging, stableURL: item.destination)
                else { continue }
                if let track = item.track {
                    tracks.append(track)
                    _ = store.updateMetadata(for: attemptKey) {
                        var merged = $0.offlineTextSubtitles ?? []
                        if !merged.contains(where: { $0.relativePath == track.relativePath }) {
                            merged.append(track)
                        }
                        $0.offlineTextSubtitles = merged
                    }
                }
            }
            guard !tracks.isEmpty else { return }
            await MainActor.run {
                let result = store.updateMetadata(for: attemptKey) {
                    var merged = $0.offlineTextSubtitles ?? []
                    for track in tracks where !merged.contains(where: { $0.relativePath == track.relativePath }) {
                        merged.append(track)
                    }
                    $0.offlineTextSubtitles = merged
                }
                if result == .applied || result == .noChange { self.refreshRecords() }
            }
        }
    }

    private nonisolated static func plexSubtitleURL(server: URL, token: String, key: String) -> URL? {
        let raw = key.hasPrefix("/") ? key : "/\(key)"
        guard var comps = URLComponents(url: server.appendingPathComponent(raw), resolvingAgainstBaseURL: false) else { return nil }
        // Drop any token the key already carried, then append the token through the project's strict
        // encoder so it is percent-encoded consistently with every other Plex URL builder.
        if var items = comps.queryItems {
            items.removeAll { $0.name.caseInsensitiveCompare("X-Plex-Token") == .orderedSame }
            comps.queryItems = items.isEmpty ? nil : items
        }
        PlexURLQueryEncoder.appendQueryItems([.init(name: "X-Plex-Token", value: token)], to: &comps)
        return comps.url
    }

    private nonisolated static func validTextSubtitleData(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return !OfflineTextSubtitleParser.parse(text).isEmpty
    }

    /// Download + cache Plex's BIF trick-play index for the selected source Part so the
    /// local custom player can keep showing scrub previews fully offline (#78). Best-effort:
    /// a missing/invalid BIF never fails the media download. The request carries the token in
    /// query, so do not log the URL or surfaced error.
    func cachePlexBIF(for attemptKey: DownloadAttemptKey, item: MediaItem, mediaIndex: Int,
                              server: URL, token: String) {
        guard let part = DownloadSideAssetPolicy.selectedPlexBIFPart(from: item, mediaIndex: mediaIndex) else { return }
        let destination = store.plexBIFDestinationURL(ratingKey: attemptKey.ratingKey)
        if store.reusableSideAssetRelativePath(for: attemptKey, destination: destination) != nil { return }
        guard let staging = store.attemptStagingURL(for: attemptKey, stableURL: destination) else { return }
        let request = TrickPlayRequest.plexBIFIndex(server: server,
                                                    token: token,
                                                    identity: appModel.identity,
                                                    partID: part.id,
                                                    quality: "sd")
        // Data-plane side asset (a BIF can be tens of MB): fetch through a URLRequest so the
        // Wi-Fi-only download policy can be stamped, instead of the shared PlexClient.
        let bifRequest = Self.sideAssetRequest(applyingCellularPolicy: request.urlRequest())
        let store = self.store
        downloadWorkRegistry.startIfAbsent(for: attemptKey, kind: .sideCache(.plexBIF)) { [weak self] in
            guard let self, !Task.isCancelled else { return }
            defer { try? FileManager.default.removeItem(at: staging) }
            do {
                let data = try await self.fetchOptionalSideAsset(bifRequest, for: attemptKey)
                guard !data.isEmpty, (try? BIFParser.parse(data)) != nil else { return }
                try data.write(to: staging, options: .atomic)
                guard !Task.isCancelled,
                      Self.promoteSideAsset(store: store, key: attemptKey,
                                            stagingURL: staging, stableURL: destination) else { return }
                await MainActor.run {
                    let result = store.updateMetadata(for: attemptKey) {
                        $0.plexBIFRelativePath = destination.lastPathComponent
                    }
                    if result == .applied || result == .noChange { self.refreshRecords() }
                }
            } catch {
                // Expected for items/servers without BIFs, auth churn, or cache races.
                // Keep silent and never log token-bearing URLs.
            }
        }
    }

    /// Download + cache each chapter's image at download time so the offline Chapters menu rail
    /// shows real per-chapter thumbnails (#88) and the Emby offline scrubber has a coarse preview
    /// source (#89). One shared index-keyed cache feeds both consumers.
    ///
    /// Best-effort, exactly like `cachePlexBIF`/`cacheJellyfinTrickPlay`: a failed image is simply
    /// dropped (that chapter shows the online-equivalent placeholder offline), and the whole cache
    /// failing never fails the media download. Each backend builds the same image URL its online
    /// chapter resolver uses (Plex `/photo/:/transcode`; Jellyfin/Emby chapter-image endpoint). The
    /// requests carry tokens (Plex in query, JF/Emby in headers) so URLs are never logged.
    func cacheChapterImages(for attemptKey: DownloadAttemptKey, item: MediaItem, backend: DownloadBackendKind,
                                    server: URL, token: String, userID: String? = nil) {
        let chapters = item.chapters ?? []
        guard !chapters.isEmpty else { return }
        // Build (chapter index, request) for every chapter that carries an image key. The index is
        // the chapter's position in `chapters` — the same enumeration the Chapters rail and the
        // offline scrub provider use, so it is the stable join key offline.
        let identity = appModel.identity
        var requests: [(index: Int, request: URLRequest, destination: URL)] = []
        for (index, chapter) in chapters.enumerated() {
            guard let thumb = chapter.thumb, !thumb.isEmpty else { continue }
            switch backend {
            case .plex:
                guard let url = PlexPhotoTranscode.url(server: server, token: token, imagePath: thumb,
                                                       width: 480, height: 270) else { continue }
                requests.append((index, URLRequest(url: url),
                                 store.chapterImageDestinationURL(ratingKey: attemptKey.ratingKey,
                                                                  index: index)))
            case .jellyfin:
                guard let parsed = DownloadSideAssetPolicy.parsedSyntheticChapterImageKey(thumb, scheme: "jellyfin"),
                      let url = try? JellyfinLibrary.chapterImageURL(server: server, itemId: parsed.itemID,
                                                                    chapterIndex: parsed.index, tag: parsed.tag,
                                                                    width: 480, height: 270) else { continue }
                var req = JellyfinLibrary.authenticatedRequest(url: url, token: token, identity: identity.jellyfin)
                req.setValue("*/*", forHTTPHeaderField: "Accept")
                requests.append((index, req,
                                 store.chapterImageDestinationURL(ratingKey: attemptKey.ratingKey,
                                                                  index: index)))
            case .emby:
                guard let parsed = DownloadSideAssetPolicy.parsedSyntheticChapterImageKey(thumb, scheme: "emby"),
                      let url = try? EmbyLibrary.chapterImageURL(server: server, itemId: parsed.itemID,
                                                               chapterIndex: parsed.index, tag: parsed.tag,
                                                               width: 480, height: 270) else { continue }
                var req = EmbyLibrary.authenticatedRequest(url: url, token: token,
                                                            identity: identity.emby, userId: userID)
                req.setValue("*/*", forHTTPHeaderField: "Accept")
                requests.append((index, req,
                                 store.chapterImageDestinationURL(ratingKey: attemptKey.ratingKey,
                                                                  index: index)))
            }
        }
        guard !requests.isEmpty else { return }
        var reusableRelatives: [Int: String] = [:]
        let pendingRequests = requests.filter { entry in
            if let relative = store.reusableSideAssetRelativePath(
                for: attemptKey, destination: entry.destination) {
                reusableRelatives[entry.index] = relative
                return false
            }
            return true
        }
        guard !pendingRequests.isEmpty || !reusableRelatives.isEmpty else { return }
        let store = self.store
        downloadWorkRegistry.startIfAbsent(for: attemptKey, kind: .sideCache(.chapterImages)) { [weak self] in
            guard let self else { return }
            let policy = SideAssetRequestPolicy.conservativeDefault
            if pendingRequests.count > policy.maximumConcurrentRequests {
                await MainActor.run {
                    self.recordDownloadDiagnostic("downloads.side_cache_throttled", fields: [
                        "download_id": .identifier(attemptKey.ratingKey),
                        "asset": .label("chapter_images"),
                        "request_count": .int(pendingRequests.count),
                        "maximum_concurrency": .int(policy.maximumConcurrentRequests),
                        "maximum_starts_per_second": .double(policy.maximumRequestStartsPerSecond),
                    ])
                }
            }
            var relativesByIndex = reusableRelatives
            var downloadedCount = 0
            var failedCount = 0
            await withTaskGroup(
                of: (Int, URL, Data)?.self
            ) { group in
                for entry in pendingRequests {
                    group.addTask {
                        guard let data = try? await self.fetchOptionalSideAsset(
                            entry.request, for: attemptKey) else { return nil }
                        return (entry.index, entry.destination, data)
                    }
                }
                for await result in group {
                    guard let (index, destination, data) = result else {
                        failedCount += 1
                        continue
                    }
                    guard
                          !Task.isCancelled,
                          let staging = store.attemptStagingURL(
                            for: attemptKey, stableURL: destination) else {
                        failedCount += 1
                        continue
                    }
                    defer { try? FileManager.default.removeItem(at: staging) }
                    guard (try? data.write(to: staging, options: .atomic)) != nil,
                          Self.promoteSideAsset(store: store, key: attemptKey,
                                                stagingURL: staging, stableURL: destination) else {
                        failedCount += 1
                        continue
                    }
                    let relative = destination.lastPathComponent
                    downloadedCount += 1
                    relativesByIndex[index] = relative
                    _ = store.updateMetadata(for: attemptKey) {
                        var merged = $0.chapterImageRelativePaths ?? [:]
                        merged[index] = relative
                        $0.chapterImageRelativePaths = merged
                    }
                }
            }
            await MainActor.run {
                self.recordDownloadDiagnostic("downloads.side_cache_complete", fields: [
                    "download_id": .identifier(attemptKey.ratingKey),
                    "asset": .label("chapter_images"),
                    "requested_count": .int(pendingRequests.count),
                    "downloaded_count": .int(downloadedCount),
                    "reused_count": .int(reusableRelatives.count),
                    "failed_count": .int(failedCount),
                ])
            }
            guard !relativesByIndex.isEmpty else { return }
            await MainActor.run {
                let result = store.updateMetadata(for: attemptKey) {
                    var merged = $0.chapterImageRelativePaths ?? [:]
                    merged.merge(relativesByIndex) { _, current in current }
                    $0.chapterImageRelativePaths = merged
                }
                if result == .applied || result == .noChange { self.refreshRecords() }
            }
        }
    }

    /// Shared stale-tail boundary. Always removes only this attempt's derived staging file; a
    /// rejected stale promotion never touches the stable destination owned by a newer attempt.
    nonisolated static func promoteSideAsset(store: DownloadStore, key: DownloadAttemptKey,
                                             stagingURL: URL, stableURL: URL) -> Bool {
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        guard !Task.isCancelled else { return false }
        return store.promoteAttemptStagingFile(for: key, stagingURL: stagingURL, to: stableURL)
            == .promoted
    }
}
