import Foundation
import PMSKit

/// Reusable probe result shared by the single-item sheet and the one-time season planner. Keeping
/// server negotiation here prevents season planning from becoming a second routing engine.
struct DownloadItemPlanningOptions {
    struct Original: Sendable, Equatable {
        let sizeBytes: Int?
        let resolution: String?
    }

    struct CompatibleRemux: Sendable, Equatable {
        let codecSummary: String?
    }

    let item: MediaItem
    let original: Original?
    let compatibleRemux: CompatibleRemux?
    let presets: [String]
    let probeFailed: Bool
    let originalStreamableButOfflineUnsupported: Bool
    let existingVersions: [DownloadExistingVersionOption]
}

@MainActor
struct DownloadItemPlanner {
    let appModel: AppModel
    let downloadManager: DownloadManager

    func refreshedItem(_ item: MediaItem, backend: DownloadBackendKind) async throws -> MediaItem {
        switch backend {
        case .plex:
            return try await PlexBrowseService(appModel: appModel).metadata(ratingKey: item.ratingKey)
        case .jellyfin:
            return try await JellyfinBrowseService(appModel: appModel).metadata(itemId: item.ratingKey)
        case .emby:
            return try await EmbyBrowseService(appModel: appModel).metadata(itemId: item.ratingKey)
        }
    }

    func options(for item: MediaItem,
                 mediaIndex: Int = 0,
                 partIndex: Int = 0,
                 audioStreamIndexOverride: Int? = nil,
                 preferredAudioLanguage: String? = nil,
                 backend: DownloadBackendKind) async -> DownloadItemPlanningOptions {
        let selection = DownloadMediaSelectionPolicy.selection(
            item: item, mediaIndex: mediaIndex, partIndex: partIndex)
        let audioStreamIndex = DownloadAudioSelectionPolicy.selectedAudioStreamIndex(
            part: selection.part,
            overrideStreamIndex: audioStreamIndexOverride,
            preferredLanguage: preferredAudioLanguage)
        switch backend {
        case .plex:
            return await plexOptions(for: item, mediaIndex: mediaIndex, partIndex: partIndex)
        case .jellyfin:
            return await jellyfinOptions(for: item, mediaIndex: mediaIndex, partIndex: partIndex,
                                         audioStreamIndex: audioStreamIndex)
        case .emby:
            return await embyOptions(for: item, mediaIndex: mediaIndex, partIndex: partIndex,
                                     audioStreamIndex: audioStreamIndex)
        }
    }

    private func plexOptions(for item: MediaItem, mediaIndex: Int, partIndex: Int) async
        -> DownloadItemPlanningOptions {
        let fallbackPresets = DownloadPresetPolicy.visiblePresetNames(serverTargets: [])
        let existing = DownloadExistingVersionOptionPolicy.plexOptions(
            media: item.media, sourceMediaIndex: mediaIndex)
        guard let session = appModel.backendSession(for: .plex) else {
            return .init(item: item, original: nil, compatibleRemux: nil,
                         presets: fallbackPresets, probeFailed: true,
                         originalStreamableButOfflineUnsupported: false,
                         existingVersions: existing)
        }
        async let probeTask = downloadManager.directPlayProbe(
            for: item, server: session.baseURL, token: session.token,
            mediaIndex: mediaIndex, partIndex: partIndex)
        async let presetsTask = downloadManager.optimizePresetNames(
            server: session.baseURL, token: session.token)
        let probe = await probeTask
        let fetched = await presetsTask
        let presets = fetched.isEmpty ? fallbackPresets : fetched
        let media = item.media?[safe: mediaIndex]
        let part = probe.part ?? media?.part[safe: partIndex]
        let original = probe.direct && OfflineDownloadDecision.isLocallyPlayableOriginal(part: part)
            ? DownloadItemPlanningOptions.Original(
                sizeBytes: part?.size,
                resolution: DownloadPresetPolicy.resolutionLabel(for: media))
            : nil
        return .init(item: item, original: original, compatibleRemux: nil, presets: presets,
                     probeFailed: false,
                     originalStreamableButOfflineUnsupported: probe.direct && original == nil,
                     existingVersions: existing)
    }

