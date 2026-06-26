import Foundation

/// Pure, testable route classifier for an Emby download (GH #135 Stage 5 enabler, extracted from
/// `DownloadManager.downloadEmby`). It maps the user's download *intent* and the server's
/// AUTHORITATIVE negotiated PlaybackInfo verdict onto one of three transfer routes. Privacy-safe —
/// it reads only codec/container tokens and the negotiated direct-play flag.
///
/// The #112 (`.existingVersion`) / #126 (Emby existing-version reuse) / #83 (compatible remux)
/// routing semantics are load-bearing and were previously inlined and untested; they are now pinned
/// by `EmbyDownloadRouterTests`.
public enum EmbyDownloadRouter {
    /// What the user asked for, collapsed to the three classes the router distinguishes. The app's
    /// `DownloadChoice` maps `.original` → `.original`, `.existingVersion` → `.existingVersion`,
    /// `.optimizeCompatible` → `.compatible`, and `.optimize` → `.transcode`.
    public enum Intent: Sendable, Equatable {
        /// A user/source `.original`: download byte-for-byte ONLY when Emby negotiates direct-play AND
        /// the container is locally playable. A user-original has no server-rendered guarantee, so the
        /// direct-play verdict is the safety net against silently downloading a non-playable source.
        case original
        /// A #126 existing-version / convert-reuse handoff: the source is a PRE-RENDERED file we GET
        /// byte-for-byte (static download), so eligibility is purely "can AVFoundation play this local
        /// container+codec" (mirrors Plex's `existingVersionPlayableOffline` / #125) — NOT Emby's
        /// streaming `supportsDirectPlay` verdict, which it returns false for even a clean mp4/h264
        /// converted file (observed live, Emby 4.9; that false verdict used to silently kill the
        /// convert→download handoff).
        case existingVersion
        /// #83 "Original quality (compatible)": honour the remux lane when the source video is
        /// stream-copy eligible, otherwise transcode.
        case compatible
        /// An explicit optimize preset always forces the transcode lane.
        case transcode
    }

    /// The chosen transfer route against the negotiated verdict.
    public enum Route: String, Sendable, Equatable {
        /// Byte-for-byte static download of a directly-playable file (range-resumable).
        case original
        /// #83 server-side remux that COPIES the original video into MP4 (forward-only).
        case compatibleRemux
        /// Forced h264/aac re-encode — a live, forward-only transcode. The caller reroutes this to
        /// the convert-then-download lane for `.optimize`/`.optimizeCompatible`, and fails it for
        /// `.original`/`.existingVersion` (those must stay byte-for-byte resumable).
        case transcode
    }

    /// The negotiated-container gate: AVFoundation can open the downloaded result as a standalone
    /// local file when the raw source part is already locally playable OR the server negotiated an
    /// mp4-family container.
    public static func containerGate(part: Part?, negotiatedContainer: String?) -> Bool {
        OfflineDownloadDecision.isLocallyPlayableOriginal(part: part)
            || ["mp4", "m4v", "mov"].contains((negotiatedContainer ?? "").lowercased())
    }

    /// Classify the transfer route. The `supportsDirectPlay` / `container` / `videoCodec` /
    /// `audioCodec` inputs come straight from the Emby download PlaybackInfo decision; `part` is the
    /// in-memory source part (its container backstops the gate when the server omits one).
    public static func route(intent: Intent,
                             supportsDirectPlay: Bool,
                             container: String?,
                             videoCodec: String?,
                             audioCodec: String?,
                             part: Part?) -> Route {
        switch intent {
        case .original:
            return (supportsDirectPlay && containerGate(part: part, negotiatedContainer: container))
                ? .original : .transcode
        case .existingVersion:
            // Static GET of a pre-rendered file → gate on local playability (container + video codec,
            // fail-closed on unknown), independent of Emby's streaming direct-play verdict.
            return OfflineDownloadDecision.existingVersionPlayableOffline(
                container: container, videoCodec: videoCodec) ? .original : .transcode
        case .compatible:
            // The negotiated DirectStream flag may be false for audio-only transcode cases (e.g.
            // HEVC + DTS → MP4 + AAC) that still preserve original video quality, so gate on
            // stream-copy eligibility, not the flag.
            let remux = OfflineDownloadDecision.compatibleRemuxEligibility(
                videoCodec: videoCodec, audioCodec: audioCodec, sourceContainer: container)
            return remux.isEligible ? .compatibleRemux : .transcode
        case .transcode:
            return .transcode
        }
    }
}
