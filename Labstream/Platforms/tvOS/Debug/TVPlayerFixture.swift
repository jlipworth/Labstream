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
        if DebugUITestLaunchConfiguration.playerFixtureStartsBuffering {
            // The buffering-review variant needs the controller instance so it can hold
            // `transportStatus` in `.buffering` against the KVO-driven transitions that would
            // otherwise clear it as local playback primes instantly.
            let identity = PlatformClientIdentity.make(clientIdentifier: "offline")
            let client = PlexClient(identity: identity)
            CustomPlayerView(item: item,
                             controllerFactory: {
                                 let controller = PlaybackController(item: item,
                                                                     sessionSource: .offline(
                                                                        OfflinePlaybackSession(fileURL: url)),
                                                                     identity: identity,
                                                                     client: client)
                                 holdBufferingStatus(on: controller)
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
        Task { @MainActor [weak controller] in
            let deadline = ContinuousClock.now.advanced(by: .seconds(600))
            while ContinuousClock.now < deadline {
                guard let controller else { return }
                controller.transportStatus.set(.buffering)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func prepare() async {
        do {
            let url = try await DebugPlayerFixtureMedia.ensureVideoFile()
            phase = .ready(url)
            presentingPlayer = true
        } catch {
            phase = .failed(String(describing: error))
        }
    }
}

/// Native text-entry fixture for TVUI-004. Three fields bisect the live Search defect:
///
/// 1. `bare` — a plain default `TextField` (known-good baseline: letters insert here);
/// 2. `styled` — adds SearchView's visual modifiers (`.plain` style, font, capsule frame)
///    but NO focus binding;
/// 3. `replica` — the full SearchView treatment including `.focused($…)`, the leading
///    icon row, and the on-appear programmatic focus write.
///
/// If `bare` passes and `replica` fails, the styled field tells us whether the visual
/// modifiers or the focus binding is what breaks system-keyboard insertion.
struct TVKeyboardFixtureView: View {
    @State private var bareQuery = ""
    @State private var styledQuery = ""
    @State private var replicaQuery = ""
    @FocusState private var replicaFocused: Bool

    var body: some View {
        VStack(spacing: 40) {
            TextField("Fixture query", text: $bareQuery)
                .frame(maxWidth: 900)
                .accessibilityIdentifier("tv.fixture.keyboard.field")
            Text("typed:\(bareQuery)")
                .font(.title3.monospaced())
                .accessibilityIdentifier("tv.fixture.keyboard.echo")

            TextField("Styled query", text: $styledQuery)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(.horizontal, 28)
                .frame(width: 920, height: 70)
                .background(.thinMaterial, in: Capsule())
                .accessibilityIdentifier("tv.fixture.keyboard.styled.field")
            Text("styled:\(styledQuery)")
                .font(.title3.monospaced())
                .accessibilityIdentifier("tv.fixture.keyboard.styled.echo")

            HStack(spacing: 18) {
                Image(systemName: "magnifyingglass")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("Replica query", text: $replicaQuery)
                    .focused($replicaFocused)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .accessibilityIdentifier("tv.fixture.keyboard.replica.field")
            }
            .padding(.horizontal, 28)
            .frame(width: 920, height: 70)
            .background(.thinMaterial, in: Capsule())
            Text("replica:\(replicaQuery)")
                .font(.title3.monospaced())
                .accessibilityIdentifier("tv.fixture.keyboard.replica.echo")
        }
        .task {
            await Task.yield()
            replicaFocused = true
        }
        .onChange(of: bareQuery) { _, value in
            NSLog("%@", "TVKeyboardFixture: bare query changed to '\(value)'")
        }
        .onChange(of: styledQuery) { _, value in
            NSLog("%@", "TVKeyboardFixture: styled query changed to '\(value)'")
        }
        .onChange(of: replicaQuery) { _, value in
            NSLog("%@", "TVKeyboardFixture: replica query changed to '\(value)'")
        }
        .onChange(of: replicaFocused) { _, focused in
            NSLog("%@", "TVKeyboardFixture: replica focused -> \(focused)")
        }
    }
}

/// TVUI-004 shell bisection (`--ui-testing-fixture keyboard-shell`): the replica field
/// inserts letters when hosted bare (`TVKeyboardFixtureView`), yet the identical field in
/// the live Search tab loses the input session the moment a keyboard letter is selected
/// (captured evidence: `_teardownExistingDelegate` fires on the Select's press-end, no
/// insertion ever reaches the binding). This variant rebuilds the layers the live shell
/// adds — TabView tab, NavigationStack, results ScrollView below the field, and the
/// conditional trailing Clear button — so a UI test can tell which one kills insertion.
struct TVKeyboardShellFixtureView: View {
    private enum FixtureTab: Hashable { case home, search }

    @State private var query = ""
    @FocusState private var fieldFocused: Bool
    // Launch selected on Search: the state under test is an arrived-at Search tab, and the
    // UI-test can't assert on a field that doesn't exist until the tab is chosen.
    @State private var selection: FixtureTab = .search

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: FixtureTab.home) {
                Text("Fixture home stub")
            }
            Tab("Search", systemImage: "magnifyingglass", value: FixtureTab.search) {
                NavigationStack {
                    VStack(spacing: 0) {
                        HStack(spacing: 18) {
                            Image(systemName: "magnifyingglass")
                                .font(.title2.weight(.medium))
                                .foregroundStyle(.secondary)

                            TextField("Movies, shows, music…", text: $query)
                                .focused($fieldFocused)
                                .textFieldStyle(.plain)
                                .font(.title3)
                                .accessibilityIdentifier("tv.fixture.keyboard.shell.field")

                            if !query.isEmpty {
                                Button {
                                    query = ""
                                    fieldFocused = true
                                } label: {
                                    Label("Clear search", systemImage: "xmark.circle.fill")
                                        .labelStyle(.iconOnly)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 28)
                        .frame(width: 920, height: 70)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.top, 28)
                        .padding(.bottom, 12)

                        Text("shell:\(query)")
                            .font(.title3.monospaced())
                            .accessibilityIdentifier("tv.fixture.keyboard.shell.echo")

                        ScrollView {
                            ContentUnavailableView("Search your libraries",
                                                   systemImage: "magnifyingglass",
                                                   description: Text("Fixture results stub."))
                            .frame(maxWidth: .infinity, minHeight: 300)
                        }
                    }
                    .navigationTitle("Search")
                    .task {
                        await Task.yield()
                        fieldFocused = true
                    }
                    .onChange(of: query) { _, value in
                        NSLog("%@", "TVKeyboardFixture: shell query changed to '\(value)'")
                    }
                    .onChange(of: fieldFocused) { _, focused in
                        NSLog("%@", "TVKeyboardFixture: shell focused -> \(focused)")
                    }
                }
            }
        }
    }
}

#endif
