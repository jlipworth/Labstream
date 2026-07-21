#if os(tvOS) && DEBUG
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
        let item = TVPlayerFixtureMedia.item
        if TVUITestLaunchConfiguration.playerFixtureStartsBuffering {
            // The buffering-review variant needs the controller instance so it can hold
            // `transportStatus` in `.buffering` against the KVO-driven transitions that would
            // otherwise clear it as local playback primes instantly.
            let identity = PlatformClientIdentity.make(clientIdentifier: "offline")
            let client = PlexClient(identity: identity)
            CustomPlayerView(item: item,
                             controllerFactory: {
                                 let controller = PlaybackController(localFile: url,
                                                                     item: item,
                                                                     identity: identity,
                                                                     client: client)
                                 holdBufferingStatus(on: controller)
                                 return controller
                             },
                             cinemaOrigin: .offline(ratingKey: item.ratingKey),
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
            let url = try await TVPlayerFixtureMedia.ensureVideoFile()
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
    @State private var query = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house") {
                Text("Fixture home stub")
            }
            Tab("Search", systemImage: "magnifyingglass") {
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

/// Generates the fixture's local video: 20 minutes of alternating solid frames, H.264, silent.
/// Written once into Caches and reused across launches.
enum TVPlayerFixtureMedia {
    static var item: MediaItem {
        MediaItem(ratingKey: "tv-player-fixture", title: "TV Player Fixture", type: "movie",
                  duration: durationMs, year: 2026,
                  summary: "Deterministic local playback fixture for tvOS player chrome work.",
                  chapters: [
                      Chapter(id: 1, tag: "Opening", startTimeOffset: 0),
                      Chapter(id: 2, tag: "Middle", startTimeOffset: durationMs / 3),
                      Chapter(id: 3, tag: "Late", startTimeOffset: durationMs * 2 / 3),
                  ])
    }

    private static let durationSeconds = 1200
    private static var durationMs: Int { durationSeconds * 1000 }
    private static let frameDurationSeconds = 2
    private static let width = 1280
    private static let height = 720

    enum FixtureError: Error {
        case cachesUnavailable
        case pixelBufferUnavailable
        case writerFailed(String)
    }

    static func ensureVideoFile() async throws -> URL {
        guard let caches = FileManager.default.urls(for: .cachesDirectory,
                                                    in: .userDomainMask).first else {
            throw FixtureError.cachesUnavailable
        }
        let url = caches.appendingPathComponent("tv-player-fixture-\(durationSeconds)s.mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let target = url
        try await Task.detached(priority: .userInitiated) {
            try writeVideo(to: target)
        }.value
        return url
    }

    private nonisolated static func writeVideo(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        guard writer.startWriting() else {
            throw FixtureError.writerFailed(writer.error.map(String.init(describing:)) ?? "startWriting")
        }
        writer.startSession(atSourceTime: .zero)

        let frameCount = durationSeconds / frameDurationSeconds
        let frames = [try makeFrame(adaptor: adaptor, blue: 0x50, red: 0x10),
                      try makeFrame(adaptor: adaptor, blue: 0x18, red: 0x40)]
        var index = 0
        while index < frameCount {
            guard input.isReadyForMoreMediaData else {
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            let time = CMTime(value: CMTimeValue(index * frameDurationSeconds), timescale: 1)
            if !adaptor.append(frames[index % frames.count], withPresentationTime: time) {
                throw FixtureError.writerFailed(writer.error.map(String.init(describing:)) ?? "append")
            }
            index += 1
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed {
            throw FixtureError.writerFailed(writer.error.map(String.init(describing:)) ?? "finish")
        }
    }

    private nonisolated static func makeFrame(adaptor: AVAssetWriterInputPixelBufferAdaptor,
                                              blue: UInt8, red: UInt8) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool,
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else {
            throw FixtureError.pixelBufferUnavailable
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw FixtureError.pixelBufferUnavailable
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        for row in 0..<height {
            let rowBase = base.advanced(by: row * bytesPerRow)
            let pixels = rowBase.assumingMemoryBound(to: UInt8.self)
            for column in 0..<width {
                let offset = column * 4
                pixels[offset] = blue
                pixels[offset + 1] = 0x20
                pixels[offset + 2] = red
                pixels[offset + 3] = 0xFF
            }
        }
        return buffer
    }
}
#endif
