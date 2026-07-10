import Foundation
import PMSKit
import os

// GH #135 Stage 5c: the offline SIDE-ASSET caching cluster, split out of the DownloadManager
// god-object into its own file. Behavior-unchanged — the same @MainActor methods (an extension of a
// @MainActor class inherits its isolation), relocated verbatim: poster art (Plex/Jellyfin/Emby),
// text subtitles (Plex/Jellyfin), the Plex BIF trick-play index, and per-chapter images — each a
// best-effort cache that never fails the media download. (Stage 7 will further unify these into one
// fetch→write→persist→refresh helper; this is the file-level separation.)

extension DownloadManager {

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
    func cachePoster(ratingKey: String, thumb: String?, server: URL, token: String) {
        guard let thumb, !thumb.isEmpty,
              let url = Self.posterTranscodeURL(thumb: thumb, server: server, token: token)
        else { return }
        // Plex carries the token in-query, so a bare `URLRequest(url:)` authenticates the fetch.
        cachePoster(ratingKey: ratingKey, request: URLRequest(url: url))
    }

    /// #135 Stage 7: shared poster-cache tail for all three backends. Fetch the (already
    /// backend-authenticated) request OFF the main actor — mirrors `PlaybackController.fetchArtworkData`
    /// — atomically write it to the row's poster destination, and on success record the relative path
    /// + refresh on the main actor. Best-effort: a nil request or any fetch/write failure leaves the
    /// row poster-less and never fails the download. The three public entry points differ ONLY in how
    /// they build the request (Plex token-in-query URL vs Jellyfin/Emby authenticated header request
    /// with a primary→backdrop ref fallback), so that is all they do before delegating here.
    private func cachePoster(ratingKey: String, request: URLRequest?) {
        guard let request else { return }
        let posterURL = store.posterDestinationURL(ratingKey: ratingKey)
        let store = self.store
        Task { [weak self] in
            guard await Self.fetchAndWritePoster(request: request, to: posterURL) else { return }
            await MainActor.run {
                store.setPosterRelativePath(ratingKey: ratingKey, posterURL.lastPathComponent)
                self?.refreshRecords()
            }
        }
    }

    /// Best-effort poster fetch + atomic write, fully off the main actor, driven by a pre-resolved
    /// `URLRequest`. Returns `true` only when a non-empty poster landed on disk at `destination`; any
    /// failure (HTTP error, empty body, write failure) returns `false` and is never surfaced — a
    /// missing poster is never a download error. Plex authenticates via token-in-query (a bare
    /// `URLRequest(url:)`); the MediaBrowser (Jellyfin/Emby) image endpoints instead need the
    /// `Authorization` header (Emby also `userId`) that `*.authenticatedRequest(...)` attaches.
    private nonisolated static func fetchAndWritePoster(request: URLRequest, to destination: URL) async -> Bool {
        do {
            let (data, response) = try await URLSession.shared.data(
                for: sideAssetRequest(applyingCellularPolicy: request))
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) { return false }
            guard !data.isEmpty else { return false }
            try data.write(to: destination, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Best-effort cache of a Jellyfin item's poster so the offline library shows artwork
    /// without the server (#102). Mirrors `cacheJellyfinTrickPlay` (authenticated,
    /// off-main-actor side-asset cache). Resolves the item's inline synthetic Primary ref
    /// (`item.thumb`), falling back to the Backdrop ref (`item.art`); a fetch failure
    /// leaves the row poster-less and never fails the download.
    func cacheJellyfinPoster(ratingKey: String, item: MediaItem, server: URL,
                                     token: String, identity: JellyfinClientIdentity) {
        let primaryRef = DownloadSideAssetPolicy.offlinePosterRef(for: item)
        let request = (try? JellyfinLibrary.posterRequest(syntheticRef: primaryRef, server: server,
                                                          token: token, identity: identity))
            ?? (try? JellyfinLibrary.posterRequest(syntheticRef: item.art, server: server,
                                                   token: token, identity: identity))
        cachePoster(ratingKey: ratingKey, request: request)
    }

    /// Best-effort cache of an Emby item's poster (#102). Same shape as
    /// `cacheJellyfinPoster`, but the Emby image endpoint additionally needs `userId` on
    /// the authenticated request.
    func cacheEmbyPoster(ratingKey: String, item: MediaItem, server: URL,
                                 token: String, identity: EmbyClientIdentity, userId: String) {
        let primaryRef = DownloadSideAssetPolicy.offlinePosterRef(for: item)
        let request = (try? EmbyLibrary.posterRequest(syntheticRef: primaryRef, server: server,
                                                      token: token, identity: identity, userId: userId))
            ?? (try? EmbyLibrary.posterRequest(syntheticRef: item.art, server: server,
                                               token: token, identity: identity, userId: userId))
        cachePoster(ratingKey: ratingKey, request: request)
    }

    /// Build the `/photo/:/transcode` URL for an image path via the shared `PlexPhotoTranscode`
    /// builder. Requests a poster-sized image so the cached file stays small.
    private static func posterTranscodeURL(thumb: String, server: URL, token: String) -> URL? {
        PlexPhotoTranscode.url(server: server, token: token, imagePath: thumb,
                               width: 400, height: 600)
    }

    func cachePlexTextSubtitles(ratingKey: String, part: Part, server: URL, token: String) {
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
                let destination = store.textSubtitleDestinationURL(ratingKey: ratingKey, streamID: stream.id, ext: ext)
                return PendingSubtitle(
                    request: URLRequest(url: url), destination: destination,
                    track: OfflineTextSubtitleCachePlanner.track(for: stream,
                                                                 relativePath: destination.lastPathComponent,
                                                                 fallbackIndex: fallbackIndex))
            }
        cacheTextSubtitles(ratingKey: ratingKey, pending: pending)
    }

    func cacheJellyfinTextSubtitles(ratingKey: String,
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
                let destination = store.textSubtitleDestinationURL(ratingKey: ratingKey, streamID: stream.id, ext: ext)
                return PendingSubtitle(
                    request: request, destination: destination,
                    track: OfflineTextSubtitleCachePlanner.track(for: stream,
                                                                 relativePath: destination.lastPathComponent,
                                                                 fallbackIndex: fallbackIndex))
            }
        cacheTextSubtitles(ratingKey: ratingKey, pending: pending)
    }

