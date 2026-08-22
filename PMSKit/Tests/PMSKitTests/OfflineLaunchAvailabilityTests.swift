import Foundation
import Testing
@testable import PMSKit

@Suite("Offline launch availability")
struct OfflineLaunchAvailabilityTests {
    private let file = URL(fileURLWithPath: "/tmp/offline-launch-test.mp4")

    @Test("requires a completed row whose local file still exists")
    func requiresCompletedPresentFile() {
        let complete = DownloadRecord(ratingKey: "plex:item", title: "Item",
                                      localURL: file, status: .complete)
        let unverified = DownloadRecord(ratingKey: "jellyfin:item", title: "Item",
                                        localURL: file, status: .unverified)
        let queued = DownloadRecord(ratingKey: "emby:item", title: "Item",
                                    localURL: file, status: .queued)

        #expect(OfflineLaunchAvailability.hasPlayableDownload(records: [complete]) { _ in true })
        #expect(OfflineLaunchAvailability.hasPlayableDownload(records: [unverified]) { _ in true })
        #expect(!OfflineLaunchAvailability.hasPlayableDownload(records: [queued]) { _ in true })
        #expect(!OfflineLaunchAvailability.hasPlayableDownload(records: [complete]) { _ in false })
        #expect(!OfflineLaunchAvailability.hasPlayableDownload(records: []) { _ in true })
    }
}
