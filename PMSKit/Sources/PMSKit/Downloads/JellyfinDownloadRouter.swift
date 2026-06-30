import Foundation

/// Pure route classifier for Jellyfin offline downloads.
///
/// Jellyfin differs from Emby: `.original` is a static stream request built directly from the item
/// and MediaSource id, while `.optimize` / `.optimizeCompatible` use a server-minted PlaybackInfo
/// session and a live-forward MP4 stream. Keep this router deliberately small so request building,
/// PlaySession keepalive, and fallback side effects stay in the Jellyfin backend adapter.
public enum JellyfinDownloadRouter {
    public enum Intent: Sendable, Equatable {
        /// Byte-for-byte static stream. `.existingVersion` is accepted as this same intent because
        /// Plex-only existing versions are not normally offered for Jellyfin, but retry code still
        /// needs an exhaustive mapping.
        case original
        /// Explicit bitrate/resolution preset.
        case transcode
        /// Original-quality compatible MP4 request: copy source video when safe, otherwise transcode.
        case compatible
    }

    public enum Route: String, Sendable, Equatable {
        /// Static original stream; range-resumable and network-bound.
        case staticOriginal
        /// Live remux stream that copies the source video into MP4; forward-only.
        case compatibleRemux
        /// Live h264/aac MP4 transcode; forward-only.
        case transcode

        public var isLiveForwardOnly: Bool {
            switch self {
            case .staticOriginal:
                return false
            case .compatibleRemux, .transcode:
                return true
            }
        }

        public var usesByteRangeCheckpoint: Bool {
            !isLiveForwardOnly
        }

        public var diagnosticLabel: String {
            switch self {
            case .staticOriginal:
                return "static_original"
            case .compatibleRemux:
                return "compatible_remux"
            case .transcode:
                return "transcode"
            }
        }
    }

    public struct CompatibleDecision: Sendable, Equatable {
        public let route: Route
        public let eligibility: CompatibleRemuxEligibility

        public var isRemux: Bool { route == .compatibleRemux }
    }

    public static func route(intent: Intent,
                             videoCodec: String?,
                             audioCodec: String?,
                             container: String?) -> Route {
        switch intent {
        case .original:
            return .staticOriginal
        case .transcode:
            return .transcode
        case .compatible:
            return compatibleDecision(videoCodec: videoCodec,
                                      audioCodec: audioCodec,
                                      container: container).route
        }
    }

    public static func compatibleDecision(videoCodec: String?,
                                          audioCodec: String?,
                                          container: String?) -> CompatibleDecision {
        let eligibility = OfflineDownloadDecision.compatibleRemuxEligibility(
            videoCodec: videoCodec,
            audioCodec: audioCodec,
            sourceContainer: container)
        return CompatibleDecision(route: eligibility.isEligible ? .compatibleRemux : .transcode,
                                  eligibility: eligibility)
    }
}
