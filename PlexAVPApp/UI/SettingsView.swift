import SwiftUI
import PMSKit

/// Settings tab: current server + re-discover, default streaming quality, download storage
/// usage, and sign out.
///
/// The "Streaming quality" picker (#21) and the in-player Quality tab are two views of the
/// SAME persisted `@AppStorage("maxVideoBitrateKbps")` key and share one ladder
/// (`StreamingQuality`): this picker sets the cap new playback sessions start at, while the
/// in-player tab additionally reloads the live stream — a pick in either place is reflected
/// in the other.
struct SettingsView: View {
    let authManager: AuthManager

    @Environment(AppModel.self) private var appModel
    @Environment(DownloadManager.self) private var downloadManager

    @State private var rediscovering = false

    /// Default bitrate cap for NEW playback sessions — the same key `PlayerView` seeds each
    /// session from and the in-player Quality tab persists to. 8 Mbps default per spec.
    @AppStorage("maxVideoBitrateKbps") private var maxVideoBitrateKbps: Int = 8000

    var body: some View {
        Form {
            serverSection
            playbackSection
            storageSection
            accountSection
        }
        .navigationTitle("Settings")
    }

    // MARK: Playback

    private var playbackSection: some View {
        SwiftUI.Section {
            Picker(selection: $maxVideoBitrateKbps) {
                ForEach(StreamingQuality.ladder) { option in
                    Text(StreamingQuality.label(kbps: option.kbps)).tag(option.kbps)
                }
            } label: {
                Label("Streaming quality", systemImage: "slider.horizontal.3")
            }
        } header: {
            Text("Playback")
        } footer: {
            Text("The quality new streams start at. Changing quality inside the player updates this too.")
        }
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

    // MARK: Storage

    private var storageSection: some View {
        SwiftUI.Section("Downloads") {
            LabeledContent {
                Text("\(downloadManager.records.count)")
            } label: {
                Label("Items", systemImage: "arrow.down.circle")
            }
            LabeledContent {
                Text(formattedStorage)
            } label: {
                Label("Storage used", systemImage: "internaldrive")
            }
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