    private func jellyfinOptions(for item: MediaItem, mediaIndex: Int, partIndex: Int,
                                  audioStreamIndex: Int?) async -> DownloadItemPlanningOptions {
        let selection = DownloadMediaSelectionPolicy.selection(
            item: item, mediaIndex: mediaIndex, partIndex: partIndex)
        let media = selection.media
        let part = selection.part
        let originalPlayable = OfflineDownloadDecision.isLocallyPlayableOriginal(part: part)
        let original = originalPlayable
            ? DownloadItemPlanningOptions.Original(
                sizeBytes: part?.size,
                resolution: DownloadPresetPolicy.resolutionLabel(for: media))
            : nil
        var remux: DownloadItemPlanningOptions.CompatibleRemux?
        var failed = false
        if !originalPlayable {
            guard let session = appModel.backendSession(for: .jellyfin),
                  let userID = session.userID else {
                return .init(item: item, original: original, compatibleRemux: nil,
                             presets: DownloadPresetPolicy.bitratePresetNames, probeFailed: true,
                             originalStreamableButOfflineUnsupported: true, existingVersions: [])
            }
            var didRetryCancellation = false
            while true {
                do {
                    let request = try JellyfinPlayback.downloadPlaybackInfoRequest(
                        server: session.baseURL, token: session.token,
                        identity: appModel.identity.jellyfin,
                        itemId: item.ratingKey, userId: userID,
                        mediaSourceId: selection.mediaSourceID, maxStaticBitrate: 200_000_000,
                        audioStreamIndex: audioStreamIndex)
                    let (data, response) = try await URLSession.shared.data(for: request)
                    try Self.requireSuccess(response)
                    let info = try JellyfinPlaybackInfoResponse.decode(from: data)
                    let decision = try JellyfinPlayback.downloadDecision(
                        response: info, preferredMediaSourceId: selection.mediaSourceID)
                    let eligibility = OfflineDownloadDecision.compatibleRemuxEligibility(
                        videoCodec: decision.videoCodec, audioCodec: decision.audioCodec,
                        sourceContainer: decision.container)
                    if eligibility.shouldOffer(originalLocallyPlayable: false) {
                        remux = .init(codecSummary: eligibility.codecSummary)
                    }
                    break
                } catch {
                    if Self.isCancellation(error), !Task.isCancelled, !didRetryCancellation {
                        didRetryCancellation = true
                        continue
                    }
                    if Task.isCancelled { return .init(
                        item: item, original: original, compatibleRemux: nil,
                        presets: DownloadPresetPolicy.bitratePresetNames, probeFailed: true,
                        originalStreamableButOfflineUnsupported: original == nil,
                        existingVersions: [])
                    }
                    failed = true
                    break
                }
            }
        }
        return .init(item: item, original: original, compatibleRemux: remux,
                     presets: DownloadPresetPolicy.bitratePresetNames, probeFailed: failed,
                     originalStreamableButOfflineUnsupported: original == nil && remux == nil,
                     existingVersions: [])
    }

