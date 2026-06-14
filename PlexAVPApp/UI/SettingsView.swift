import SwiftUI
import UIKit
import PMSKit

/// Settings tab (#26): server info + reachability, default streaming quality, playback-pref
/// reset, download storage usage, maintenance, About/diagnostics, and sign out.
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
    @State private var confirmingSignOut = false
    @State private var confirmingReset = false
    @State private var connectionStatus: ConnectionStatus = .unknown
    /// Transient "done" feedback for the one-shot maintenance/About actions.
    @State private var clearedImageCache = false
    @State private var resetPlaybackPrefs = false
    @State private var copiedDiagnostics = false
    @State private var switchingBackend: MediaBackendKind?

    /// Default bitrate cap for NEW playback sessions — the same key the custom player seeds each
    /// session from and the in-player Quality tab persists to. 8 Mbps default per spec.
    @AppStorage("maxVideoBitrateKbps") private var maxVideoBitrateKbps: Int = 8000

    var body: some View {
        Form {
            backendSection
            serverSection
            playbackSection
            storageSection
            maintenanceSection
            aboutSection
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
            Text("The quality new streams start at. Changing quality inside the player updates this too. \"Direct Play / Maximum\" plays the original file directly when the server can, otherwise it transcodes at maximum. \"Maximum (transcoded)\" always transcodes.")
        }
    }

    // MARK: Backend

    private var backendSection: some View {
        SwiftUI.Section {
            Picker("Media Backend", selection: Binding(
                get: { appModel.activeBackend },
                set: { backend in
                    guard backend != appModel.activeBackend else { return }
                    switchingBackend = backend
                    Task {
                        await authManager.switchBackend(backend)
                        switchingBackend = nil
                    }
                })) {
                    ForEach(MediaBackendKind.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(switchingBackend != nil)

            if let switchingBackend {
                HStack {
                    ProgressView()
                    Text("Switching to \(switchingBackend.displayName)…")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Backend")
        } footer: {
            Text("Switching keeps Plex and Jellyfin credentials separate. If the selected backend has a saved session, VisionPlex reconnects automatically; otherwise it opens that backend’s sign-in flow.")
        }
    }

    // MARK: Server

    /// Result of the last manual reachability check. No background polling — the probe runs
    /// only on tap (and re-arms after re-discovery, which replaces the connection anyway).
    private enum ConnectionStatus: Equatable {
        case unknown
        case checking
        case reachable(Date)
        case unreachable(Date)
    }

    private var serverSection: some View {
        SwiftUI.Section("Server") {
            switch appModel.activeBackend {
            case .plex:
                if let server = appModel.selectedServer {
                    LabeledContent("Name", value: server.name)
                    if let version = server.productVersion, !version.isEmpty {
                        LabeledContent("Version", value: version)
                    }
                }
                if let url = appModel.serverBaseURL {
                    LabeledContent("Connection", value: url.absoluteString)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    connectionStatusRow
                }
                Button {
                    Task {
                        rediscovering = true
                        try? await authManager.refreshServers()
                        rediscovering = false
                        connectionStatus = .unknown
                    }
                } label: {
                    if rediscovering {
                        ProgressView()
                    } else {
                        Label("Re-discover servers", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(rediscovering)
            case .jellyfin:
                if let url = appModel.jellyfinServerBaseURL {
                    LabeledContent("Connection", value: url.absoluteString)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let userID = appModel.jellyfinUserID {
                    LabeledContent("User ID", value: userID)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    /// Status dot + last-checked time, with the whole row acting as "check now".
    private var connectionStatusRow: some View {
        Button {
            Task {
                connectionStatus = .checking
                let ok = await authManager.probeSelectedServer()
                connectionStatus = ok ? .reachable(.now) : .unreachable(.now)
            }
        } label: {
            LabeledContent {
                switch connectionStatus {
                case .unknown:
                    Text("Tap to check")
                case .checking:
                    ProgressView()
                case .reachable(let date):
                    Label(checkedAt(date), systemImage: "circle.fill")
                        .foregroundStyle(.green)
                case .unreachable(let date):
                    Label(checkedAt(date), systemImage: "circle.fill")
                        .foregroundStyle(.red)
                }
            } label: {
                Label("Status", systemImage: "dot.radiowaves.left.and.right")
            }
        }
        .buttonStyle(.plain)
        .disabled(connectionStatus == .checking)
    }

    private func checkedAt(_ date: Date) -> String {
        "Checked \(date.formatted(date: .omitted, time: .shortened))"
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

    // MARK: Maintenance

    private var maintenanceSection: some View {
        SwiftUI.Section {
            Button {
                // PosterImage rides URLSession.shared's default cache — there is no
                // bespoke image cache, so this is the whole story.
                URLCache.shared.removeAllCachedResponses()
                clearedImageCache = true
            } label: {
                if clearedImageCache {
                    Label("Cache cleared", systemImage: "checkmark")
                } else {
                    Label("Clear image cache", systemImage: "photo.on.rectangle.angled")
                }
            }
            .disabled(clearedImageCache)
        } header: {
            Text("Maintenance")
        } footer: {
            Text("Artwork re-downloads on next view.")
        }
    }

    // MARK: About

    private var aboutSection: some View {
        SwiftUI.Section("About") {
            LabeledContent("Version", value: "\(Self.appVersion) (\(Self.appBuild))")
            LabeledContent("visionOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
            // Product/device name exactly as sent to Plex. NEVER the client identifier —
            // it's treated as a secret in this repo.
            LabeledContent("Client", value: "\(appModel.identity.product) on \(appModel.identity.deviceName)")
            Button {
                UIPasteboard.general.string = diagnosticsText
                copiedDiagnostics = true
            } label: {
                if copiedDiagnostics {
                    Label("Copied", systemImage: "checkmark")
                } else {
                    Label("Copy diagnostics", systemImage: "doc.on.doc")
                }
            }
        }
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    /// Bug-report blob. Includes versions, server name/version, and the connection SCHEME
    /// only — never the token, client identifier, or full connection URL/hostname.
    private var diagnosticsText: String {
        var lines = [
            "\(appModel.identity.product) \(Self.appVersion) (\(Self.appBuild))",
            "visionOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Device: \(appModel.identity.deviceName)",
        ]
        if let server = appModel.selectedServer {
            let version = server.productVersion.map { " \($0)" } ?? ""
            lines.append("Server: \(server.name)\(version)")
        }
        if let scheme = appModel.serverBaseURL?.scheme {
            lines.append("Connection scheme: \(scheme)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Account

    private var accountSection: some View {
        SwiftUI.Section {
            // Reset lives down here next to Sign Out: both are rarely-used, destructive-ish
            // account actions, so they're grouped away from the everyday playback toggles.
            Button(role: .destructive) {
                confirmingReset = true
            } label: {
                if resetPlaybackPrefs {
                    Label("Preferences reset", systemImage: "checkmark")
                } else {
                    Label("Reset playback preferences", systemImage: "arrow.counterclockwise")
                }
            }
            .disabled(resetPlaybackPrefs)
            // Reset silently throws away remembered choices, so confirm first.
            .confirmationDialog(
                "Reset playback preferences?",
                isPresented: $confirmingReset,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) {
                    // Clears speed + subtitle/audio-language keys (single source of truth in
                    // PlaybackController). Deliberately leaves `maxVideoBitrateKbps` alone —
                    // the Streaming quality picker owns it.
                    let defaults = UserDefaults.standard
                    for key in PlaybackController.persistedPreferenceKeys {
                        defaults.removeObject(forKey: key)
                    }
                    resetPlaybackPrefs = true
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Clears the remembered playback speed and subtitle/audio language. Streaming quality is unaffected.")
            }

            Button(role: .destructive) {
                confirmingSignOut = true
            } label: {
                Label("Sign Out of \(appModel.activeBackend.displayName)", systemImage: "rectangle.portrait.and.arrow.right")
            }
            // Sign-out is genuinely disruptive — re-login is the plex.tv PIN dance —
            // so the destructive action gets a confirmation (#26).
            .confirmationDialog(
                "Sign out of Plex?",
                isPresented: $confirmingSignOut,
                titleVisibility: .visible
            ) {
                Button("Sign Out", role: .destructive) {
                    authManager.signOut()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Signing back in requires authorizing this device with plex.tv again.")
            }
        }
    }
}
