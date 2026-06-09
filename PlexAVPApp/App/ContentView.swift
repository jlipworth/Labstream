import SwiftUI
import PlexKit

/// App root. Owns the long-lived state objects and switches between the login
/// flow and the browse UI based on `appModel.isBrowseReady`.
///
/// Ownership (per the module contract): `AppModel` holds identity/token/server +
/// the shared `PlexClient`; it deliberately does NOT hold the player or download
/// controllers. This view creates the single `DownloadManager(appModel:)` for the
/// whole app and passes it (with `AppModel`) down to `RootView`.
struct ContentView: View {
    @State private var appModel: AppModel
    @State private var authManager: AuthManager
    @State private var downloadManager: DownloadManager

    /// True until the launch-time `restoreSession()` finishes. While restoring we show a
    /// neutral splash — NOT `LoginView` — because a saved token takes a moment to resolve a
    /// reachable server (discovery + connection probing), during which `isBrowseReady` is still
    /// false. Showing the Sign-In button in that window let the user start a second OAuth flow
    /// whose web sheet then orphaned itself over the restored UI.
    @State private var isRestoring = true

    init() {
        // Build a stable identity from the persisted client identifier.
        let keychain = KeychainStore()
        let identity = ClientIdentity(
            clientIdentifier: keychain.clientIdentifier(),
            product: "plex-avp-app",
            version: "0.1.0",
            deviceName: "Apple Vision Pro"
        )
        let model = AppModel(identity: identity)
        let auth = AuthManager(appModel: model, keychain: keychain)
        _appModel = State(initialValue: model)
        _authManager = State(initialValue: auth)
        _downloadManager = State(initialValue: DownloadManager(appModel: model))
    }

    var body: some View {
        Group {
            if appModel.isBrowseReady {
                RootView(appModel: appModel,
                         authManager: authManager,
                         downloadManager: downloadManager)
            } else if isRestoring {
                RestoringSessionView()
            } else {
                LoginView(authManager: authManager)
                    .environment(appModel)
            }
        }
        .task {
            guard isRestoring else { return }
            await authManager.restoreSession()
            isRestoring = false
        }
    }
}

/// Neutral launch splash shown while a saved session is being restored (token read +
/// server discovery/probing), so the Sign-In screen never flashes for an already-signed-in
/// user.
private struct RestoringSessionView: View {
    var body: some View {
        VStack(spacing: DS.Space.lg) {
            ProgressView()
                .controlSize(.large)
            Text("Connecting…")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview(windowStyle: .plain) {
    ContentView()
}
