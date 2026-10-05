import AVFoundation
import Foundation
import PMSKit
import Testing
@testable import Labstream

@MainActor
struct PlaybackStopIntegrationTests {
    @Test func stopDetachesItemEvenWhileControllerRemainsAlive() {
        let identity = ClientIdentity(clientIdentifier: "stop-fixture", product: "Labstream",
                                      version: "1", deviceName: "Fixture")
        let controller = PlaybackController(
            item: MediaItem(ratingKey: "stop-fixture", title: "Fixture", type: "movie"),
            sessionSource: .offline(OfflinePlaybackSession(fileURL: URL(fileURLWithPath: "/fixture.invalid"))),
            identity: identity, client: PlexClient(identity: identity))
        // An empty composition exercises real AVPlayer ownership without network or files.
        let item = AVPlayerItem(asset: AVMutableComposition())
        controller.player.replaceCurrentItem(with: item)
        #expect(controller.player.currentItem === item)

        controller.stop()
        #expect(controller.player.currentItem == nil)
        #expect(controller.player.rate == 0)
        controller.stop()
        #expect(controller.player.currentItem == nil)
    }
}
