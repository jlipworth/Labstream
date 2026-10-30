import Foundation

/// #421: Emby can start two transcodes for one video-copy session when an `init.mp4`
/// request lands while a seek-gap restart has the job unregistered. Both write the same
/// init and segments, and AVPlayer may then reject the served init (`fmt?`). A second open
/// of the same verified copy lane normally succeeds, so it precedes the encode-consent prompt.
public enum EmbyCopyReopenRetryPolicy {
    public static func shouldRetry(isEmby: Bool, videoCopyEnforced: Bool, bitrateCeilingKbps: Int,
                                   videoTranscodeApproved: Bool, retryAlreadyUsed: Bool,
                                   failureIsTerminal: Bool) -> Bool {
        isEmby && videoCopyEnforced && bitrateCeilingKbps <= 0 && !videoTranscodeApproved
            && !retryAlreadyUsed && !failureIsTerminal
    }
}
