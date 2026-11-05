#if DEBUG
import AVFoundation
import Foundation
import PMSKit
import SwiftUI

/// Isolated, synthetic surface over the actual player/chrome. Live auth is never used.
struct MacPlayerFixtureView: View {
    @State private var file: URL?
    @State private var controller: PlaybackController?
    @State private var closed = false
    @State private var failed = false

    var body: some View {
        Group {
            if closed {
                Text("Fixture stopped").accessibilityIdentifier("playback.fixture.stopped")
            } else if failed {
                Text("Fixture blocked").accessibilityIdentifier("playback.fixture.blocked")
            } else if let file {
                CustomPlayerView(item: DebugPlayerFixtureMedia.item, controllerFactory: {
                    let identity = PlatformClientIdentity.make(clientIdentifier: "fixture")
                    let source: PlaybackSessionSource
                    if ProcessInfo.processInfo.arguments.contains("--ui-testing-player-consent") {
                        source = .mediaBrowser(MediaBrowserPlaybackSession(
                            streamURL: URL(string: "https://fixture.invalid/master.m3u8")!,
                            backend: .emby, backendLabel: "Emby", httpHeaders: [:], playSessionID: "fixture",
                            sourceMetadata: .init(videoCodec: "unsupported"), playMethod: .transcode,
                            transcodeReasons: ["VideoCodecNotSupported"], progressSession: nil,
                            onStop: {}, reopener: { _ in throw URLError(.cancelled) }, onStopAndWait: {}))
                    } else { source = .offline(OfflinePlaybackSession(fileURL: file)) }
                    let value = PlaybackController(item: DebugPlayerFixtureMedia.item,
                        sessionSource: source, identity: identity, client: PlexClient(identity: identity),
                        maxVideoBitrateKbps: 0)
                    controller = value
                    DebugStatsFixture.seedWhenReady(value)
                    return value
                }, onClose: { closed = true })
            } else { ProgressView("Preparing fixture") }
        }
        .task {
            DebugStatsFixture.prepareLaunch()
            do { file = try await DebugPlayerFixtureMedia.ensureVideoFile() }
            catch { failed = true }
        }
        .task(id: controller != nil) {
            guard let controller else { return }
            if DebugUITestLaunchConfiguration.playerFixtureStartsBuffering {
                controller.transportStatus.holdForTesting(.buffering)
            }
        }
    }
}
#endif
