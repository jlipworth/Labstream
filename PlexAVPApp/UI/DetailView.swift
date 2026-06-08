import SwiftUI
import PlexKit

/// Item detail: artwork, summary, and the primary actions —
/// Play / Resume (presents the AVKit `PlayerView`), Download (kicks off the
/// optimize → background-download pipeline), and an offline-play shortcut when a
/// local copy already exists.
///
/// On appear it fetches full metadata for the item (the list/hub payload is often
/// trimmed and lacks `Media`/`Part`, which the player needs); it falls back to the
/// passed-in item if the refresh fails.
struct DetailView: View {
    let item: MediaItem

    @Environment(AppModel.self) private var appModel
    @Environment(DownloadManager.self) private var downloadManager

    @State private var detailed: MediaItem
    @State private var presentingPlayer = false
    @State private var playLocalURL: URL?

    init(item: MediaItem) {
        self.item = item
        _detailed = State(initialValue: item)
    }

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 40) {
                PosterImage(path: detailed.thumb, width: 300, height: 450)

                VStack(alignment: .leading, spacing: 20) {
                    Text(detailed.title)
                        .font(.largeTitle.bold())

                    HStack(spacing: 16) {
                        if let year = detailed.year {
                            Text(String(year))
                        }
                        if let mins = runtimeMinutes {
                            Text("\(mins) min")
                        }
                        if isWatched {
                            Label("Watched", systemImage: "checkmark.circle.fill")
                        }
                    }
                    .font(.title3)
                    .foregroundStyle(.secondary)

                    actionButtons

                    if let summary = detailed.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.body)
                            .padding(.top, 8)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(40)
        }
        .navigationTitle(detailed.title)
        .task { await refreshMetadata() }
        .fullScreenCover(isPresented: $presentingPlayer) {
            playerCover
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 16) {
            Button {
                playLocalURL = nil
                presentingPlayer = true
            } label: {
                Label(resumeLabel, systemImage: "play.fill")
                    .font(.title3)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)

            if let local = localURL {
                Button {
                    playLocalURL = local
                    presentingPlayer = true
                } label: {
                    Label("Play Offline", systemImage: "arrow.down.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    Task { await downloadManager.optimizeAndDownload(detailed) }
                } label: {
                    Label(downloadLabel, systemImage: "arrow.down.circle")
                        .font(.title3)
                }
                .buttonStyle(.bordered)
                .disabled(isDownloading)
            }
        }
    }

    @ViewBuilder
    private var playerCover: some View {
        if let token = appModel.token, let server = appModel.serverBaseURL {
            ZStack(alignment: .topTrailing) {
                if let local = playLocalURL {
                    PlayerView(localFile: local, item: detailed)
                } else {
                    PlayerView(item: detailed,
                               server: server,
                               token: token,
                               identity: appModel.identity,
                               client: appModel.client)
                }
                Button {
                    presentingPlayer = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.largeTitle)
                        .padding()
                }
                .buttonStyle(.plain)
            }
            .ignoresSafeArea()
        } else {
            ContentUnavailableView("Can’t play",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text("No active server session."))
        }
    }

    // MARK: Derived state

    private var localURL: URL? {
        downloadManager.localURL(for: detailed.ratingKey)
    }

    private var isDownloading: Bool {
        downloadManager.records.contains { $0.ratingKey == detailed.ratingKey && $0.progress < 1.0 }
    }

    private var downloadLabel: String {
        if let rec = downloadManager.records.first(where: { $0.ratingKey == detailed.ratingKey }),
           rec.progress < 1.0 {
            return "Downloading \(Int(rec.progress * 100))%"
        }
        return "Download"
    }

    private var isWatched: Bool {
        (detailed.viewCount ?? 0) > 0
    }

    private var resumeLabel: String {
        if let offset = detailed.viewOffset, offset > 0 { return "Resume" }
        return "Play"
    }

    private var runtimeMinutes: Int? {
        guard let ms = detailed.duration, ms > 0 else { return nil }
        return ms / 60000
    }

    private func refreshMetadata() async {
        guard let server = appModel.serverBaseURL, let token = appModel.token else { return }
        let req = BrowseAPI.metadata(server: server, token: token,
                                     identity: appModel.identity, ratingKey: item.ratingKey)
        if let resp = try? await appModel.client.send(req, as: MetadataResponse.self),
           let full = resp.mediaContainer.metadata.first {
            detailed = full
        }
    }
}
