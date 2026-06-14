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

    /// Default bitrate cap for NEW playback sessions — the same key the custom player seeds each
    /// session from and the in-player Quality tab persists to. 8 Mbps default per spec.
    @AppStorage("maxVideoBitrateKbps") private var maxVideoBitrateKbps: Int = 8000

    /// Direct Stream opt-in (#7 Step 3, default OFF). When on, playback first asks PMS
    /// whether it can copy the video stream (remux) instead of re-encoding; the player only
    /// commits to the direct-play request when PMS agrees. Same key `PlaybackController`
    /// reads each (re)build, so flipping it mid-session affects the next stream rebuild —
    /// the in-headset kill switch the research/15 rollout plan calls for.
    @AppStorage(PlaybackController.directStreamEnabledKey) private var directStreamEnabled = false

    /// Optional #31 guard for Direct Stream. Default OFF so the original #7 experimental
    /// behavior stays available for testing unless the user asks for the safer heuristic.
    @AppStorage(PlaybackController.directStreamHeadroomEnabledKey) private var directStreamHeadroomEnabled = false

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
            Toggle(isOn: $directStreamEnabled) {
                Label("Direct Stream (experimental)", systemImage: "arrow.triangle.branch")
            }
            Toggle(isOn: $directStreamHeadroomEnabled) {
                Label("Require bandwidth headroom", systemImage: "speedometer")
            }
            .disabled(!directStreamEnabled)
        } header: {
            Text("Playback")
        } footer: {
            Text("The quality new streams start at. Changing quality inside the player updates this too. Direct Stream plays compatible video without re-encoding on the server. The headroom gate is stricter: when enabled, Direct Stream only starts after a recent throughput sample exceeds the source bitrate by 25%.")
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
