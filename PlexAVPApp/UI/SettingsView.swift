import SwiftUI
import PlexKit

/// Settings tab: current server + re-discover, download storage usage, and sign out.
///
/// NOTE: the playback bitrate control used to live here, but quality now lives in the
/// in-player Quality menu (which reloads the stream live and persists the choice to the
/// shared `@AppStorage("maxVideoBitrateKbps")` key). The picker was removed from here to
/// avoid two competing surfaces for the same setting.
struct SettingsView: View {
    let authManager: AuthManager

    @Environment(AppModel.self) private var appModel
    @Environment(DownloadManager.self) private var downloadManager

    @State private var rediscovering = false

    var body: some View {
        Form {
            serverSection
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
