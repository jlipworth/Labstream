import Foundation

/// Pure source/transfer plan after Jellyfin's request/PlaybackInfo facts are known.
///
/// Request construction and URLSession side effects stay in the app/backend adapter. This plan owns
/// the durable transfer semantics: static-vs-forward-only route, expected byte estimate,
/// negotiated MediaSource/PlaySession ids, and the metadata lane mutation needed when a compatible
/// remux request must safely fall back to a transcode.
public struct JellyfinDownloadSourcePlan: Sendable, Equatable {
    public let route: JellyfinDownloadRouter.Route
    public let expectedBytes: Int?
    public let mediaSourceID: String?
    public let playSessionID: String?
    public let metadataLaneOverride: DownloadLane?
    public let metadataOptimizeTargetNameOverride: String?
    public let compatibleEligibility: CompatibleRemuxEligibility?

    public var isCompatibleRemux: Bool { route == .compatibleRemux }

    public init(route: JellyfinDownloadRouter.Route,
                expectedBytes: Int?,
                mediaSourceID: String?,
                playSessionID: String?,
                metadataLaneOverride: DownloadLane? = nil,
                metadataOptimizeTargetNameOverride: String? = nil,
                compatibleEligibility: CompatibleRemuxEligibility? = nil) {
        self.route = route
        self.expectedBytes = expectedBytes
        self.mediaSourceID = mediaSourceID
        self.playSessionID = playSessionID
        self.metadataLaneOverride = metadataLaneOverride
        self.metadataOptimizeTargetNameOverride = metadataOptimizeTargetNameOverride
        self.compatibleEligibility = compatibleEligibility
    }

    public static func staticOriginal(sourcePartBytes: Int?) -> Self {
        JellyfinDownloadSourcePlan(route: .staticOriginal,
                                   expectedBytes: sourcePartBytes,
                                   mediaSourceID: nil,
                                   playSessionID: nil)
    }

    public static func transcode(decision: JellyfinDownloadPlaybackDecision,
                                 durationMs: Int?,
                                 profile: DownloadPresetPolicy.JellyfinTranscodeProfile) -> Self {
        JellyfinDownloadSourcePlan(route: .transcode,
                                   expectedBytes: TranscodeSizeEstimator.bytes(durationMs: durationMs,
                                                                               videoBitrateBps: profile.videoBitrateBps),
                                   mediaSourceID: decision.mediaSourceId,
                                   playSessionID: decision.playSessionId)
    }

    public static func compatible(decision: JellyfinDownloadPlaybackDecision,
                                  sourcePartBytes: Int?,
                                  durationMs: Int?,
                                  fallbackProfile: DownloadPresetPolicy.JellyfinTranscodeProfile,
                                  fallbackTargetName: String = DownloadPresetPolicy.jellyfinDefaultDownloadPreset) -> Self {
        let routeDecision = JellyfinDownloadRouter.compatibleDecision(videoCodec: decision.videoCodec,
                                                                      audioCodec: decision.audioCodec,
                                                                      container: decision.container)
        if routeDecision.isRemux {
            return JellyfinDownloadSourcePlan(route: .compatibleRemux,
                                              expectedBytes: decision.size ?? sourcePartBytes,
                                              mediaSourceID: decision.mediaSourceId,
                                              playSessionID: decision.playSessionId,
                                              compatibleEligibility: routeDecision.eligibility)
        }
        return JellyfinDownloadSourcePlan(route: .transcode,
                                          expectedBytes: TranscodeSizeEstimator.bytes(durationMs: durationMs,
                                                                                      videoBitrateBps: fallbackProfile.videoBitrateBps),
                                          mediaSourceID: decision.mediaSourceId,
                                          playSessionID: decision.playSessionId,
                                          metadataLaneOverride: .optimize,
                                          metadataOptimizeTargetNameOverride: fallbackTargetName,
                                          compatibleEligibility: routeDecision.eligibility)
    }
}
