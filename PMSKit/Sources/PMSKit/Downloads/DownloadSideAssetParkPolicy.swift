import Foundation

/// When a finished body lifts the pause its row put on optional side assets (F3, #474).
///
/// A user pause parks the attempt's side-asset owner and leaves its tasks registered. A transfer
/// that finishes as the pause lands still finalizes and completes, and such a row has no Resume
/// to unpark it; the repair pass starts nothing either, because the tasks are still registered.
/// So the publishing finalizer's admission unparks the owner itself.
public enum DownloadSideAssetParkPolicy {
    /// Pause All still holds every non-poster fetch of a row that is not exempt from it (the
    /// fetch entry would park it again); Resume All unparks those rows.
    public static func finishedBodyUnparks(isQueuePaused: Bool, isExemptFromQueuePause: Bool) -> Bool {
        !isQueuePaused || isExemptFromQueuePause
    }
}
