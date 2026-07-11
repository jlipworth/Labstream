import Foundation

/// User-facing disclosure policy for a compatible-remux choice whose authoritative download-time
/// negotiation can fall back to a bitrate-capped server conversion.
///
/// Emby currently maps that fallback to its default 1080p Convert preset. The picker always
/// discloses the fallback, and sources known to exceed the 1080p bounding box require an explicit
/// confirmation before download starts. Jellyfin does not use Emby's persistent Convert fallback.
public enum DownloadCompatibleRemuxDisclosurePolicy {
    public static let fallbackCaption =
        "If Emby can't copy the video, it will create a compatible copy capped at 1080p."

    public static let confirmationTitle = "Allow a 1080p fallback?"

    public static let confirmationMessage =
        "This source is above 1080p. Emby may create a 1080p compatible copy if it can't remux the original video. Choose a 4K bitrate preset instead to require a 4K converted copy."

    public static func showsFallbackDisclosure(backend: DownloadBackendKind) -> Bool {
        backend == .emby
    }

    public static func requiresConfirmation(backend: DownloadBackendKind,
                                            sourceWidth: Int?,
                                            sourceHeight: Int?) -> Bool {
        guard backend == .emby else { return false }
        return (sourceWidth.map { $0 > 1_920 } ?? false)
            || (sourceHeight.map { $0 > 1_080 } ?? false)
    }
}
