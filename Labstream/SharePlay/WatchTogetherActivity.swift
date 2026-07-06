import Foundation
import GroupActivities
import PMSKit

/// Minimal SharePlay activity payload for the first Watch Together milestone.
///
/// Privacy contract: this activity carries only a random activity id, media kind, and a
/// sanitized exact display title. Provider ids, backend item ids, server URLs, library ids,
/// filenames, tokens, and playback/session ids remain local-only matching hints.
struct WatchTogetherActivity: GroupActivity, Codable, Sendable {
    let payload: SharePlayMediaActivityPayload

    var metadata: GroupActivityMetadata {
        var metadata = GroupActivityMetadata()
        metadata.title = payload.displayTitle
        metadata.subtitle = "Watch Together"
        metadata.type = .watchTogether
        return metadata
    }
}
