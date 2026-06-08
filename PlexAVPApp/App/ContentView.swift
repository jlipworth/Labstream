import SwiftUI
import PlexKit

/// App root. Owns the long-lived state objects and switches between the login
/// flow and the authenticated UI based on `appModel.isAuthenticated`.
///
/// Ownership (per the module contract): `AppModel` holds identity/token/server +
/// the shared `PlexClient`; it deliberately does NOT hold the player or download
/// controllers. This view creates the single `DownloadManager(appModel:)` for the
/// whole app and passes it (with `AppModel`) down to `RootView`.
struct ContentView: View {
    @State private var appModel: AppModel
    @State private var authManager: AuthManager
    @State private var downloadManager: DownloadManager

    @State private var didRestore = false

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
            if appModel.isAuthenticated {
                RootView(appModel: appModel,
                         authManager: authManager,
                         downloadManager: downloadManager)
            } else {
                LoginView(authManager: authManager)
                    .environment(appModel)
            }
        }
        .task {
            guard !didRestore else { return }
            didRestore = true
            await authManager.restoreSession()
        }
    }
}

#Preview(windowStyle: .plain) {
    ContentView()
}
