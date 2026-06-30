import Foundation

/// Pure Plex download-route decisions.
///
/// The app layer still owns AVFoundation preflight, metadata mutation, storage checks,
/// side-cache work, and URLSession startup. This helper only names the Plex-specific
/// route shape so `DownloadManager+Plex` does not encode every branch inline.
public enum PlexDownloadRouter {
    public enum Intent: Equatable, Sendable {
        case original
        case existingVersion
        case optimize(targetName: String)
        case optimizeCompatible
    }

    public enum MissingPartReason: String, Equatable, Sendable {
        case noMediaPart = "no_media_part"
        case noExistingVersionPart = "no_existing_version_part"
    }

    public enum InitialRoute: Equatable, Sendable {
        /// True original needs the app's AVFoundation source preflight before static transfer.
        case preflightOriginal
        /// User-selected Plex server version: static transfer, no original preflight, no optimizer.
        case staticExistingVersion
        /// Plex optimizer lane with the server's target name.
        case optimize(targetName: String)
        /// Static lanes need a concrete `Part`; report the legacy diagnostic reason when absent.
        case missingPart(reason: MissingPartReason)
    }

    public enum OriginalPreflightRoute: Equatable, Sendable {
        case staticOriginal
        case optimizeFallback(targetName: String)
    }

    public static func intent(for choice: DownloadIntentChoice) -> Intent {
        switch choice {
        case .original:
            return .original
        case .existingVersion:
            return .existingVersion
        case .optimize(let targetName):
            return .optimize(targetName: targetName)
        case .optimizeCompatible:
            return .optimizeCompatible
        }
    }

    public static func initialRoute(intent: Intent,
                                    hasPart: Bool,
                                    compatibleFallbackTarget: String) -> InitialRoute {
        switch intent {
        case .original:
            return hasPart ? .preflightOriginal : .missingPart(reason: .noMediaPart)
        case .existingVersion:
            return hasPart ? .staticExistingVersion : .missingPart(reason: .noExistingVersionPart)
        case .optimize(let targetName):
            return .optimize(targetName: targetName)
        case .optimizeCompatible:
            // Plex has no Jellyfin/Emby-style compatible-remux download lane. Its compatible
            // output is represented by the normal optimized-version target.
            return .optimize(targetName: compatibleFallbackTarget)
        }
    }

    public static func routeAfterOriginalPreflight(passed: Bool,
                                                   fallbackOptimizeTarget: String) -> OriginalPreflightRoute {
        passed ? .staticOriginal : .optimizeFallback(targetName: fallbackOptimizeTarget)
    }
}
