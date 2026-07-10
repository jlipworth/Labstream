import Foundation
import GroupActivities
import PMSKit

/// Minimal SharePlay activity payload for the first Watch Together milestone.
///
/// Privacy contract: this carries a random activity id plus explicitly disclosed public
/// catalog identity. Backend item/library ids, URLs, filenames, credentials, and playback
/// session ids are never representable in the payload.
struct WatchTogetherActivity: GroupActivity, Codable, Sendable {
    let payload: SharePlayMediaActivityPayload

    var metadata: GroupActivityMetadata {
        var metadata = GroupActivityMetadata()
        metadata.title = payload.displayTitle
        metadata.subtitle = payload.displaySubtitle.map { "Watch Together · \($0)" }
            ?? "Watch Together"
        metadata.type = .watchTogether
        return metadata
    }
}