    private func embyOptions(for item: MediaItem, mediaIndex: Int, partIndex: Int,
                             audioStreamIndex: Int?) async -> DownloadItemPlanningOptions {
        let selection = DownloadMediaSelectionPolicy.selection(
            item: item, mediaIndex: mediaIndex, partIndex: partIndex)
        let media = selection.media
        let part = selection.part
        let presets = DownloadPresetPolicy.bitratePresetNames
        guard let session = appModel.backendSession(for: .emby), let userID = session.userID else {
            return .init(item: item, original: nil, compatibleRemux: nil, presets: presets,
                         probeFailed: true, originalStreamableButOfflineUnsupported: false,
                         existingVersions: [])
        }
        let identity = appModel.identity.emby
        var direct = false
        var container: String?
        var failed = false
        do {
            let request = try EmbyPlayback.downloadPlaybackInfoRequest(
                server: session.baseURL, token: session.token, identity: identity,
                userId: userID, itemId: item.ratingKey, mediaSourceId: selection.mediaSourceID,
                maxStaticBitrate: 200_000_000, audioStreamIndex: audioStreamIndex)
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.requireSuccess(response)
            let decision = try EmbyPlayback.downloadDecision(
                response: EmbyPlaybackInfoResponse.decode(from: data))
            direct = decision.supportsDirectPlay
            container = decision.container
        } catch {
            failed = true
        }

        let original = direct && EmbyDownloadRouter.containerGate(
            part: part, negotiatedContainer: container)
            ? DownloadItemPlanningOptions.Original(
                sizeBytes: part?.size,
                resolution: DownloadPresetPolicy.resolutionLabel(for: media))
            : nil
        var remux: DownloadItemPlanningOptions.CompatibleRemux?
        if !failed && original == nil {
            do {
                let request = try EmbyPlayback.compatibleRemuxDownloadPlaybackInfoRequest(
                    server: session.baseURL, token: session.token, identity: identity,
                    userId: userID, itemId: item.ratingKey, mediaSourceId: selection.mediaSourceID,
                    maxStaticBitrate: 200_000_000, audioStreamIndex: audioStreamIndex)
                let (data, response) = try await URLSession.shared.data(for: request)
                try Self.requireSuccess(response)
                let decision = try EmbyPlayback.downloadDecision(
                    response: EmbyPlaybackInfoResponse.decode(from: data),
                    preferredMediaSourceId: selection.mediaSourceID)
                let eligibility = OfflineDownloadDecision.compatibleRemuxEligibility(
                    videoCodec: decision.videoCodec, audioCodec: decision.audioCodec,
                    sourceContainer: decision.container)
                if eligibility.shouldOffer(originalLocallyPlayable: false) {
                    remux = .init(codecSummary: eligibility.codecSummary)
                }
            } catch {
                failed = true
            }
        }
        let existing = (try? await embyExistingVersions(
            session: session, identity: identity, userID: userID, item: item,
            selectedMediaSourceID: selection.mediaSourceID)) ?? []
        return .init(item: item, original: original, compatibleRemux: remux, presets: presets,
                     probeFailed: failed,
                     originalStreamableButOfflineUnsupported: !failed && direct && original == nil && remux == nil,
                     existingVersions: existing)
    }

    private func embyExistingVersions(session: BackendSession, identity: EmbyClientIdentity,
                                      userID: String, item: MediaItem,
                                      selectedMediaSourceID: String?) async throws
        -> [DownloadExistingVersionOption] {
        func fetch() async throws -> [DownloadExistingVersionOption] {
            let request = try EmbyPlayback.downloadPlaybackInfoRequest(
                server: session.baseURL, token: session.token, identity: identity,
                userId: userID, itemId: item.ratingKey, mediaSourceId: nil,
                maxStaticBitrate: 200_000_000)
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.requireSuccess(response)
            let info = try EmbyPlaybackInfoResponse.decode(from: data)
            let primary = selectedMediaSourceID
                ?? (try? EmbyPlayback.downloadDecision(response: info))?.mediaSourceId
            return DownloadExistingVersionOptionPolicy.embyOptions(
                response: info, primaryMediaSourceId: primary)
        }
        let initial = try await fetch()
        if !initial.isEmpty { return initial }
        let refresh = try EmbyConvertRequest.itemRefreshRequest(
            server: session.baseURL, token: session.token, identity: identity,
            userId: userID, itemId: item.ratingKey)
        let (_, response) = try await URLSession.shared.data(for: refresh)
        try Self.requireSuccess(response)
        for attempt in 0..<2 {
            let versions = try await fetch()
            if !versions.isEmpty { return versions }
            if attempt == 0 { try? await Task.sleep(for: .seconds(5)) }
        }
        return []
    }

    private static func requireSuccess(_ response: URLResponse) throws {
        if let response = response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            throw URLError(.badServerResponse)
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let error = error as NSError
        return error.domain == NSURLErrorDomain && error.code == URLError.cancelled.rawValue
    }
}
