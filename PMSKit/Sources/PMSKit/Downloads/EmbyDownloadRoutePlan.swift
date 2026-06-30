import Foundation

/// Pure post-route action policy for Emby downloads.
///
/// `EmbyDownloadRouter` classifies the negotiated source. This plan decides whether the app should
/// start that transfer, redirect a live transcode into the persistent Convert-then-static lane, or
/// fail closed when a row that must remain byte-for-byte/static no longer negotiates a direct file.
public enum EmbyDownloadRoutePlan {
    public enum FailureReason: String, Sendable, Equatable {
        case convertedNotDirectlyDownloadable = "converted_not_directly_downloadable"
        case originalNotDirectlyDownloadable = "original_not_directly_downloadable"

        public var userMessage: String {
            switch self {
            case .convertedNotDirectlyDownloadable:
                return "Converted source not directly downloadable."
            case .originalNotDirectlyDownloadable:
                return "Original source no longer directly downloadable."
            }
        }
    }

    public enum Action: Sendable, Equatable {
        case startTransfer
        case rerouteConvert(targetName: String)
        case fail(FailureReason)
    }

    public static func action(route: EmbyDownloadRouter.Route,
                              choice: DownloadIntentChoice,
                              compatibleFallbackTargetName: String = DownloadPresetPolicy.jellyfinDefaultDownloadPreset) -> Action {
        guard route == .transcode else { return .startTransfer }
        switch choice {
        case .optimize(let targetName):
            return .rerouteConvert(targetName: targetName)
        case .optimizeCompatible:
            return .rerouteConvert(targetName: compatibleFallbackTargetName)
        case .existingVersion:
            return .fail(.convertedNotDirectlyDownloadable)
        case .original:
            return .fail(.originalNotDirectlyDownloadable)
        }
    }

    public static func useServerSession(for route: EmbyDownloadRouter.Route) -> Bool {
        route != .original
    }

    public static func usesByteRangeCheckpoint(for route: EmbyDownloadRouter.Route) -> Bool {
        route == .original
    }

    public static func diagnosticChoiceLabel(route: EmbyDownloadRouter.Route,
                                             choice: DownloadIntentChoice,
                                             choiceLabel: String) -> String {
        switch route {
        case .original:
            return "original"
        case .compatibleRemux:
            return "optimize_compatible"
        case .transcode:
            return choiceLabel
        }
    }
}
