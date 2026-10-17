#if !os(tvOS)
import AVFoundation
import Foundation
import PMSKit
import Synchronization
import Testing
@testable import Labstream

@Suite(.serialized)
@MainActor
struct P7OfflineSubtitleTests {
    private func asset() async throws -> (AVURLAsset, AVMediaSelectionGroup) {
        // Generated one-second black frame + tx3g, without server/media metadata.
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/P7/embedded-tx3g.mp4")
        let asset = AVURLAsset(url: file)
        let embedded = try #require(try await asset.loadMediaSelectionGroup(for: .legible))
        try #require(!embedded.options.isEmpty)
        return (asset, embedded)
    }

    private func controller(asset: AVURLAsset,
                            loader: @escaping OfflineSubtitleCueLoader) -> PlaybackController {
        let identity = PlatformClientIdentity.make(clientIdentifier: "p7-subtitles")
        let controller = PlaybackController(item: MediaItem(ratingKey: "fixture", title: "Fixture", type: "movie"),
            sessionSource: .offline(.init(fileURL: asset.url, textSubtitles: [
                .init(id: 1, displayName: "Fixture sidecar", relativePath: "fixture.srt")])),
            identity: identity, client: PlexClient(identity: identity), offlineSubtitleCueLoader: loader)
        controller.player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        return controller
    }

    @Test func embeddedAndSidecarAppearInOneMenu() async throws {
        let (asset, _) = try await asset()
        let loads = Mutex(0)
        let controller = controller(asset: asset, loader: { _ in
            loads.withLock { $0 += 1 }
            return []
        })
        defer { controller.stop() }
        let menu = try #require(try await controller.loadSubtitleTracks())
        #expect(menu.tracks.filter { $0.displayName == "Off" }.count == 1)
        #expect(menu.tracks.contains { $0.id == .offlineSidecar(1) })
        #expect(loads.withLock { $0 } == 0)
        #expect(menu.tracks.contains { $0.id == .avFoundation(0) })
    }

    @Test func sidecarAndOffRevokeEmbeddedSelection() async throws {
        let restore = preservePreferences()
        defer { restore() }
        let (asset, group) = try await asset()
        let controller = controller(asset: asset, loader: { _ in
            [.init(startMs: 0, endMs: 1_000, text: "Fixture")]
        })
        defer { controller.stop() }
        let embedded = PlaybackSubtitleTrack(displayName: "Embedded",
            mechanism: .avFoundation(index: 0, option: group.options[0]))
        try await controller.selectSubtitle(embedded)
        let menu = try #require(try await controller.loadSubtitleTracks())
        let sidecar = try #require(menu.tracks.first { $0.id == .offlineSidecar(1) })
        let off = try #require(menu.tracks.first { $0.displayName == "Off" })
        try await controller.selectSubtitle(sidecar)
        #expect(controller.player.currentItem?.currentMediaSelection.selectedMediaOption(in: group) == nil)
        try await controller.selectSubtitle(off)
        #expect(controller.player.currentItem?.currentMediaSelection.selectedMediaOption(in: group) == nil)
        #expect(controller.offlineSubtitleOverlay.text == nil)
    }

    @Test func embeddedSelectionInvalidatesPendingSidecarParse() async throws {
        let restore = preservePreferences()
        defer { restore() }
        let entered = P6Acknowledgement<Bool>()
        let release = P6Acknowledgement<Bool>()
        let (asset, group) = try await asset()
        let controller = controller(asset: asset, loader: { _ in
            entered.signal(true)
            _ = await release.wait()
            return [.init(startMs: 0, endMs: 1_000, text: "Fixture")]
        })
        defer { controller.stop(); release.signal(true) }
        let menu = try #require(try await controller.loadSubtitleTracks())
        let sidecar = try #require(menu.tracks.first { $0.id == .offlineSidecar(1) })
        let selection = Task { try await controller.selectSubtitle(sidecar) }
        _ = await entered.wait()
        try await controller.selectSubtitle(.init(displayName: "Embedded",
            mechanism: .avFoundation(index: 0, option: group.options[0])))
        release.signal(true)
        try await selection.value
        let after = try #require(try await controller.loadSubtitleTracks())
        #expect(after.selectedID == .avFoundation(0))
        #expect(controller.offlineSubtitleOverlay.text == nil)
    }

    private func preservePreferences() -> () -> Void {
        let defaults = UserDefaults.standard
        let keys = [PlaybackPreferences.Keys.subtitlesOff, PlaybackPreferences.Keys.preferredSubtitleLanguage,
                    PlaybackPreferences.Keys.preferredSubtitleRole]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        return {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
    }
}
#endif
