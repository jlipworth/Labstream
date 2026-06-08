import SwiftUI
import PlexKit

/// Settings tab: current server + re-discover, default transcode bitrate,
/// download storage usage, and sign out.
///
/// The default bitrate is persisted in `@AppStorage` so the player/download
/// modules can read the same key; it defaults to the 8 Mbps target from the plan.
struct SettingsView: View {
    let authManager: AuthManager

    @Environment(AppModel.self) private var appModel
    @Environment(DownloadManager.self) private var downloadManager

    /// Shared default cap for server-side transcode (kbps). Read by Player/Downloads.
    @AppStorage("maxVideoBitrateKbps") private var maxVideoBitrateKbps: Int = 8000

    @State private var rediscovering = false

    private let bitrateOptions: [Int] = [2000, 4000, 8000, 12000, 20000]

    var body: some View {
        Form {
            serverSection
            playbackSection
            storageSection
            accountSection
        }
        .navigationTitle("Settings")
    }

    // MARK: Server

    private var serverSection: some View {
        SwiftUI.Section("Server") {
            if let server = appModel.selectedServer {
                LabeledContent("Name", value: server.name)
            }
            if let url = appModel.serverBaseURL {
                LabeledContent("Connection", value: url.absoluteString)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Button {
                Task {
                    rediscovering = true
                    try? await authManager.refreshServers()
                    rediscovering = false
                }
            } label: {
                if rediscovering {
                    ProgressView()
                } else {
                    Label("Re-discover servers", systemImage: "arrow.clockwise")
                }
            }
            .disabled(rediscovering)
        }
    }

    // MARK: Playback

    private var playbackSection: some View {
        SwiftUI.Section {
            Picker("Max bitrate", selection: $maxVideoBitrateKbps) {
                ForEach(bitrateOptions, id: \.self) { kbps in
                    Text(bitrateLabel(kbps)).tag(kbps)
                }
            }
        } header: {
            Text("Playback")
        } footer: {
            Text("Caps server-side transcoding. 8 Mbps matches the offline 1080p preset.")
        }
    }

    private func bitrateLabel(_ kbps: Int) -> String {
        kbps >= 1000 ? "\(kbps / 1000) Mbps" : "\(kbps) kbps"
    }

    // MARK: Storage

    private var storageSection: some View {
        SwiftUI.Section("Downloads") {
            LabeledContent("Items", value: "\(downloadManager.records.count)")
            LabeledContent("Storage used", value: formattedStorage)
        }
    }

    private var formattedStorage: String {
        let total = downloadManager.records.reduce(0) { $0 + $1.bytes }
        return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }

    // MARK: Account

    private var accountSection: some View {
        SwiftUI.Section {
            Button(role: .destructive) {
                authManager.signOut()
            } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }
}
