/// Identifies one successful SharePlay playback-coordinator attachment.
///
/// Both dimensions are load-bearing: `AVPlayerItem` replacement requires reattachment within the
/// same group session, while a newly delivered `GroupSession` requires reattachment even when the
/// current player item is unchanged.
public struct SharePlayPlaybackAttachmentRevision<ItemID: Equatable>: Equatable {
    public let sessionGeneration: UInt64
    public let itemID: ItemID

    public init(sessionGeneration: UInt64, itemID: ItemID) {
        self.sessionGeneration = sessionGeneration
        self.itemID = itemID
    }
}
