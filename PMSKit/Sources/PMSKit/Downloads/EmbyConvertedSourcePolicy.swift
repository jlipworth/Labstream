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
    /// be outside the pre-conversion snapshot, shaped like a converted output, and (where the request
    /// tier is known) not implausibly far below the tier this job could have rendered — a foreign
    /// low-res sibling that slipped past the snapshot must not be adopted as our output.
    public static func newConvertedSource(_ sources: [EmbyMediaSourceInfo],
                                          excludingSnapshotIDs snapshotIDs: Set<String>,
                                          requestedHeight: Int? = nil,
                                          primaryMediaSourceID: String? = nil) -> EmbyMediaSourceInfo? {
        mostRecent(sources.filter { source in
            guard !snapshotIDs.contains(source.id ?? "") else { return false }
            guard looksConverted(source) else { return false }
            return convertOutputTierIsSane(source, sources: sources,
                                           requestedHeight: requestedHeight,
                                           primaryMediaSourceID: primaryMediaSourceID)
        })
    }

    /// Final fallback once the bounded post-completion poll has expired: prefer any new file source,
    /// then the most-recent converted-looking source visible in PlaybackInfo. The same output-tier
    /// sanity gate as `newConvertedSource` applies — this fallback is even more exposed to adopting
    /// a foreign sibling because it drops the `looksConverted` requirement on new sources.
    public static func completedSourceFallback(_ sources: [EmbyMediaSourceInfo],
                                               excludingSnapshotIDs snapshotIDs: Set<String>,
                                               requestedHeight: Int? = nil,
                                               primaryMediaSourceID: String? = nil) -> EmbyMediaSourceInfo? {
        func tierSane(_ source: EmbyMediaSourceInfo) -> Bool {
            convertOutputTierIsSane(source, sources: sources,
                                    requestedHeight: requestedHeight,
                                    primaryMediaSourceID: primaryMediaSourceID)
        }
        let notInSnapshot = sources.filter { !snapshotIDs.contains($0.id ?? "") && tierSane($0) }
        return mostRecent(notInSnapshot)
            ?? mostRecent(sources.filter { looksConverted($0) && tierSane($0) })
    }

    /// Pick an already-existing server-prepared `File` source to reuse for a Convert request.
    ///
    /// Reuse must preserve the user's choice: a converted sibling qualifies only in the requested
    /// tier band, or — because Convert never upscales — in the SOURCE's own band when the source is
    /// smaller than the request (an SD source converted under a 1080p preset legitimately yields an
    /// SD output, and re-converting it forever would pile up duplicates). A sibling merely "no larger
    /// than the request" (e.g. an old 404p copy against a 1080p request on a 4K source) is a
    /// downgrade, not a match. For 4K/Original custom-profile requests, require an exact tier match
    /// so we don't silently reuse an older 1080p sibling for a resolution-preserving request. When
    /// the request pins an audio stream, the reused source must carry that stream's language.
    public static func reusableSource(_ sources: [EmbyMediaSourceInfo],
                                      requestedHeight: Int?,
                                      primaryMediaSourceID: String?,
                                      requestedAudioStreamIndex: Int? = nil) -> EmbyMediaSourceInfo? {
        guard let requestedHeight,
              let wantedTier = DownloadResolutionLabel.label(width: nil, height: requestedHeight) else {
            return nil
        }
        let primary = sources.first { $0.id != nil && $0.id == primaryMediaSourceID }
        let wantedAudioLanguage = requestedAudioLanguage(primary: primary,
                                                         index: requestedAudioStreamIndex)
        let converted = sources.filter {
            $0.id != primaryMediaSourceID && looksConverted($0)
                && audioLanguageMatches($0, wantedLanguage: wantedAudioLanguage)
        }
        if let exact = mostRecent(converted.filter { resolutionLabel(for: $0) == wantedTier }) {
            return exact
        }

        guard requestedHeight <= 1080 else { return nil }
        // Below-tier reuse is only valid when the SOURCE itself is below the requested tier —
        // then min(request, source) is the source's band and a sibling in that band is exactly
        // what this convert would render anyway. Without a resolvable primary source we cannot
        // prove that, so require the exact-tier match above.
        let requestedRank = tierRank(wantedTier)
        guard let primary else { return nil }
        let primaryRank = tierRank(resolutionLabel(for: primary))
        guard primaryRank < requestedRank else { return nil }
        return mostRecent(converted.filter { tierRank(resolutionLabel(for: $0)) == primaryRank })
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

    /// A Convert render's output tier is bounded by min(requested tier, source tier) — it never
    /// upscales. A candidate whose KNOWN dimensions land more than one band below that effective
    /// tier cannot plausibly be this job's output; it is an older or foreign sibling. Candidates
    /// with unknown dimensions pass: a freshly indexed source may not have probe data yet, and
    /// rejecting it would strand the post-completion pickup.
    private static func convertOutputTierIsSane(_ candidate: EmbyMediaSourceInfo,
                                                sources: [EmbyMediaSourceInfo],
                                                requestedHeight: Int?,
                                                primaryMediaSourceID: String?) -> Bool {
        guard let requestedHeight,
              let wantedTier = DownloadResolutionLabel.label(width: nil, height: requestedHeight) else {
            return true
        }
        let candidateRank = tierRank(resolutionLabel(for: candidate))
        guard candidateRank > 0 else { return true }
        var effectiveRank = tierRank(wantedTier)
        if let primary = sources.first(where: { $0.id != nil && $0.id == primaryMediaSourceID }) {
            let primaryRank = tierRank(resolutionLabel(for: primary))
            if primaryRank > 0 { effectiveRank = min(effectiveRank, primaryRank) }
        }
        return candidateRank >= effectiveRank - 1
    }

    /// Resolve the language of the audio stream a Convert request pinned (by stream index on the
    /// PRIMARY source), so reuse can honor the user's audio choice. Nil when the request pinned
    /// nothing or the language cannot be resolved — then reuse applies no audio constraint.
    private static func requestedAudioLanguage(primary: EmbyMediaSourceInfo?,
                                               index: Int?) -> String? {
        guard let index, let primary else { return nil }
        let language = primary.mediaStreams
            .first { $0.type == "Audio" && $0.index == index }?
            .language?.trimmingCharacters(in: .whitespaces).lowercased()
        return (language?.isEmpty ?? true) ? nil : language
    }

    private static func audioLanguageMatches(_ candidate: EmbyMediaSourceInfo,
                                             wantedLanguage: String?) -> Bool {
        guard let wantedLanguage else { return true }
        return candidate.mediaStreams.contains {
            $0.type == "Audio" && $0.language?.lowercased() == wantedLanguage
        }
    }

    private static func recency(_ source: EmbyMediaSourceInfo) -> Int {
        Int(source.id ?? "") ?? -1
    }

    private static func mostRecent(_ sources: [EmbyMediaSourceInfo]) -> EmbyMediaSourceInfo? {
        // Emby ids are numeric in practice; when they are not, fall back to PlaybackInfo position
        // so "newest" degrades to "listed last" instead of collapsing every tie to the first item.
        sources.enumerated()
            .max { (recency($0.element), $0.offset) < (recency($1.element), $1.offset) }?
            .element
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
