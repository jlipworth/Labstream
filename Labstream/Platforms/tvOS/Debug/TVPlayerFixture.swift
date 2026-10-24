#if DEBUG
import AVFoundation
import CoreVideo
import PMSKit
import SwiftUI
import UIKit

/// Deterministic tvOS player fixture (TVUI-024/TVUI-025): presents the real shared
/// `CustomPlayerView` over a locally generated H.264 file, with no network, credentials, or
/// browse state. Production launches never reach this surface.
struct TVPlayerFixtureView: View {
    @Environment(MusicPlayerController.self) private var musicPlayer

    private enum Phase {
        case preparing
        case ready(URL)
        case closed
        case failed(String)
    }

    @State private var phase: Phase = .preparing
    @State private var presentingPlayer = false

    var body: some View {
        ZStack {
            switch phase {
            case .preparing:
                ProgressView("Preparing fixture video…")
            case .ready(let url):
                // Production presents the custom player in a `.fullScreenCover` (DetailView), and
                // that presentation is what gives Menu/Back its exit behavior. Mirror it exactly.
                Color.black
                    .ignoresSafeArea()
                    .fullScreenCover(isPresented: $presentingPlayer,
                                     onDismiss: { phase = .closed }) {
                        fixturePlayer(url: url)
                            .ignoresSafeArea()
                    }
            case .closed:
                VStack(spacing: 24) {
                    Text("Player closed")
                        .font(.title2)
                        .accessibilityIdentifier("tv.fixture.player.closed")
                    Button("Reopen Player") {
                        phase = .preparing
                        Task { await prepare() }
                    }
                    .accessibilityIdentifier("tv.fixture.player.reopen")
                }
            case .failed(let message):
                Text("Fixture failed: \(message)")
                    .accessibilityIdentifier("tv.fixture.player.failed")
            }
        }
        .task { await prepare() }
    }

    @ViewBuilder
    private func fixturePlayer(url: URL) -> some View {
        let item = DebugPlayerFixtureMedia.item
        if DebugUITestLaunchConfiguration.playerFixtureStartsBuffering || DebugStatsFixture.scenario != nil {
            // The buffering-review variant needs the controller instance so it can pin
            // `transportStatus` in `.buffering` against the KVO-driven transitions that would
            // otherwise clear it as local playback primes instantly. The Stats-scenario
            // variant needs it to seed synthetic diagnostics (#331).
            let identity = PlatformClientIdentity.make(clientIdentifier: "offline")
            let client = PlexClient(identity: identity)
            CustomPlayerView(item: item,
                             controllerFactory: {
                                 let controller = PlaybackController(item: item,
                                                                     sessionSource: .offline(
                                                                        OfflinePlaybackSession(fileURL: url)),
                                                                     identity: identity,
                                                                     client: client)
                                 if DebugUITestLaunchConfiguration.playerFixtureStartsBuffering {
                                     holdBufferingStatus(on: controller)
                                 }
                                 DebugStatsFixture.seedWhenReady(controller)
                                 return controller
                             },
                             onClose: { presentingPlayer = false })
        } else {
            CustomPlayerView(localFile: url,
                             item: item,
                             onClose: { presentingPlayer = false })
        }
    }

    private func holdBufferingStatus(on controller: PlaybackController) {
        // Pinned through the real presentation timing: spinner after the show delay, card
        // after the escalation threshold, while KVO-driven updates are ignored.
        controller.transportStatus.holdForTesting(.buffering)
    }

    private func prepare() async {
        DebugStatsFixture.prepareLaunch()
        do {
            let url = try await DebugPlayerFixtureMedia.ensureVideoFile()
            phase = .ready(url)
            presentingPlayer = true
        } catch {
            phase = .failed(String(describing: error))
        }
    }
}

#endif