    func cacheEmbyTextSubtitles(ratingKey: String,
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
                let destination = store.textSubtitleDestinationURL(ratingKey: ratingKey, streamID: stream.id, ext: ext)
                return PendingSubtitle(
                    request: request, destination: destination,
                    track: OfflineTextSubtitleCachePlanner.track(for: stream,
                                                                 relativePath: destination.lastPathComponent,
                                                                 fallbackIndex: fallbackIndex))
            }
        cacheTextSubtitles(ratingKey: ratingKey, pending: pending)
    }

    /// One compatible text-subtitle stream resolved into the work needed to cache it offline: the
    /// already-backend-authenticated request, the on-disk destination, and the pre-computed
    /// `OfflineTextSubtitleTrack` (pure; its inputs are known before the fetch). Deliberately carries
    /// no `Stream` so the shared tail names no PMSKit type that collides with `Foundation.Stream`.
    private struct PendingSubtitle {
        let request: URLRequest
        let destination: URL
        let track: OfflineTextSubtitleTrack?
    }

    /// #135 Stage 7: shared text-subtitle cache tail for Plex and Jellyfin. Fetch+write each
    /// pre-resolved sidecar OFF the main actor; a stream that fails is skipped, and on success its
    /// pre-computed track is accumulated. Persist the lot + refresh if any landed. Best-effort — the
    /// whole cache failing never fails the media download. The two public entry points differ ONLY in
    /// how each stream's request is built (Plex token-in-query URL from the stream key; Jellyfin
    /// authenticated request by stream index), so that is all they resolve before delegating.
    private func cacheTextSubtitles(ratingKey: String, pending: [PendingSubtitle]) {
        guard !pending.isEmpty else { return }
        let store = self.store
        Task { [weak self] in
            var tracks: [OfflineTextSubtitleTrack] = []
            for item in pending {
                guard await Self.fetchAndWriteTextSubtitle(request: item.request, to: item.destination)
                else { continue }
                if let track = item.track { tracks.append(track) }
            }
            guard !tracks.isEmpty else { return }
            await MainActor.run {
                store.setOfflineTextSubtitles(ratingKey: ratingKey, tracks)
                self?.refreshRecords()
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

    private nonisolated static func fetchAndWriteTextSubtitle(request: URLRequest, to destination: URL) async -> Bool {
        do {
            let (data, response) = try await URLSession.shared.data(
                for: sideAssetRequest(applyingCellularPolicy: request))
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return false }
            guard let text = String(data: data, encoding: .utf8),
                  !OfflineTextSubtitleParser.parse(text).isEmpty else { return false }
            try data.write(to: destination, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Download + cache Plex's BIF trick-play index for the selected source Part so the
    /// local custom player can keep showing scrub previews fully offline (#78). Best-effort:
    /// a missing/invalid BIF never fails the media download. The request carries the token in
    /// query, so do not log the URL or surfaced error.
    func cachePlexBIF(ratingKey: String, item: MediaItem, mediaIndex: Int,
                              server: URL, token: String) {
        guard let part = DownloadSideAssetPolicy.selectedPlexBIFPart(from: item, mediaIndex: mediaIndex) else { return }
        let destination = store.plexBIFDestinationURL(ratingKey: ratingKey)
        let request = TrickPlayRequest.plexBIFIndex(server: server,
                                                    token: token,
                                                    identity: appModel.identity,
                                                    partID: part.id,
                                                    quality: "sd")
        // Data-plane side asset (a BIF can be tens of MB): fetch through a URLRequest so the
        // Wi-Fi-only download policy can be stamped, instead of the shared PlexClient.
        let bifRequest = Self.sideAssetRequest(applyingCellularPolicy: request.urlRequest())
        let store = self.store
        Task { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(for: bifRequest)
                if let http = response as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) { return }
                guard !data.isEmpty, (try? BIFParser.parse(data)) != nil else { return }
                try data.write(to: destination, options: .atomic)
                await MainActor.run {
                    store.setPlexBIFRelativePath(ratingKey: ratingKey, destination.lastPathComponent)
                    self?.refreshRecords()
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
    func cacheChapterImages(ratingKey: String, item: MediaItem, backend: DownloadBackendKind,
                                    server: URL, token: String) {
        let chapters = item.chapters ?? []
        guard !chapters.isEmpty else { return }
        // Build (chapter index, request) for every chapter that carries an image key. The index is
        // the chapter's position in `chapters` — the same enumeration the Chapters rail and the
        // offline scrub provider use, so it is the stable join key offline.
        let identity = appModel.identity
        var requests: [(index: Int, request: URLRequest)] = []
        for (index, chapter) in chapters.enumerated() {
            guard let thumb = chapter.thumb, !thumb.isEmpty else { continue }
            switch backend {
            case .plex:
                guard let url = PlexPhotoTranscode.url(server: server, token: token, imagePath: thumb,
                                                       width: 480, height: 270) else { continue }
                requests.append((index, URLRequest(url: url)))
            case .jellyfin:
                guard let parsed = DownloadSideAssetPolicy.parsedSyntheticChapterImageKey(thumb, scheme: "jellyfin"),
                      let url = try? JellyfinLibrary.chapterImageURL(server: server, itemId: parsed.itemID,
                                                                    chapterIndex: parsed.index, tag: parsed.tag,
                                                                    width: 480, height: 270) else { continue }
                var req = JellyfinLibrary.authenticatedRequest(url: url, token: token, identity: identity.jellyfin)
                req.setValue("*/*", forHTTPHeaderField: "Accept")
                requests.append((index, req))
            case .emby:
                guard let parsed = DownloadSideAssetPolicy.parsedSyntheticChapterImageKey(thumb, scheme: "emby"),
                      let url = try? EmbyLibrary.chapterImageURL(server: server, itemId: parsed.itemID,
                                                               chapterIndex: parsed.index, tag: parsed.tag,
                                                               width: 480, height: 270) else { continue }
                let userId = appModel.backendSession(for: .emby)?.userID
                var req = EmbyLibrary.authenticatedRequest(url: url, token: token, identity: identity.emby, userId: userId)
                req.setValue("*/*", forHTTPHeaderField: "Accept")
                requests.append((index, req))
            }
        }
        guard !requests.isEmpty else { return }
        let store = self.store
        Task { [weak self] in
            // Bound side-asset fanout (#187). The old task group launched every chapter thumbnail at
            // once and accumulated all image Data before writing. A long movie times several overnight
            // downloads could amplify memory/network pressure independent of the media transfer. Fetch
            // in small batches and write each batch before requesting the next one.
            let batchSize = DownloadSideAssetPolicy.chapterImageBatchSize
            if DownloadSideAssetPolicy.shouldLogChapterImageThrottling(requestCount: requests.count) {
                await MainActor.run {
                    self?.recordDownloadDiagnostic("downloads.side_cache_throttled", fields: [
                        "download_id": .identifier(ratingKey),
                        "asset": .label("chapter_images"),
                        "request_count": .int(requests.count),
                        "batch_size": .int(batchSize),
                    ])
                }
            }
            var relativesByIndex: [Int: String] = [:]
            var start = 0
            while start < requests.count {
                let end = min(start + batchSize, requests.count)
                let batch = Array(requests[start..<end])
                let fetched: [(index: Int, data: Data)] = await withTaskGroup(of: (Int, Data)?.self) { group in
                    for entry in batch {
                        group.addTask {
                            guard let (data, response) = try? await URLSession.shared.data(
                                    for: Self.sideAssetRequest(applyingCellularPolicy: entry.request)),
                                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                                  !data.isEmpty else { return nil }
                            return (entry.index, data)
                        }
                    }
                    var out: [(index: Int, data: Data)] = []
                    for await result in group { if let result { out.append(result) } }
                    return out
                }
                for entry in fetched {
                    let destination = store.chapterImageDestinationURL(ratingKey: ratingKey, index: entry.index)
                    guard (try? entry.data.write(to: destination, options: .atomic)) != nil else { continue }
                    relativesByIndex[entry.index] = destination.lastPathComponent
                }
                start = end
            }
            guard !relativesByIndex.isEmpty else { return }
            await MainActor.run {
                store.setChapterImageRelativePaths(ratingKey: ratingKey, relativesByIndex)
                self?.refreshRecords()
            }
        }
    }
}
